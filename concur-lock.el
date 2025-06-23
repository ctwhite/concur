;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-lock.el --- Mutual Exclusion Locks for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides the `concur-lock` (mutex) primitive for Emacs Lisp.
;; It supports both cooperative (Emacs Lisp-managed) and native
;; (OS-thread-managed) mutexes, ensuring thread-safe access to shared
;; resources across various concurrency modes within the Concur library.
;;
;; Key features include:
;; - **Cooperative Locks**: For single-threaded asynchronous operations
;;   (e.g., `:deferred` mode), preventing re-entry.
;; - **Native Thread Locks**: For true preemptive thread-safety (for
;;   `:thread` mode) using Emacs's underlying native mutexes.
;; - **Resource Tracking Integration**: Hooks into `concur-resource-tracking-function`
;;   to allow higher-level libraries (like `concur-core`) to monitor
;;   resource acquisition and release.

;;; Code:

(require 'cl-lib)    ; For cl-defstruct
(require 'subr-x)    ; For when-let, gensym

;; Ensure native Emacs thread functions are loaded if available.
(when (fboundp 'make-thread) (require 'thread))

(declare-function concur:make-error "concur-core")
(declare-function concur-promise-p "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Error Definitions

(define-error 'concur-lock-error
  "A generic error with a concurrency lock operation."
  'concur-error)
(define-error 'concur-lock-contention-error
  "A lock could not be acquired due to contention."
  'concur-lock-error)
(define-error 'concur-lock-unowned-release-error
  "Attempted to release a lock not owned by the caller."
  'concur-lock-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Resource Tracking

(defvar concur-resource-tracking-function nil
  "A function called by primitives when a resource is acquired or released.
The function should accept two arguments: `ACTION` (a keyword like
`:acquire` or `:release`) and `RESOURCE` (the primitive object itself).
This is intended to be dynamically bound by a higher-level library
(e.g., a promise executor) to associate resource management with a
specific task.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Lock (Mutex) Primitive

(eval-and-compile
  (cl-defstruct (concur-lock (:constructor %%make-lock))
    "A mutual exclusion lock (mutex).

  Arguments:
  - `mode` (symbol): The lock's operating mode (`:deferred`, `:thread`,
    or `:async`). Defaults to `:deferred`.
  - `locked-p` (boolean): `t` if the lock is currently held (for cooperative
    modes). Defaults to `nil`.
  - `native-mutex` (mutex or nil): The underlying native Emacs mutex object
    used in `:thread` mode. Defaults to `nil`.
  - `owner` (any): Identifier of the entity currently holding the lock.
    For `:thread` mode, this is implicitly `current-thread`. For other
    modes, it can be `current-buffer` or a custom identifier. Defaults
    to `nil`.
  - `name` (string): A descriptive name for debugging. Defaults to \"\"."
    (mode :deferred :type (member :deferred :thread :async))
    (locked-p nil :type boolean)
    (native-mutex nil :type (or null (satisfies mutex-p)))
    (owner nil)
    (name "" :type string)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public Lock API

;;;###autoload
(cl-defun concur:make-lock (name &key (mode :deferred))
  "Create a new lock object (mutex).
The lock's behavior depends on its `MODE`:
- `:deferred`, `:async`: Emacs Lisp mutex (cooperative, non-blocking acquire).
- `:thread`: Native OS thread mutex (preemptive, blocking acquire).

  Arguments:
  - `NAME` (string): A descriptive name for debugging.
    If `nil`, a `gensym`-based name is generated.
  - `:MODE` (symbol, optional): The lock's operating mode.
    Defaults to `:deferred`.

  Returns:
  - (concur-lock): A new lock object."
  (unless (memq mode '(:deferred :thread :async))
    (user-error "concur:make-lock: Invalid lock mode: %S. Must be \
                 :deferred, :async, or :thread." mode))
  (let* ((lock-name (or name (format "lock-%S" (gensym))))
         (new-lock (pcase mode
                     (:thread
                      (unless (fboundp 'make-mutex)
                        (user-error "concur:make-lock: Cannot create :thread \
                                     mode mutex without thread support."))
                      (%%make-lock :name lock-name :mode :thread
                                   :native-mutex (make-mutex lock-name)))
                     ((or :async :deferred)
                      (%%make-lock :name lock-name :mode mode)))))
    (concur--log :debug (concur-lock-name new-lock) "Created lock.")
    new-lock))

;;;###autoload
(defun concur:lock-acquire (lock &optional owner)
  "Acquire `LOCK`.
For `:thread` mode, this blocks the calling thread until acquired.
For other modes, it's a non-blocking attempt that returns `nil` if held.

  Arguments:
  - `LOCK` (concur-lock): The lock object.
  - `OWNER` (any, optional): Identifier for the entity acquiring the lock.
    Defaults to `current-thread` for `:thread` mode, or `current-buffer`
    for other modes.

  Returns:
  - (boolean): `t` if the lock was acquired, `nil` otherwise."
  (unless (concur-lock-p lock)
    (user-error "concur:lock-acquire: Invalid lock object: %S" lock))
  (let ((acquired-p nil)
        (effective-owner (or owner
                             (if (eq (concur-lock-mode lock) :thread)
                                 (current-thread)
                               (current-buffer)))))
    (pcase (concur-lock-mode lock)
      (:thread
       (mutex-lock (concur-lock-native-mutex lock))
       (setf (concur-lock-owner lock) effective-owner)
       (setq acquired-p t))
      ((or :async :deferred)
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
      ;; **FIX:** Prevent resource tracking on the registry's own lock
      ;; to avoid infinite recursion.
      (when (and concur-resource-tracking-function
                 (not (and (boundp 'concur--promise-registry-lock)
                           (eq lock concur--promise-registry-lock))))
        (funcall concur-resource-tracking-function :acquire lock)))
    acquired-p))

;;;###autoload
(defun concur:lock-release (lock &optional owner)
  "Release `LOCK`. Requires the caller to be the owner of the lock.

  Arguments:
  - `LOCK` (concur-lock): The lock object to release.
  - `OWNER` (any, optional): Identifier of the entity releasing the lock.
    Defaults to `current-thread` for `:thread` mode, or `current-buffer`
    for other modes.

  Returns:
  - `t` if the lock was successfully released.

  Signals:
  - `concur-lock-error`: if the lock is already unlocked.
  - `concur-lock-unowned-release-error`: if attempted by a non-owner."
  (unless (concur-lock-p lock)
    (user-error "concur:lock-release: Invalid lock object: %S" lock))
  (let ((effective-owner (or owner
                             (if (eq (concur-lock-mode lock) :thread)
                                 (current-thread)
                               (current-buffer)))))
    (pcase (concur-lock-mode lock)
      (:thread
       ;; For thread mode, the owner is implicitly the current thread.
       ;; `mutex-unlock` will error if not owned, so we check first.
       (unless (mutex-owner (concur-lock-native-mutex lock))
         (user-error "concur:lock-release: Attempt to release an unlocked \
                      :thread lock: %S" (concur-lock-name lock))))
      ((or :async :deferred) ;; Cooperative modes
       (unless (concur-lock-locked-p lock)
         (user-error "concur:lock-release: Attempt to release an unlocked \
                      cooperative lock: %S" (concur-lock-name lock)))
       (when (and (concur-lock-owner lock)
                  (not (eq (concur-lock-owner lock) effective-owner)))
         (user-error "concur:lock-release: Cannot release lock %S owned by %S \
                      (caller is %S)"
                     (concur-lock-name lock)
                     (concur-lock-owner lock)
                     effective-owner))))

    ;; Perform resource tracking cleanup before actual lock release.
    ;; **FIX:** Prevent resource tracking on the registry's own lock.
    (when (and concur-resource-tracking-function
               (not (and (boundp 'concur--promise-registry-lock)
                         (eq lock concur--promise-registry-lock))))
      (funcall concur-resource-tracking-function :release lock))

    (setf (concur-lock-owner lock) nil)
    (pcase (concur-lock-mode lock)
      (:thread (mutex-unlock (concur-lock-native-mutex lock)))
      ((or :async :deferred) (setf (concur-lock-locked-p lock) nil)))
    (concur--log :debug (concur-lock-name lock) "Released lock by %S."
                 effective-owner)
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
  - (any): The result of executing either the BODY or the fallback."
  (declare (indent 1) (debug t))
  (let ((main-body '())
        (fallback-forms '((concur--log :warn nil "Lock %S held, skipping."
                                        (concur-lock-name lock-obj)))))
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

;;;###autoload
(cl-defun concur:lock-status (lock)
  "Return a snapshot of the `LOCK`'s current status.

  Arguments:
  - `LOCK` (concur-lock): The lock to inspect.

  Returns:
  - (plist): A property list with lock metrics:
    `:name`: Name of the lock.
    `:mode`: Concurrency mode (:deferred, :thread, :async).
    `:locked-p`: Whether the lock is currently held.
    `:owner`: Identifier of the current lock owner (if locked).
    `:native-mutex-p`: Whether it's a native mutex (for :thread mode)."
  (interactive)
  (unless (concur-lock-p lock)
    (user-error "concur:lock-status: Invalid lock object: %S" lock))
  `(:name ,(concur-lock-name lock)
    :mode ,(concur-lock-mode lock)
    :locked-p ,(concur-lock-locked-p lock)
    :owner ,(concur-lock-owner lock)
    :native-mutex-p ,(not (null (concur-lock-native-mutex lock)))))

(provide 'concur-lock)
;;; concur-lock.el ends here