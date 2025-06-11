;;; concur-primitives.el --- Concurrency Primitives for Emacs Lisp -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides basic concurrency primitives for Emacs Lisp,
;; including macros for ensuring code runs once, and for managing locks
;; (mutexes) and semaphores to protect critical sections and manage resource access.
;;
;; Features:
;; - `concur:once-do!`: Ensures a block of code runs only once.
;; - `concur:make-lock`, `concur:lock-acquire`, `concur:lock-release`:
;;   Functions for creating and managing explicit lock objects (mutexes).
;; - `concur:with-mutex!`: A macro for defining critical sections using lock objects.
;; - `concur:block-until`: A cooperative blocking primitive that yields control
;;   until a condition is met or a timeout occurs.
;; - Semaphores: `concur:make-semaphore`, `concur:semaphore-acquire`,
;;   `concur:semaphore-try-acquire`, `concur:semaphore-release`,
;;   and `concur:with-semaphore!`.
;;
;; These primitives are designed to be lightweight and suitable for common
;; concurrency patterns within single-threaded, cooperative environments like
;; Emacs Lisp. They rely on atomic operations where possible and
;; `unwind-protect` to ensure proper resource cleanup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'concur-core)

(define-error 'concur:timeout-error "Concurrency timeout error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Once Execution Primitives

;;;###autoload
(defmacro concur:once-do! (place fallback &rest body)
  "Run BODY once if PLACE is nil, otherwise run FALLBACK.

This macro ensures a block of code is executed only once based on
the state of PLACE. If PLACE is nil, BODY is executed and PLACE is
set to `t`. If PLACE is already non-nil, FALLBACK is executed.

Arguments:
- `PLACE`: A variable or place that determines whether the body should execute.
- `FALLBACK`: The code to run if PLACE is non-nil. Can be a single form
  or a list of forms starting with `:else`, e.g., `(:else FORM...)`.
- `BODY`: The code to run once if PLACE is nil.

Returns:
The result of BODY or FALLBACK."
  (declare (indent 2))
  (let ((fallback-forms (if (and (consp fallback) (eq (car fallback) :else))
                            (cdr fallback)
                          (list fallback))))
    `(if ,place
         (progn ,@fallback-forms)
       (unwind-protect
           (progn ,@body)
         (setf ,place t)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Lock (Mutex) Primitives

(eval-and-compile
  (cl-defstruct (concur-lock (:constructor %%make-lock))
    "A simple mutual exclusion lock (mutex)."
    (locked-p nil "A flag indicating if the lock is held." :type boolean)
    (owner nil "The entity that currently holds the lock.")
    (name nil "A descriptive name for the lock, for debugging.")))

;;;###autoload
(defun concur:make-lock (&optional name)
  "Create a new lock object (mutex).

Arguments:
- `NAME` (string, optional): A descriptive name for debugging purposes.

Returns:
A new lock object initialized to an unlocked state."
  (%%make-lock :name (or name (format "lock-%s" (gensym)))))

;;;###autoload
(defun concur:lock-acquire (lock &optional owner)
  "Try to acquire LOCK, optionally for OWNER. Non-blocking.
In Emacs's single-threaded environment, this operation is not
truly atomic but serves as a cooperative locking mechanism.

Arguments:
- `LOCK` (concur-lock): A lock object created by `concur:make-lock`.
- `OWNER` (any, optional): An identifier for the entity acquiring the lock.

Returns:
`t` if the lock was successfully acquired, `nil` otherwise."
  (unless (concur-lock-p lock)
    (error "Invalid lock object provided to concur:lock-acquire"))
  (unless (concur-lock-locked-p lock)
    (setf (concur-lock-locked-p lock) t)
    (setf (concur-lock-owner lock) owner)
    t))

;;;###autoload
(defun concur:lock-release (lock &optional owner)
  "Release LOCK, optionally checking for OWNER.

Arguments:
- `LOCK` (concur-lock): The lock object to release.
- `OWNER` (any, optional): If non-nil, the lock is only released
  if `OWNER` matches the current lock owner.

Returns:
`t` if the lock was successfully released.

Errors:
- If `OWNER` is provided and does not match the current lock owner."
  (unless (concur-lock-p lock)
    (error "Invalid lock object provided to concur:lock-release"))
  ;; If an owner is specified for release, it MUST match the current owner.
  (when (and owner (concur-lock-owner lock)
             (not (eq owner (concur-lock-owner lock))))
    (error "Task %S cannot release lock owned by %S"
           owner (concur-lock-owner lock)))
  (setf (concur-lock-locked-p lock) nil)
  (setf (concur-lock-owner lock) nil)
  t)

;;;###autoload
(defmacro concur:with-mutex! (lock-obj fallback &rest body)
  "Execute BODY within a critical section guarded by LOCK-OBJ.
This macro attempts to acquire `LOCK-OBJ`. If successful, it
executes BODY and guarantees the lock is released afterward, even
in the case of an error. If the lock is already held, it executes
the FALLBACK forms.

Arguments:
- `LOCK-OBJ`: A lock object created by `concur:make-lock`.
- `FALLBACK`: Code to execute if the lock cannot be acquired. Can be a
  single form or a list of forms starting with `:else`.
- `BODY`: The forms to execute while holding the lock.

Returns:
The result of BODY or FALLBACK."
  (declare (indent 2))
  (let ((fallback-forms (if (and (consp fallback) (eq (car fallback) :else))
                            (cdr fallback)
                          (list fallback)))
        (owner-sym (gensym "lock-owner-")))
    `(let ((,owner-sym (gensym "task-")))
       (if (concur:lock-acquire ,lock-obj ,owner-sym)
           (unwind-protect
               (progn ,@body)
             (concur:lock-release ,lock-obj ,owner-sym))
         (progn ,@fallback-forms)))))

;;;###autoload
(defmacro concur:with-lock! (place fallback &rest body)
  "A simplified mutex using a variable (PLACE) as the lock.
This macro is a simpler version of `concur:with-mutex!` that uses
any non-nil value in PLACE to signify a locked state. It's less
robust than object-based locks but useful for simple cases.

Arguments:
- `PLACE`: A variable or place to use as the lock.
- `FALLBACK`: Code to execute if the lock is held (if PLACE is non-nil).
- `BODY`: The forms to execute while holding the lock.

Returns:
The result of BODY or FALLBACK."
  (declare (indent 2))
  (let ((fallback-forms (if (and (consp fallback) (eq (car fallback) :else))
                            (cdr fallback)
                          (list fallback))))
    `(if ,place
         (progn ,@fallback-forms)
       (unwind-protect
           (progn
             (setf ,place t)
             ,@body)
         (setf ,place nil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Blocking Primitives

;;;###autoload
(cl-defun concur:block-until
    (test success-callback
          &key timeout interval meta error-function timeout-callback
          (start-time (float-time)))
  "Block cooperatively until TEST returns non-nil, then run SUCCESS-CALLBACK.
This function does not block Emacs's main thread. Instead, it
uses a timer to periodically re-check the `TEST` function.

Arguments:
- `TEST` (function): A zero-argument function. Blocking stops when it returns non-nil.
- `SUCCESS-CALLBACK` (function): A zero-argument function called upon success.
- `:timeout` (float, optional): Maximum seconds to wait.
- `:interval` (float, optional): Seconds between checks. Defaults to 0.1.
- `:meta` (any, optional): Arbitrary metadata for logging/tracking.
- `:error-function` (function, optional): A function `(lambda (meta))` called
  on timeout if `:timeout-callback` is not set.
- `:timeout-callback` (function, optional): A zero-argument function called
  on timeout. Takes precedence over `:error-function`.
- `:start-time` (float, internal): Do not set manually.

Returns:
`nil`. The result is delivered via callbacks."
  (if (funcall test)
      ;; Condition met, execute success path.
      (funcall success-callback)
    ;; Condition not met, check for timeout.
    (if (and timeout (> (- (float-time) start-time) timeout))
        ;; Timeout occurred.
        (progn
          (concur--log :warn "concur:block-until: Timeout for: %S" meta)
          (cond (timeout-callback (funcall timeout-callback))
                (error-function (funcall error-function meta))
                (t (error 'concur:timeout-error
                          (format "Timeout waiting for: %S" meta)))))
      ;; No timeout, re-schedule the check.
      (run-with-timer (or interval 0.1) nil
                      #'(lambda ()
                          (concur:block-until
                           test success-callback
                           :timeout timeout :interval interval :meta meta
                           :error-function error-function
                           :timeout-callback timeout-callback
                           :start-time start-time))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Semaphore Primitives

(eval-and-compile
  (cl-defstruct (concur-semaphore (:constructor %%make-semaphore))
    "A semaphore object for controlling concurrent access."
    (count 0 "The current number of available slots." :type integer)
    (max-count 0 "The maximum number of available slots." :type integer)
    (lock (concur:make-lock) "A mutex to protect internal state." :type t)
    (name nil "A descriptive name for debugging.")))

;;;###autoload
(defun concur:make-semaphore (n &optional name)
  "Create a semaphore with N available slots.

Arguments:
- `N` (integer): The initial (and maximum) number of available slots.
- `NAME` (string, optional): A descriptive name for debugging.

Returns:
A new semaphore object."
  (unless (and (integerp n) (>= n 0))
    (error "Semaphore count must be a non-negative integer: %S" n))
  (%%make-semaphore
   :count n
   :max-count n
   :name (or name (format "sem-%s" (gensym)))
   :lock (concur:make-lock (format "sem-lock-%s" (or name "anon")))))

;;;###autoload
(defun concur:semaphore-try-acquire (sem)
  "Try to acquire SEM without blocking.
This function immediately attempts to acquire one slot from the
semaphore. It is non-blocking and returns instantly.

Arguments:
- `SEM` (concur-semaphore): The semaphore to acquire.

Returns:
`t` if a slot was successfully acquired, `nil` otherwise."
  (unless (concur-semaphore-p sem)
    (error "Not a valid semaphore: %S" sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
      (:else (concur--log :warn "Semaphore %S lock contention on try-acquire"
                          (concur-semaphore-name sem))
             nil)
    (if (> (concur-semaphore-count sem) 0)
        (progn
          (cl-decf (concur-semaphore-count sem))
          t)
      nil)))

;;;###autoload
(defun concur:semaphore-release (sem)
  "Release one slot in SEM.
Increments the semaphore's count of available slots. If the count
exceeds the maximum (e.g., due to extra releases), it is capped.

Arguments:
- `SEM` (concur-semaphore): The semaphore to release.

Returns:
The new count of the semaphore."
  (unless (concur-semaphore-p sem)
    (error "Not a valid semaphore: %S" sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
      (:else (error "Semaphore %S lock contention on release"
                    (concur-semaphore-name sem)))
    ;; Increment the count of available slots.
    (cl-incf (concur-semaphore-count sem))
    ;; Ensure the count does not exceed the max.
    (when (> (concur-semaphore-count sem) (concur-semaphore-max-count sem))
      (setf (concur-semaphore-count sem) (concur-semaphore-max-count sem)))
    (concur-semaphore-count sem)))

;;;###autoload
(defun concur:semaphore-acquire (sem success-callback
                                 &key timeout timeout-callback)
  "Acquire a slot from SEM, blocking cooperatively if necessary.
This function attempts to acquire a slot from `SEM`. If no slots
are available, it will block cooperatively using
`concur:block-until`, waiting for a slot to be freed.

Arguments:
- `SEM` (concur-semaphore): The semaphore to acquire.
- `SUCCESS-CALLBACK` (function): A zero-argument function called when a
  slot is successfully acquired.
- `:timeout` (float, optional): Maximum seconds to wait for a slot.
- `:timeout-callback` (function, optional): A zero-argument function
  called if the timeout is reached.

Returns:
`nil`. The result is delivered via callbacks."
  (unless (concur-semaphore-p sem)
    (error "Not a valid semaphore: %S" sem))
  ;; First, try a quick, non-blocking acquire.
  (if (concur:semaphore-try-acquire sem)
      (funcall success-callback)
    ;; If that fails, start the cooperative blocking process.
    (concur:block-until
     ;; The test condition is another attempt to acquire the lock.
     #'(lambda () (concur:semaphore-try-acquire sem))
     ;; The success callback is the one provided by the user.
     success-callback
     :timeout timeout
     :timeout-callback timeout-callback
     :meta `(semaphore-acquire ,(concur-semaphore-name sem)))))

