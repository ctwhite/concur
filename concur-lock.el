;;; concur-lock.el --- Mutual Exclusion Locks for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `concur-lock` (mutex) primitive. It supports
;; both cooperative (Emacs Lisp-managed) and native (OS-thread-managed)
;; mutexes, ensuring thread-safe access to shared resources across the
;; various concurrency modes within the Concur library.
;;
;; Key features include:
;; - Cooperative Locks: For single-threaded async operations, preventing re-entry.
;; - Native Thread Locks: For preemptive thread-safety using Emacs's native mutexes.
;; - Non-Blocking `try-acquire`: Allows attempting to acquire a lock without
;;   blocking, even for native threads.
;; - Resource Tracking Hooks: Integrates with higher-level libraries to monitor
;;   resource acquisition and release.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'concur-log)

;; Ensure native Emacs thread functions are loaded if available.
(when (fboundp 'make-thread) (require 'thread))

(declare-function concur:make-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-lock (:constructor %%make-lock))
  "A mutual exclusion lock (mutex).

Fields:
- `name` (string): A descriptive name for debugging.
- `mode` (symbol): The lock's operating mode (`:deferred` or `:thread`).
- `locked-p` (boolean): `t` if held (for cooperative `:deferred` mode).
- `native-mutex` (mutex): The underlying native Emacs mutex for `:thread` mode.
- `owner` (any): Identifier of the entity currently holding the lock."
  (name "" :type string)
  (mode :deferred :type (member :deferred :thread))
  (locked-p nil :type boolean)
  (native-mutex nil :type (or null (satisfies mutex-p)))
  (owner nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-lock (lock function-name)
  "Signal an error if LOCK is not a `concur-lock`.

Arguments:
- `LOCK` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:make-lock (name &key (mode :deferred))
  "Create a new lock object (mutex).
The lock's behavior depends on its `MODE`:
- `:deferred`: A cooperative, non-blocking lock for the main Emacs thread.
- `:thread`: A native OS thread mutex (blocking acquire, preemptive).

Arguments:
- `NAME` (string): A descriptive name for debugging.
- `:MODE` (symbol, optional): The lock's mode. Defaults to `:deferred`.

Returns:
- (concur-lock): A new lock object.

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
                          :native-mutex (make-mutex lock-name)))
            (:deferred
             (%%make-lock :name lock-name :mode mode)))))
    (concur--log :debug (concur-lock-name new-lock) "Created lock.")
    new-lock))

