;;; concur-primitives.el --- Concurrency Primitives for Emacs Lisp -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides basic concurrency primitives for Emacs Lisp,
;; including macros for ensuring code runs once, and for managing locks
;; (mutexes) and semaphores to protect critical sections and manage resource
;; access in a cooperative, single-threaded environment.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'concur-hooks)

(define-error 'concur:timeout-error "A concurrency operation timed out.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Once Execution Primitives

;;;###autoload
(defmacro concur:once-do! (place fallback &rest body)
  "Run BODY once if PLACE is nil, otherwise run FALLBACK.
This macro provides a simple mechanism to ensure a block of code is executed
only a single time.

Arguments:
- PLACE: A variable or place that determines whether the body should execute.
- FALLBACK: The code to run if PLACE is already non-nil. Can be a single
  form or a list of forms starting with `:else`, e.g., `(:else ...)`.
- BODY: The code to run once if PLACE is nil.

Returns:
The result of executing either the BODY or the FALLBACK forms."
  (declare (indent 1) (debug t))
  (let ((fallback-forms (if (and (consp fallback) (eq (car fallback) :else))
                            (cdr fallback)
                          (list fallback))))
    `(if ,place
         (progn ,@fallback-forms)
       (unwind-protect
           (progn ,@body)
         (setf ,place t)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Lock (Mutex) Primitives

(eval-and-compile
  (cl-defstruct (concur-lock (:constructor %%make-lock))
    "A simple mutual exclusion lock (mutex).

Fields:
- `locked-p` (boolean): A flag indicating if the lock is held.
- `owner` (any): The entity that currently holds the lock.
- `name` (string): A descriptive name for the lock, for debugging."
    (locked-p nil :type boolean)
    (owner nil)
    (name nil)))

;;;###autoload
(defun concur:make-lock (&optional name)
  "Create a new lock object (mutex).

Arguments:
- NAME (string, optional): A descriptive name for debugging purposes.

Returns:
A new `concur-lock` object, initialized to an unlocked state."
  (%%make-lock :name (or name (format "lock-%s" (gensym)))))

;;;###autoload
(defun concur:lock-acquire (lock &optional owner)
  "Try to acquire LOCK non-blockingly.

Arguments:
- LOCK (`concur-lock`): A lock object created by `concur:make-lock`.
- OWNER (any, optional): An identifier for the entity acquiring the lock.

Returns:
`t` if the lock was successfully acquired, `nil` otherwise."
  (unless (concur-lock-p lock)
    (error "Invalid lock object to concur:lock-acquire"))
  (unless (concur-lock-locked-p lock)
    (setf (concur-lock-locked-p lock) t)
    (setf (concur-lock-owner lock) owner)
    t))

;;;###autoload
(defun concur:lock-release (lock &optional owner)
  "Release LOCK, optionally checking for OWNER.

Arguments:
- LOCK (`concur-lock`): The lock object to release.
- OWNER (any, optional): If non-nil, the lock is only released if OWNER
  matches the current lock owner.

Returns:
`t` if the lock was successfully released."
  (unless (concur-lock-p lock)
    (error "Invalid lock object to concur:lock-release"))
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
If the lock is acquired, executes BODY and guarantees release.
If the lock is already held, executes FALLBACK instead.

Arguments:
- LOCK-OBJ: A `concur-lock` object.
- FALLBACK: Code to execute if the lock cannot be acquired. Can be a
  single form or a list of forms starting with `:else`.
- BODY: The forms to execute while holding the lock.

Returns:
The result of BODY or FALLBACK."
  (declare (indent 1) (debug t))
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
Uses any non-nil value in PLACE to signify a locked state.

Arguments:
- PLACE: A variable or place to use as the lock.
- FALLBACK: Code to execute if the lock is held (if PLACE is non-nil).
- BODY: The forms to execute while holding the lock.

Returns:
The result of BODY or FALLBACK."
  (declare (indent 1) (debug t))
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Blocking Primitives

;;;###autoload
(cl-defun concur:block-until
    (test success-callback
          &key timeout interval label error-function timeout-callback
          (start-time (float-time)))
  "Block cooperatively until TEST returns non-nil, then run SUCCESS-CALLBACK.
This uses a timer to periodically re-check the `TEST` function.

Arguments:
- TEST (function): A zero-argument function; stops when it returns non-nil.
- SUCCESS-CALLBACK (function): A zero-argument function called upon success.
- :TIMEOUT (float): Optional maximum seconds to wait.
- :INTERVAL (float): Optional seconds between checks. Defaults to 0.1.
- :LABEL (any): Optional metadata for logging/tracking.
- :ERROR-FUNCTION (function): Function `(lambda (label))` called on timeout.
- :TIMEOUT-CALLBACK (function): Zero-arg function called on timeout.
  Takes precedence over `:error-function`.
- :START-TIME (float, internal): Do not set manually.

Returns:
`nil`. The result is delivered via callbacks."
  (if (funcall test)
      (funcall success-callback)
    (if (and timeout (> (- (float-time) start-time) timeout))
        (progn
          (concur--log :warn "concur:block-until: Timeout for: %S" label)
          (cond (timeout-callback (funcall timeout-callback))
                (error-function (funcall error-function label))
                (t (error 'concur:timeout-error
                          (format "Timeout waiting for: %S" label)))))
      (run-with-timer (or interval 0.1) nil
                      #'(lambda ()
                          (concur:block-until
                           test success-callback
                           :timeout timeout :interval interval :label label
                           :error-function error-function
                           :timeout-callback timeout-callback
                           :start-time start-time))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Semaphore Primitives

(eval-and-compile
  (cl-defstruct (concur-semaphore (:constructor %%make-semaphore))
    "A semaphore for controlling access to a finite number of resources.

Fields:
- `count` (integer): The current number of available slots.
- `max-count` (integer): The maximum number of available slots.
- `lock` (concur-lock): A mutex to protect internal state.
- `name` (string): A descriptive name for debugging."
    (count 0 :type integer)
    (max-count 0 :type integer)
    (lock nil :type concur-lock)
    (name nil)))

;;;###autoload
(defun concur:make-semaphore (n &optional name)
  "Create a semaphore with N available slots.

Arguments:
- N (integer): The initial (and maximum) number of available slots.
- NAME (string, optional): A descriptive name for debugging.

Returns:
A new `concur-semaphore` object."
  (unless (and (integerp n) (>= n 0))
    (error "Semaphore count must be a non-negative integer: %S" n))
  (%%make-semaphore
   :count n :max-count n
   :name (or name (format "sem-%s" (gensym)))
   :lock (concur:make-lock (format "sem-lock-%s" (or name "anon")))))

;;;###autoload
(defun concur:semaphore-try-acquire (sem)
  "Try to acquire SEM without blocking.

Arguments:
- SEM (`concur-semaphore`): The semaphore to acquire.

Returns:
`t` if a slot was successfully acquired, `nil` otherwise."
  (unless (concur-semaphore-p sem) (error "Not a valid semaphore: %S" sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
      (:else (concur--log :warn "Semaphore %S lock contention on try-acquire"
                          (concur-semaphore-name sem))
             nil)
    (if (> (concur-semaphore-count sem) 0)
        (progn (cl-decf (concur-semaphore-count sem)) t)
      nil)))

;;;###autoload
(defun concur:semaphore-release (sem)
  "Release one slot in SEM.
Increments the semaphore's available slots count. Signals an error if the
semaphore is already at its maximum capacity, which indicates a logic
error (releasing more than was acquired).

Arguments:
- SEM (`concur-semaphore`): The semaphore to release.

Returns:
The new count of the semaphore."
  (unless (concur-semaphore-p sem) (error "Not a valid semaphore: %S" sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
      (:else (error "Semaphore %S lock contention on release"
                    (concur-semaphore-name sem)))
    ;; The fix for the design flaw is here.
    (if (>= (concur-semaphore-count sem) (concur-semaphore-max-count sem))
        (error "Cannot release semaphore '%s': already at maximum capacity (%d)"
               (concur-semaphore-name sem) (concur-semaphore-max-count sem))
      (cl-incf (concur-semaphore-count sem)))))

;;;###autoload
(cl-defun concur:semaphore-acquire (sem success-callback
                                       &key timeout timeout-callback)
  "Acquire a slot from SEM, blocking cooperatively if necessary."
  (unless (concur-semaphore-p sem) (error "Not a valid semaphore: %S" sem))
  (if (concur:semaphore-try-acquire sem)
      (funcall success-callback)
    (concur:block-until
     #'(lambda () (concur:semaphore-try-acquire sem))
     success-callback
     :timeout timeout
     :timeout-callback timeout-callback
     :label `(semaphore-acquire ,(concur-semaphore-name sem)))))

;;;###autoload
(defmacro concur:with-semaphore! (sem-obj fallback &rest body)
  "Execute BODY after acquiring a slot from SEM-OBJ.
Wraps `concur:semaphore-acquire` for a convenient block-based syntax. It
acquires a semaphore slot and executes BODY, always releasing the semaphore
afterward. This process is fully asynchronous and cooperative.

Arguments:
- SEM-OBJ: The semaphore object to acquire.
- FALLBACK: Code to execute if acquiring the semaphore times out.
  Can be a single form or `(:else ...)` forms.
- BODY: The forms to execute, optionally with `:timeout` as a keyword arg
  for the underlying acquire operation.

Returns:
`nil`. BODY is executed asynchronously within a callback."
  (declare (indent 1) (debug t))
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