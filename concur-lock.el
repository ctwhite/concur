;;; concur-lock.el --- Mutual Exclusion Locks for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `concur-lock` (mutex) primitive. It supports
;; both cooperative (Emacs Lisp-managed) and native (OS-thread-managed)
;; mutexes, ensuring thread-safe access to shared resources across the
;; various concurrency modes within the Concur library.
;;
;; Key features include:
;; - Cooperative Locks: For single-threaded async operations, with reentrant
;;   support.
;; - Native Thread Locks: For preemptive thread-safety using Emacs's native
;;   mutexes (implicitly reentrant).
;; - Non-Blocking `try-acquire`: For cooperative locks, allows attempting to
;;   acquire a lock without blocking.
;; - Resource Tracking Hooks: Integrates with higher-level libraries to monitor
;;   resource acquisition and release.

;;; Code:

(require 'cl-lib)
(require 'subr-x) ; Provides `timerp`.
(require 'concur-log)

;; Ensure native Emacs thread functions are loaded if available.
(when (fboundp 'make-thread) (require 'thread))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:make-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-lock-error
  "A generic error with a concurrency lock operation."
  'concur-error)

(define-error 'concur-invalid-lock-error
  "An operation was attempted on an invalid lock object."
  'concur-lock-error)

(define-error 'concur-lock-unowned-release-error
  "Attempted to release a lock not owned by the caller."
  'concur-lock-error)

(define-error 'concur-lock-unsupported-operation-error
  "An operation is not supported for the lock's mode."
  'concur-lock-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-lock (:constructor %%make-lock))
  "A mutual exclusion lock (mutex).

Fields:
- `name` (string): Descriptive name for debugging.
- `mode` (symbol): Lock's operating mode (`:deferred` or `:thread`).
- `locked-p` (boolean): `t` if held (for cooperative `:deferred` mode).
- `native-mutex` (mutex): Underlying native Emacs mutex for `:thread` mode.
- `owner` (any): Identifier of the entity holding the lock.
- `reentrant-count` (integer): Tracks nested acquisitions for `:deferred` mode."
  (name "" :type string)
  (mode :deferred :type (member :deferred :thread))
  (locked-p nil :type boolean)
  (native-mutex nil :type (or null (satisfies mutex-p)))
  (owner nil)
  (reentrant-count 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-lock (lock function-name)
  "Signal an error if LOCK is not a `concur-lock`.

Arguments:
- `LOCK` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for error reporting."
  (unless (concur-lock-p lock)
    (signal 'concur-invalid-lock-error
            (list (format "%s: Invalid lock object" function-name) lock))))

(defun concur--lock-get-effective-owner (lock owner)
  "Return the effective owner for a lock operation.

Arguments:
- `LOCK` (concur-lock): The lock object.
- `OWNER` (any): The owner provided by the caller.

Returns:
- (any): The effective owner, defaulting to `current-thread` for
  `:thread` mode locks or `current-buffer` otherwise."
  (or owner
      (if (eq (concur-lock-mode lock) :thread)
          (current-thread)
        (current-buffer))))

(defun concur--lock-track-resource (action lock)
  "Call the resource tracking function, if defined.
This is a hook for higher-level libraries to monitor resource usage.

Arguments:
- `ACTION` (keyword): The action, either `:acquire` or `:release`.
- `LOCK` (concur-lock): The lock object."
  (when (and (fboundp 'concur-resource-tracking-function)
             concur-resource-tracking-function)
    (funcall concur-resource-tracking-function action lock)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:make-lock (&optional name &key (mode :deferred))
  "Create a new lock object (mutex).
The lock's behavior depends on its `MODE`:
- `:deferred`: A cooperative, non-blocking, reentrant lock for the main
  Emacs thread.
- `:thread`: A native OS thread mutex (blocking acquire, preemptive,
  implicitly reentrant).

Arguments:
- `NAME` (string): A descriptive name for debugging.
- `:MODE` (symbol, optional): The lock's mode. Defaults to `:deferred`.

Returns:
- `(concur-lock)`: A new lock object.

Signals:
- `error` if an invalid mode is provided or thread support is unavailable."
  (unless (memq mode '(:deferred :thread))
    (error "Invalid lock mode: %S. Must be :deferred or :thread." mode))
  (let* ((lock-name (or name (format "lock-%S" (gensym))))
         (new-lock
          (pcase mode
            (:thread
             (unless (fboundp 'make-mutex)
               (error "Cannot create :thread mode lock: thread support missing."))
             (%%make-lock :name lock-name :mode :thread
                          :native-mutex (make-mutex lock-name)
                          :reentrant-count 0))
            (:deferred
             (%%make-lock :name lock-name :mode mode
                          :reentrant-count 0)))))
    (concur-log :debug (concur-lock-name new-lock) "Lock created.")
    new-lock))

;;;###autoload
(defun concur:lock-acquire (lock &optional owner)
  "Acquire `LOCK`. This is a **blocking** operation for `:thread` locks.
For `:deferred` mode, it is cooperative and reentrant for the same owner.

Arguments:
- `LOCK` (concur-lock): The lock object.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
- `t` if the lock was acquired.

Signals:
- `concur-invalid-lock-error` if `LOCK` is not a valid lock object.
- `error` if a `:deferred` lock is already held by another owner."
  (concur--validate-lock lock 'concur:lock-acquire)
  (let ((effective-owner (concur--lock-get-effective-owner lock owner)))
    (concur-log :trace (concur-lock-name lock)
                 "Acquire attempt by %S. State: owner=%S, locked=%S, count=%d"
                 effective-owner (concur-lock-owner lock)
                 (concur-lock-locked-p lock) (concur-lock-reentrant-count lock))

    (pcase (concur-lock-mode lock)
      (:thread
       (unless (fboundp 'mutex-lock)
         (error "Thread mutex functions not available."))
       (mutex-lock (concur-lock-native-mutex lock))
       (setf (concur-lock-owner lock) effective-owner)
       (concur-log :debug (concur-lock-name lock)
                    "Native lock acquired by %S." effective-owner))
      (:deferred
       (if (not (concur-lock-locked-p lock)) ; Lock is currently free
           (progn
             (setf (concur-lock-locked-p lock) t)
             (setf (concur-lock-owner lock) effective-owner)
             (setf (concur-lock-reentrant-count lock) 1)
             (concur-log :debug (concur-lock-name lock)
                          "Deferred lock acquired (first) by %S." effective-owner))
         (if (eq (concur-lock-owner lock) effective-owner) ; Lock held by current owner (re-entry)
             (progn
               (cl-incf (concur-lock-reentrant-count lock))
               (concur-log :debug (concur-lock-name lock)
                            "Deferred lock re-acquired by %S. Count: %d."
                            effective-owner (concur-lock-reentrant-count lock)))
           ;; Lock held by *another* owner (true contention for cooperative lock)
           (error "Could not acquire cooperative lock %s (held by %S)"
                  (concur-lock-name lock) (concur-lock-owner lock))))))

    (concur-log :trace (concur-lock-name lock)
                 "Acquire complete. Final state: owner=%S, locked=%S, count=%d"
                 (concur-lock-owner lock) (concur-lock-locked-p lock)
                 (concur-lock-reentrant-count lock))
    (concur--lock-track-resource :acquire lock)
    t))

;;;###autoload
(defun concur:lock-try-acquire (lock &optional owner)
  "Attempt to acquire `LOCK`. This is a **non-blocking** operation.
This operation is only supported for `:deferred` mode locks.

Arguments:
- `LOCK` (concur-lock): The lock object.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
- `t` if the lock was acquired, `nil` if it was already held.

Signals:
- `concur-invalid-lock-error` if `LOCK` is not a valid lock object.
- `concur-lock-unsupported-operation-error` if called on a `:thread` lock."
  (concur--validate-lock lock 'concur:lock-try-acquire)
  (let ((acquired-p nil)
        (effective-owner (concur--lock-get-effective-owner lock owner)))
    (concur-log :trace (concur-lock-name lock)
                 "Try-acquire attempt by %S. State: owner=%S, locked=%S, count=%d"
                 effective-owner (concur-lock-owner lock)
                 (concur-lock-locked-p lock) (concur-lock-reentrant-count lock))

    (pcase (concur-lock-mode lock)
      (:thread
       (signal 'concur-lock-unsupported-operation-error
               (list "concur:lock-try-acquire is not supported for :thread mode locks")))
      (:deferred
       (if (or (not (concur-lock-locked-p lock))
               (eq (concur-lock-owner lock) effective-owner))
           (progn
             (setf (concur-lock-locked-p lock) t)
             (setf (concur-lock-owner lock) effective-owner)
             (cl-incf (concur-lock-reentrant-count lock))
             (setq acquired-p t))
         (setq acquired-p nil))))
    (when acquired-p
      (concur-log :debug (concur-lock-name lock)
                   "Deferred lock try-acquired by %S. Count: %d."
                   (concur-lock-owner lock) (concur-lock-reentrant-count lock))
      (concur--lock-track-resource :acquire lock))
    acquired-p))

;;;###autoload
(defun concur:lock-release (lock &optional owner)
  "Release `LOCK`. Requires the caller to be the current owner.
For `:deferred` locks, the release is counted, and the lock is only truly
freed when the reentrant count returns to zero."
  (concur--validate-lock lock 'concur:lock-release)
  (let ((effective-owner (concur--lock-get-effective-owner lock owner)))
    (concur-log :trace (concur-lock-name lock)
                 "Release attempt by %S. State: owner=%S, locked=%S, count=%d"
                 effective-owner (concur-lock-owner lock)
                 (concur-lock-locked-p lock) (concur-lock-reentrant-count lock))

    (unless (eq (concur-lock-owner lock) effective-owner)
      (concur-log :error (concur-lock-name lock)
                   "Release error: lock owned by %S (caller %S)."
                   (concur-lock-owner lock) effective-owner)
      (signal 'concur-lock-unowned-release-error
              (list (format "Cannot release lock %S owned by %S (caller is %S)"
                            (concur-lock-name lock)
                            (concur-lock-owner lock)
                            effective-owner))))

    (concur--lock-track-resource :release lock)

    (pcase (concur-lock-mode lock)
      (:thread
       (unless (fboundp 'mutex-unlock) (error "Thread mutex functions not available."))
       (mutex-unlock (concur-lock-native-mutex lock))
       (setf (concur-lock-owner lock) nil) ; Clear owner for thread locks
       (concur-log :debug (concur-lock-name lock)
                    "Native lock released by %S." effective-owner))
      (:deferred
       (cl-decf (concur-lock-reentrant-count lock))
       (concur-log :debug (concur-lock-name lock)
                    "Deferred lock released by %S. New count: %d."
                    effective-owner (concur-lock-reentrant-count lock))
       (when (zerop (concur-lock-reentrant-count lock)) ; Truly release if count is zero
         (setf (concur-lock-owner lock) nil)
         (setf (concur-lock-locked-p lock) nil)
         (concur-log :debug (concur-lock-name lock)
                      "Deferred lock fully freed by %S." effective-owner))))

    (concur-log :trace (concur-lock-name lock)
                 "Release complete. Final state: owner=%S, locked=%S, count=%d"
                 (concur-lock-owner lock) (concur-lock-locked-p lock)
                 (concur-lock-reentrant-count lock))
    t))

;;;###autoload
(defmacro concur:with-mutex! (lock-form &rest body)
  "Execute BODY within a critical section guarded by the lock from `LOCK-FORM`.
This macro ensures the lock is always released, even if an error occurs
within the BODY. It uses a **blocking** acquire for `:thread` locks. For
`:deferred` locks, it attempts a cooperative reentrant acquire."
  (declare (indent 1) (debug t))
  (let ((lock-var (gensym "lock-")))
    `(let ((,lock-var ,lock-form))
       (if (concur:lock-acquire ,lock-var)
           (unwind-protect
               (progn ,@body)
             ;; Always call concur:lock-release. It handles the reentrant count.
             (concur:lock-release ,lock-var))
         ;; This branch should only be reached if `concur:lock-acquire`
         ;; signals an error (e.g., contention for a :deferred lock by a
         ;; different owner, which is an error in cooperative mode).
         (error "Failed to acquire lock %S for with-mutex! (unexpected path)"
                (concur-lock-name ,lock-var))))))

(provide 'concur-lock)
;;; concur-lock.el ends here