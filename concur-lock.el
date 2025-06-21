;;; concur-lock.el --- Mutual Exclusion Locks for Concur -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This module provides the `concur-lock` (mutex) primitive for Emacs Lisp.
;; It supports both cooperative (Emacs Lisp-managed) and native (OS-thread-managed)
;; mutexes, ensuring thread-safe access to shared resources across various
;; concurrency modes within the Concur library.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'concur-core) ; For define-error

;; Ensure native Emacs thread functions are loaded if available.
(when (fboundp 'make-thread) (require 'thread))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error Definitions

(define-error 'concur-lock-error "Error with concurrency lock." 'concur-error)
(define-error 'concur-lock-contention-error
  "Lock could not be acquired due to contention." 'concur-lock-error)
(define-error 'concur-lock-unowned-release-error
  "Attempted to release a lock not owned by caller." 'concur-lock-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Resource Tracking

(defvar concur-resource-tracking-function nil
  "A function called by primitives when a resource is acquired or released.
The function should accept two arguments: ACTION (a keyword like `:acquire` or
`:release`) and RESOURCE (the primitive object itself). This is intended to be
dynamically bound by a higher-level library (e.g., a promise executor) to
associate resource management with a specific task.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Lock (Mutex) Primitive

(eval-and-compile
  (cl-defstruct (concur-lock (:constructor %%make-lock))
    "A mutual exclusion lock (mutex).

Fields:
- `mode` (symbol): The lock's operating mode (`:deferred`, `:thread`).
- `locked-p` (boolean): `t` if the lock is held (for cooperative modes).
- `native-mutex` (mutex or nil): The underlying native Emacs mutex object
  used in `:thread` mode.
- `owner` (any): Identifier of the entity currently holding the lock.
- `name` (string): A descriptive name for debugging."
    (mode :deferred :type (member :deferred :thread :async))
    (locked-p nil :type boolean)
    (native-mutex nil :type (or null (if (fboundp 'mutex-p)
                                         (satisfies mutex-p)
                                       'any)))
    (owner nil)
    (name "" :type string)))

;;;###autoload
(cl-defun concur:make-lock (name &key (mode :deferred))
  "Create a new lock object (mutex).
The lock's behavior depends on its `MODE`:
- `:deferred`, `:async`: Emacs Lisp mutex (cooperative, non-blocking acquire).
- `:thread`: Native OS thread mutex (preemptive, blocking acquire).

Arguments:
- `NAME` (string): A descriptive name for debugging.
- `:MODE` (symbol, optional): The lock's operating mode.

Returns:
  (concur-lock) A new lock object."
  (unless (memq mode '(:deferred :thread :async))
    (error "Invalid lock mode: %S" mode))
  (let* ((lock-name (or name (format "lock-%s" (sxhash (current-time))))))
    (pcase mode
      (:thread
       (unless (fboundp 'make-mutex)
         (error "Cannot create :thread mode mutex without thread support."))
       (%%make-lock :name lock-name :mode :thread
                    :native-mutex (make-mutex lock-name)))
      ((or :async :deferred)
       (%%make-lock :name lock-name :mode mode)))))

;;;###autoload
(defun concur:lock-acquire (lock &optional owner)
  "Acquire `LOCK`.
For `:thread` mode, this blocks the calling thread until acquired.
For other modes, it's a non-blocking attempt that returns `nil` if held.

Arguments:
- `LOCK` (concur-lock): The lock object.
- `OWNER` (any, optional): Identifier for the entity acquiring the lock.

Returns:
  (boolean) `t` if the lock was acquired, `nil` otherwise."
  (unless (concur-lock-p lock) (error "Invalid lock object: %S" lock))
  (let ((acquired-p nil)
        (current-owner (or owner
                           (if (eq (concur-lock-mode lock) :thread)
                               (current-thread)
                             (current-buffer)))))
    (pcase (concur-lock-mode lock)
      (:thread
       (mutex-lock (concur-lock-native-mutex lock))
       (setf (concur-lock-owner lock) current-owner)
       (setq acquired-p t))
      ((or :async :deferred)
       (if (or (not (concur-lock-locked-p lock))
               (eq (concur-lock-owner lock) current-owner))
           (progn
             (setf (concur-lock-locked-p lock) t)
             (setf (concur-lock-owner lock) current-owner)
             (setq acquired-p t))
         (setq acquired-p nil))))
    (when (and acquired-p concur-resource-tracking-function)
      (funcall concur-resource-tracking-function :acquire lock))
    acquired-p))

;;;###autoload
(defun concur:lock-release (lock &optional owner)
  "Release `LOCK`. Requires the caller to be the owner of the lock.

Arguments:
- `LOCK` (concur-lock): The lock object to release.
- `OWNER` (any, optional): Identifier of the entity releasing the lock.

Returns:
  `t` if the lock was successfully released.

Signals:
  (concur-lock-error) if already unlocked.
  (concur-lock-unowned-release-error) if attempted by a non-owner."
  (unless (concur-lock-p lock) (error "Invalid lock object: %S" lock))
  (let ((current-owner (or owner
                           (if (eq (concur-lock-mode lock) :thread)
                               (current-thread)
                             (current-buffer)))))
    (pcase (concur-lock-mode lock)
      (:thread
       ;; For thread mode, the owner is implicitly the current thread.
       ;; `mutex-unlock` will error if not owned, but we add our own error.
       (unless (mutex-owner (concur-lock-native-mutex lock))
         (signal 'concur-lock-error
                 (list (format "Attempt to release an unlocked lock: %s"
                               (concur-lock-name lock))))))
      (_ ;; Cooperative modes
       (unless (concur-lock-locked-p lock)
         (signal 'concur-lock-error
                 (list (format "Attempt to release an unlocked lock: %s"
                               (concur-lock-name lock)))))
       (when (and (concur-lock-owner lock)
                  (not (eq (concur-lock-owner lock) current-owner)))
         (signal 'concur-lock-unowned-release-error
                 (list (format "Cannot release lock %s owned by %S"
                               (concur-lock-name lock)
                               (concur-lock-owner lock)))))))

    (when concur-resource-tracking-function
      (funcall concur-resource-tracking-function :release lock))

    (setf (concur-lock-owner lock) nil)
    (pcase (concur-lock-mode lock)
      (:thread (mutex-unlock (concur-lock-native-mutex lock)))
      (_ (setf (concur-lock-locked-p lock) nil)))
    t))

;;;###autoload
(defmacro concur:with-mutex! (lock-obj &rest body-and-options)
  "Execute BODY within a critical section guarded by `LOCK-OBJ`.
This macro supports an optional `:else` clause for fallback behavior if the
lock cannot be acquired (only for non-blocking `:deferred`/:async modes).

Arguments:
- `LOCK-OBJ` (concur-lock): The lock object.
- `BODY-AND-OPTIONS` (forms): The forms to execute. Can include one
  instance of `(:else <fallback-forms...>)`.

Returns:
  The result of executing either the BODY or the fallback."
  (declare (indent 1) (debug t))
  (let ((main-body '())
        (fallback-forms '((message "Lock %S held, skipping." (concur-lock-name lock-obj)))))
    ;; Parse :else clause from the body.
    (if-let ((else-clause (cl-find :else body-and-options :key #'car)))
        (progn
          (setq fallback-forms (cdr else-clause))
          (setq main-body (cl-remove else-clause body-and-options)))
      (setq main-body body-and-options))

    `(if (concur:lock-acquire ,lock-obj)
         (unwind-protect
             (progn ,@main-body)
           (concur:lock-release ,lock-obj))
       ;; Fallback branch: lock not acquired.
       (progn ,@fallback-forms))))

(provide 'concur-lock)
;;; concur-lock.el ends here