;;;###autoload
(defun concur:lock-acquire (lock &optional owner)
  "Acquire `LOCK`. This is a **blocking** operation for `:thread` mode locks.
It waits until the lock is available. For `:deferred` mode, it is
non-blocking and equivalent to `concur:lock-try-acquire`.

Arguments:
- `LOCK` (concur-lock): The lock object.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
- `t` if the lock was acquired.

Signals:
- `concur-invalid-lock-error` if `LOCK` is not a valid lock object."
  (concur--validate-lock lock 'concur:lock-acquire)
  (let ((effective-owner (concur--lock-get-effective-owner lock owner)))
    (pcase (concur-lock-mode lock)
      (:thread
       (mutex-lock (concur-lock-native-mutex lock))
       (setf (concur-lock-owner lock) effective-owner))
      (:deferred
       (if (or (not (concur-lock-locked-p lock))
               (eq (concur-lock-owner lock) effective-owner))
           (progn
             (setf (concur-lock-locked-p lock) t)
             (setf (concur-lock-owner lock) effective-owner))
         ;; This case should not be hit with a blocking acquire, but is here
         ;; for logical completeness. It implies contention.
         (error "Could not acquire cooperative lock %s" (concur-lock-name lock)))))
    (concur--log :debug (concur-lock-name lock) "Acquired lock by %S."
                 (concur-lock-owner lock))
    (concur--lock-track-resource :acquire lock)
    t))

;;;###autoload
(defun concur:lock-try-acquire (lock &optional owner)
  "Attempt to acquire `LOCK`. This is a **non-blocking** operation.
If the lock is already held (by another thread or task), this
function returns `nil` immediately instead of waiting.

Arguments:
- `LOCK` (concur-lock): The lock object.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
- `t` if the lock was acquired, `nil` if it was already held.

Signals:
- `concur-invalid-lock-error` if `LOCK` is not a valid lock object."
  (concur--validate-lock lock 'concur:lock-try-acquire)
  (let ((acquired-p nil)
        (effective-owner (concur--lock-get-effective-owner lock owner)))
    (pcase (concur-lock-mode lock)
      (:thread
       (when (mutex-trylock (concur-lock-native-mutex lock))
         (setf (concur-lock-owner lock) effective-owner)
         (setq acquired-p t)))
      (:deferred
       (if (or (not (concur-lock-locked-p lock))
               (eq (concur-lock-owner lock) effective-owner))
           (progn
             (setf (concur-lock-locked-p lock) t)
             (setf (concur-lock-owner lock) effective-owner)
             (setq acquired-p t))
         (setq acquired-p nil))))
    (when acquired-p
      (concur--log :debug (concur-lock-name lock) "Acquired lock by %S."
                   (concur-lock-owner lock))
      (concur--lock-track-resource :acquire lock))
    acquired-p))

;;;###autoload
(defun concur:lock-release (lock &optional owner)
  "Release `LOCK`. Requires the caller to be the current owner.

Arguments:
- `LOCK` (concur-lock): The lock object to release.
- `OWNER` (any, optional): Identifier of the entity releasing the lock.

Returns:
- `t` if the lock was successfully released.

Signals:
- `concur-invalid-lock-error` if `LOCK` is not valid.
- `concur-lock-unowned-release-error` if attempted by a non-owner."
  (concur--validate-lock lock 'concur:lock-release)
  (let ((effective-owner (concur--lock-get-effective-owner lock owner)))
    (unless (eq (concur-lock-owner lock) effective-owner)
      (signal 'concur-lock-unowned-release-error
              (list (format "Cannot release lock %S owned by %S (caller is %S)"
                            (concur-lock-name lock)
                            (concur-lock-owner lock)
                            effective-owner))))
    (concur--lock-track-resource :release lock)
    (setf (concur-lock-owner lock) nil)
    (pcase (concur-lock-mode lock)
      (:thread (mutex-unlock (concur-lock-native-mutex lock)))
      (:deferred (setf (concur-lock-locked-p lock) nil)))
    (concur--log :debug (concur-lock-name lock) "Released lock by %S."
                 effective-owner)
    t))

;;;###autoload
(defmacro concur:with-mutex! (lock-form &rest body)
  "Execute BODY within a critical section guarded by the lock from `LOCK-FORM`.
This macro ensures the lock is always released, even if an error occurs
within the BODY. It uses a **blocking** acquire. For non-blocking behavior,
use `concur:lock-try-acquire` manually.

An optional `:else` clause can provide fallback behavior if the lock cannot
be acquired (only applicable for non-blocking lock modes, though this macro
currently always blocks for `:thread` mode).

Arguments:
- `LOCK-FORM` (form): A form that evaluates to a `concur-lock` object.
- `BODY` (forms): The forms to execute. Can include one instance of
  `(:else <fallback-forms...>)` for custom fallback logic.

Returns:
- (any): The result of executing either the BODY or the `:else` fallback."
  (declare (indent 1) (debug t))
  (let ((lock-var (gensym "lock-"))
        (main-body body)
        (else-forms nil))
    (when-let ((else-clause (cl-find :else body :key #'car-safe)))
      (setq else-forms (cdr else-clause))
      (setq main-body (cl-remove else-clause body)))

    `(let ((,lock-var ,lock-form))
       (if (concur:lock-acquire ,lock-var)
           (unwind-protect
               (progn ,@main-body)
             (concur:lock-release ,lock-var))
         ;; Fallback branch: lock not acquired.
         ,@else-forms))))

;;;###autoload
(defun concur:lock-status (lock)
  "Return a snapshot of the `LOCK`'s current status.

Arguments:
- `LOCK` (concur-lock): The lock to inspect.

Returns:
- (plist): A property list with lock metrics, including `:name`, `:mode`,
  `:locked-p`, and `:owner`.

Signals:
- `concur-invalid-lock-error` if `LOCK` is not a valid lock object."
  (concur--validate-lock lock 'concur:lock-status)
  `(:name ,(concur-lock-name lock)
    :mode ,(concur-lock-mode lock)
    :locked-p ,(if (eq (concur-lock-mode lock) :thread)
                   (not (eq (concur-lock-owner lock) nil))
                 (concur-lock-locked-p lock))
    :owner ,(concur-lock-owner lock)))

(provide 'concur-lock)
;;; concur-lock.el ends here