;;;###autoload
(defmacro concur:with-semaphore! (sem-obj fallback &rest body)
  "Execute BODY after acquiring a slot from SEM-OBJ.
This macro wraps `concur:semaphore-acquire` to provide a convenient
block-based syntax. It acquires a semaphore slot and executes
BODY. The semaphore is always released afterward. The process is
fully asynchronous and cooperative.

Arguments:
- `SEM-OBJ`: The semaphore object to acquire.
- `FALLBACK`: Code to execute if acquiring the semaphore times out.
  Can be a single form or `(:else ...)` forms.
- `BODY`: The forms to execute while holding the semaphore slot.
  Can also contain keyword arguments like `:timeout` for the acquire operation.

Returns:
`nil`. BODY is executed asynchronously within a callback."
  (declare (indent 2))
  (let* ((params (cl-loop for (key val) on body by #'cddr
                          while (keywordp key)
                          collect key and collect val))
         (body-forms (cl-loop for sublist on body by #'cddr
                              unless (keywordp (car sublist))
                              return sublist))
         (fallback-forms (if (and (consp fallback) (eq (car fallback) :else))
                             (cdr fallback)
                           (list fallback))))
    `(concur:semaphore-acquire
      ,sem-obj
      #'(lambda ()
          (unwind-protect
              (progn ,@body-forms)
            (concur:semaphore-release ,sem-obj)))
      :timeout-callback #'(lambda () ,@fallback-forms)
      ,@params)))

(provide 'concur-primitives)
;;; concur-primitives.el ends here