;;; concur-primitives.el --- Concurrency Primitives for Emacs Lisp -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Your Name

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; This library provides basic concurrency primitives for Emacs Lisp,
;; including macros for ensuring code runs once, and for managing locks
;; (mutexes) to protect critical sections.
;;
;; Features:
;; - `once-do!`: Ensures a block of code runs only once.
;; - `once-callback!`: A specialized version of `once-do!` for executing a callback once.
;; - `with-lock!`: A basic mutual exclusion lock for temporary critical sections.
;; - `concur-lock-create`, `concur-lock-acquire`, `concur-lock-release`:
;;   Functions for creating and managing explicit lock objects (mutexes).
;; - `with-mutex!`: A macro that uses the explicit lock objects (`concur-lock-*` functions)
;;   to define critical sections.
;; - `concur-block-until`: A cooperative blocking primitive that yields control
;;   until a condition is met or a timeout occurs.
;; - Semaphores: `concur-semaphore-new`, `concur-semaphore-acquire`,
;;   `concur-semaphore-try-acquire`, `concur-semaphore-release`, `concur-semaphore-reset`,
;;   `concur-semaphore-describe`, and `with-semaphore!`.
;;
;; These primitives are designed to be simple and lightweight, suitable for
;; common concurrency patterns within Emacs Lisp where true multi-threading
;; is not available. They rely on atomic operations where possible (e.g., `setf`
;; on a place) and `unwind-protect` to ensure proper resource cleanup.

;;; Code:

(require 'cl-lib)     ; For cl-lib functions, cl-defstruct, cl-incf, cl-decf
(require 'gv)         ; For generalized variables if `place` is not a simple symbol
(require 'subr-x)     ; For `when-let`
(require 'scribe)

;; Define a custom error type for timeouts
(define-error 'concur-timeout-error "Concurrency timeout error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Once Execution Primitives                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro once-do! (place fallback &rest body)
  "Run BODY once if PLACE is nil. Otherwise, run FALLBACK.

This macro ensures that a block of code is executed only once based on the
state of PLACE. If PLACE is nil, BODY is executed, and PLACE is set to `t`.
If PLACE is non-nil, FALLBACK is executed instead. FALLBACK can be either
a single form or a list of forms (e.g., `(:else FORM...)`).

Arguments:
- PLACE: A variable or place (could be a symbol or a generalized variable)
  that determines whether the body of code should be executed.
- FALLBACK: The code to run if PLACE is non-nil. Can either be a single value or
  a list of forms (e.g., `(:else FORM...)`).
- BODY: The code to run once if PLACE is nil.

Side Effects:
- Sets PLACE to `t` after executing BODY (if BODY completes successfully).
- If PLACE is non-nil, executes FALLBACK instead of BODY.
- Signals an error if PLACE is not a valid `setf`-able place.

Example:
  (let ((my-flag nil))
    (once-do! my-flag
      (message \"Running for the first time\"))
    (once-do! my-flag
      (message \"Already run!\")))
"
  (declare (indent 2))
  ;; Ensure fallback is always a list for progn
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     (list fallback))))
    `(if ,place
         (progn ,@else-body)
       (progn
         ;; Mark the place as 'running' or 'done' immediately to prevent re-entry.
         ;; `setf` works for both symbols and generalized variables.
         (setf ,place t)
         ,@body))))

;;;###autoload
(defmacro once-callback! (flag callback &rest fallback)
  "Invoke CALLBACK once if FLAG is nil. Otherwise, run FALLBACK.

This macro is a specialized version of `once-do!` that specifically
handles a callback function. It ensures that CALLBACK is called
only once, when FLAG is nil. If FLAG is non-nil, the code in
FALLBACK is executed.

Arguments:
- FLAG: A variable or place that determines whether the callback
  should be executed.
- CALLBACK: A function to call when FLAG is nil. If this is nil,
  nothing happens when FLAG is nil.
- FALLBACK: Code to execute if FLAG is non-nil. This can be a single
  form or a list of forms, as in `once-do!`.

Side Effects:
- Sets FLAG to `t` after executing CALLBACK.
- If FLAG is non-nil, executes FALLBACK.
- Signals an error if FLAG is not a valid `setf`-able place.

Example:
  (let ((my-flag nil))
    (once-callback! my-flag (lambda () (message \"Callback called\"))
                    (message \"Fallback called\"))
    (once-callback! my-flag (lambda () (message \"Callback called again\"))
                    (message \"Fallback called again\")))
"
  (declare (indent 2))
  `(once-do! ,flag
     (:else ,@fallback)
     (when ,callback
       (funcall ,callback))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Basic Lock (Mutex) Primitives                      ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro with-lock! (place fallback &rest body)
  "Acquire a lock on PLACE temporarily during the execution of BODY.

This macro ensures that the code in BODY will only execute if PLACE is not
locked. If PLACE is already locked (non-nil), FALLBACK will be executed
instead. The lock is released after the execution of BODY, regardless of
whether BODY is successful or not. This provides a basic mutual
exclusion mechanism.

Arguments:
- PLACE: A place (e.g., a symbol or generalized variable) that acts as a
  lock. The value at this place should be nil when the lock is free,
  and non-nil (typically t) when the lock is held.
- FALLBACK: Code to execute if PLACE is already locked. This can be a
  single form or a list of forms, as in `once-do!`.
- BODY: Code that will run while PLACE is locked. It is crucial that
  this code does not throw any errors, or that all errors are
  handled, to ensure the lock is always released.

Side Effects:
- Sets PLACE to `t` temporarily during the execution of BODY.
- Releases the lock on PLACE after executing BODY, even if errors occur.
- Signals an error if PLACE is not a valid `setf`-able place.

Example:
  (let ((my-lock nil))
    (with-lock! my-lock
      (message \"Lock acquired\")
      (message \"Doing something critical\"))
    (with-lock! my-lock
      (message \"Lock was held by someone else\")))
"
  (declare (indent 2))
  ;; Ensure fallback is always a list for progn
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     (list fallback))))
    `(if ,place
         (progn ,@else-body)
       (progn
         ;; Acquire the lock by setting PLACE to non-nil (t).
         (setf ,place t)
         (unwind-protect
             (progn ,@body)
           ;; Release the lock by setting PLACE back to nil, even if BODY errors.
           (setf ,place nil))))))

;;;###autoload
(defun concur-lock-create (&optional name)
  "Create a new lock object.

Optional NAME is used for debugging/logging purposes.
Returns a plist representing the lock, initialized to unlocked."
  (list :locked nil
        :owner nil
        :name (or name (format "lock-%s" (gensym)))))

;;;###autoload
(defun concur-lock-acquire (lock task)
  "Try to acquire LOCK for TASK.

LOCK must be a plist representing the lock, typically created by `concur-lock-create`.
TASK is an identifier for the entity attempting to acquire the lock (e.g., a process, a function, a timestamp).
Returns t if acquired, nil otherwise. This function does not block.
Modifies the LOCK plist in place."
  (interactive (error "Not interactive")) ; Not meant for direct interactive use
  (unless (plist-get lock :locked)
    (setf (plist-get lock :locked) t)
    (setf (plist-get lock :owner) task)
    t))

;;;###autoload
(defun concur-lock-release (lock task)
  "Release LOCK if TASK is the owner.

LOCK must be a plist representing the lock.
TASK is the identifier of the entity attempting to release the lock.
Modifies the LOCK plist in place.
Raises an error if the lock is not held by TASK, or if it's not locked at all."
  (interactive (error "Not interactive")) ; Not meant for direct interactive use
  (unless (plist-get lock :locked)
    (error "concur-lock-release: Lock %S is not currently held." (plist-get lock :name)))
  (unless (eq (plist-get lock :owner) task)
    (error "concur-lock-release: task %S does not own lock %S (current owner: %S)"
           task (plist-get lock :name) (plist-get lock :owner)))
  (setf (plist-get lock :locked) nil)
  (setf (plist-get lock :owner) nil))

;;;###autoload
(defmacro with-mutex! (lock-obj fallback &rest body)
  "Acquire LOCK-OBJ temporarily during the execution of BODY.

LOCK-OBJ must be a lock object (plist) created by `concur-lock-create`.
If the lock cannot be acquired (because it's already held), FALLBACK is executed.
The lock is guaranteed to be released after BODY completes, even if BODY
encounters an error.

Arguments:
- LOCK-OBJ: A lock object (plist) created by `concur-lock-create`.
- FALLBACK: Code to execute if the lock cannot be acquired. This can be a
  single form or a list of forms, as in `once-do!`.
- BODY: Code that will run while the lock is held.

Example:
  (let ((my-mutex (concur-lock-create)))
    (with-mutex! my-mutex
      (message \"Mutex acquired\")
      (message \"Critical section\"))
    (with-mutex! my-mutex (:else (message \"Mutex already held\"))
      (message \"This will not run\")))
"
  (declare (indent 2))
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     (list fallback)))
        (task-id (gensym "task-id"))) ; Unique ID for this execution context
    `(let ((,task-id (current-time))) ; Use current-time as a simple unique ID for the owner
       (if (concur-lock-acquire ,lock-obj ,task-id)
           (unwind-protect
               (progn ,@body)
             (concur-lock-release ,lock-obj ,task-id))
         (progn ,@else-body)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Blocking Primitives                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defun concur-block-until (test success-callback &key timeout interval meta error-function 
                                                         timeout-callback (start-time (float-time)) (step 0))
  "Block cooperatively until TEST returns non-nil.
  When the condition is met, SUCCESS-CALLBACK is called.
  If a timeout occurs, TIMEOUT-CALLBACK (if provided) or ERROR-FUNCTION (if provided) is called.

  This function cooperatively waits for a condition to become true. It does not
  block Emacs. Instead, it schedules itself to re-check the condition after a
  short `interval`.

  Arguments:
  - TEST (function): A zero-argument function that returns non-nil when the condition is met.
  - SUCCESS-CALLBACK (function): A zero-argument function to call when TEST returns non-nil.
  - :timeout SECONDS (float, optional): Maximum time to wait in seconds.
  - :interval SECONDS (float, optional): Minimum time in seconds between re-check attempts. Defaults to 0.1.
  - :meta METADATA (any, optional): Arbitrary metadata for logging or tracking.
  - :error-function (function, optional): A function (meta) to call if a timeout occurs.
  - :timeout-callback (function, optional): A zero-argument function to call if a timeout occurs.
  - :start-time (float, internal): Do not set manually. Timestamp when blocking started.
  - :step (integer, internal): Do not set manually. Counter for re-check attempts.
  "
  (let* ((current-time (float-time))
         (sem-name (or (plist-get meta :semaphore) "unknown-semaphore"))) ; For logging context

    (log! :debug "concur-block-until: Checking condition for %S (step: %d)" sem-name step)

    ;; 1. Check condition
    (if (funcall test)
        (progn
          (log! :debug "concur-block-until: Condition met for %S. Calling success-callback." sem-name)
          (funcall success-callback))
      ;; 2. Condition not met, check for timeout
      (when (and timeout (> (- current-time start-time) timeout))
        (log! :warn "concur-block-until: Timeout while waiting for %S: %S" sem-name meta)
        (if timeout-callback
            (funcall timeout-callback)
          (if error-function
              (funcall error-function meta)
            (log! :error "concur-block-until: Timeout error function/callback not provided for %S" meta))))
      ;; 3. Condition not met and no timeout, so re-queue
      (progn
        (setq step (1+ step))
        ;; Schedule the next check
        (run-with-timer (or interval 0.1) nil
                        (lambda ()
                          (concur-block-until test success-callback
                                              :timeout timeout :interval interval :meta meta
                                              :error-function error-function :timeout-callback timeout-callback
                                              :start-time start-time :step step)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Semaphore Primitives                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (concur-semaphore
               (:constructor concur-semaphore-create (count queue lock data max-count &optional name)))
  "A semaphore object for controlling concurrent access.
  Fields:
  - COUNT: Current available slots.
  - QUEUE: List of tasks waiting for a slot.
  - LOCK: A `concur-lock` object to protect semaphore state.
  - DATA: Arbitrary metadata (plist).
  - MAX-COUNT: Initial/maximum number of slots.
  - NAME: Optional human-readable name for the semaphore."
  count
  queue
  lock
  data
  max-count
  name)

(defun concur-semaphore--get-name (sem)
  "Return a human-readable name for SEM based on its name field.
  This function returns a name for the semaphore, primarily for logging
  and debugging purposes. It uses the `name` field of the semaphore struct.
  If the `name` field is nil, it generates a unique symbol name.

  Arguments:
  - sem: The semaphore whose name is being requested.

  Returns:
  - A string representing the semaphore's name."
  (or (concur-semaphore-name sem)
      (format "sem-%s" (gensym)))) ; Fallback if name is somehow nil

;;;###autoload
(defun concur-semaphore-new (n &optional name)
  "Create a semaphore with N available slots.

A semaphore is used to control access to a resource, limiting the
number of concurrent tasks that can use it. When a task needs
to access the resource, it must acquire a slot from the semaphore.
If no slots are available, the task will wait until a slot is released.

Arguments:
- N: The number of available slots in the semaphore. This must be a
  non-negative integer.
- NAME: Optional. A descriptive name for the semaphore, used for
       debugging and logging.

Returns:
- A new `concur-semaphore` object.

Throws:
- `error`: If N is not a non-negative integer.
"
  (unless (and (integerp n) (>= n 0))
    (error "Slot count must be a non-negative integer: %S" n))
  (concur-semaphore-create
   :count n
   :queue '()
   :lock (concur-lock-create)
   :data nil ; Data can be empty if name is directly in struct
   :max-count n
   :name (or name (format "sem-%s" (gensym)))))

(defvar concur-current-task nil
  "Dynamic variable holding the current cooperative task identifier.
  This variable is typically bound by a cooperative scheduler to identify
  the currently executing task, allowing primitives like semaphores to
  track which task owns a resource or is waiting.")

(defun concur-semaphore-acquire (sem task success-callback &key timeout meta timeout-callback)
  "Acquire SEM for TASK, or block cooperatively until available.
  This function attempts to acquire a slot from the semaphore. If no
  slots are available, the task is added to the semaphore's queue
  (a simple list), and the function blocks (cooperatively) until a
  slot becomes available.

  Arguments:
  - sem:  The semaphore to acquire.
  - task: The task attempting to acquire the semaphore. This is
          added to the queue if the semaphore is not immediately
          available.
  - success-callback (function): A zero-argument function to call when the semaphore is successfully acquired.
  - timeout: Optional. A timeout value in seconds. If the semaphore
             cannot be acquired within this time, the `timeout-callback` or `error-function` is invoked.
  - meta: Optional. Metadata to associate with the blocking operation,
          for logging or tracking.
  - timeout-callback (function, optional): A zero-argument function to call if a timeout occurs.

  Throws:
    - An error if the semaphore is not a valid semaphore.
    - A `concur-timeout-error` if the timeout expires (via `error-function`).
  "
  (unless (concur-semaphore-p sem)
    (error "concur-semaphore-acquire: SEM argument is not a semaphore: %S" sem))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :debug "Semaphore acquire: %s (task: %s, timeout: %s, meta: %s)"
                  sem-name task timeout meta)

    (with-mutex! (concur-semaphore-lock sem)
        (:else
         ;; If the mutex is held, it means another part of the semaphore logic
         ;; is running. This is an internal contention. We cannot acquire now.
         (log! :warn "Semaphore %s internal lock is held. Cannot acquire." sem-name)
         (if timeout-callback (funcall timeout-callback)
           (error 'concur-timeout-error (format "Semaphore %s internal lock held, cannot acquire." sem-name))))

      ;; Check if semaphore is immediately available
      (if (> (concur-semaphore-count sem) 0)
          (progn
            (cl-decf (concur-semaphore-count sem))
            (log! :debug "Semaphore %s acquired immediately (count: %d)"
                          sem-name (concur-semaphore-count sem))
            (funcall success-callback)) ; Acquired immediately, call success callback
        ;; Not immediately available, so queue the task and block cooperatively
        (progn
          ;; Add task to queue if not already there (important for re-entries)
          (unless (member task (concur-semaphore-queue sem))
            ;; Add to end for FIFO
            (setf (concur-semaphore-queue sem) (nconc (concur-semaphore-queue sem) (list task)))
            (log! :debug "Task %s queued for semaphore: %s" task sem-name))

          ;; Define callbacks for concur-block-until
          (let ((block-success-cb (lambda ()
                                    (cl-decf (concur-semaphore-count sem)) ; Decrement after acquiring
                                    (log! :debug "Semaphore %s acquired after blocking (count: %d)"
                                                  sem-name (concur-semaphore-count sem))
                                    (funcall success-callback)))
                (block-timeout-cb (lambda ()
                                    (log! :error "Timeout acquiring semaphore: %s" sem-name)
                                    ;; Remove task from queue on timeout
                                    (setf (concur-semaphore-queue sem) (delete task (concur-semaphore-queue sem)))
                                    (if timeout-callback (funcall timeout-callback)
                                      (error 'concur-timeout-error
                                             (format "Timeout acquiring semaphore %s for task %s" sem-name task))))))
            ;; Call concur-block-until to cooperatively wait
            (concur-block-until
             (lambda () (> (concur-semaphore-count sem) 0)) ; Test condition
             block-success-cb
             :timeout timeout
             :interval 0.1 ; Default interval for block-until
             :meta (or meta (list :semaphore sem-name :task task))
             :timeout-callback block-timeout-cb)))))))

;;;###autoload
(defun concur-semaphore-try-acquire (sem task)
  "Try to acquire SEM for TASK without blocking.

This function attempts to acquire a slot from the semaphore, but does
not block. If the semaphore has available slots, the task acquires
the slot and the function returns `t`. Otherwise, it returns `nil`
without modifying the semaphore or queue.

Arguments:
- sem:  The semaphore to try to acquire.
- task: The task attempting to acquire the semaphore.
       (Currently unused, but kept for consistency)

Returns:
- t if the semaphore was successfully acquired, nil otherwise.

Throws:
  - An error if SEM is not a valid semaphore.
"
  (unless (concur-semaphore-p sem)
    (error "concur-semaphore-try-acquire: SEM argument is not a semaphore: %S" sem))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :debug "Semaphore try-acquire: %s (task: %s)" sem-name task)
    (with-mutex! (concur-semaphore-lock sem)
        (:else
         ;; If mutex is held, we cannot even check the semaphore count.
         ;; So, we cannot acquire. Return nil.
         (log! :warn "Semaphore %s internal lock is held. Cannot try-acquire." sem-name)
         nil) ; Return nil if mutex is held
      (if (> (concur-semaphore-count sem) 0)
          (progn
            (cl-decf (concur-semaphore-count sem))
            (log! :debug "Semaphore try-acquire successful: %s (count: %d)"
                          sem-name (concur-semaphore-count sem))
            t)
        (progn
          (log! :debug "Semaphore try-acquire failed: %s (count: %d)"
                        sem-name (concur-semaphore-count sem))
          nil)))))

;;;###autoload
(defun concur-semaphore-release (sem wake-fn)
  "Release SEM, waking one task from the queue if present.

When a task releases the semaphore, it increments the available slot
count. If there are tasks waiting in the queue, one of them is woken
up and allowed to acquire the semaphore.

Arguments:
- sem:     The semaphore to release.
- wake-fn: The function to invoke to wake up a waiting task. This
           function is called with the task as its argument.

Returns:
  - Returns the task that was woken up, or nil if no task was woken.

Throws:
  - An error if SEM is not a valid semaphore."
  (unless (concur-semaphore-p sem)
    (error "concur-semaphore-release: SEM argument is not a semaphore: %S" sem))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :debug "Semaphore release: %s" sem-name)
    (with-mutex! (concur-semaphore-lock sem)
        (:else (error "Semaphore lock is held during release of %S" sem-name)) ; serious error.
      (cl-incf (concur-semaphore-count sem))
      (log! :debug "Semaphore released: %s (count: %d)"
                    sem-name (concur-semaphore-count sem))
      (when (and (concur-semaphore-max-count sem)
                 (> (concur-semaphore-count sem) (concur-semaphore-max-count sem)))
        (error "Semaphore count exceeds max-count for %S" sem-name))
      (let ((queue (concur-semaphore-queue sem)))
        (if (null queue)
            nil ; No task was woken
          (let ((next-task (car queue)))
            ;; Remove the head from the queue
            (setf (concur-semaphore-queue sem) (cdr queue))
            (log! :debug "Waking up task %s for semaphore: %s"
                          next-task sem-name)
            (funcall wake-fn next-task)
            next-task))))))

;;;###autoload
(defun concur-semaphore-reset (sem new-count)
  "Reset SEM to NEW-COUNT and clear its queue.

This function resets the semaphore to the specified number of available
slots and clears any tasks that are currently waiting in the queue.
This is useful for re-initializing a semaphore to its initial state.

Arguments:
- sem:       The semaphore to reset.
- new-count: The new number of available slots in the semaphore.

Returns:
  -  Returns the semaphore.

Throws:
  -  An error if SEM is not a valid semaphore, or new-count is invalid.
"
  (unless (concur-semaphore-p sem)
    (error "concur-semaphore-reset: SEM argument is not a semaphore: %S" sem))
  (unless (and (integerp new-count) (>= new-count 0))
    (error "Slot count must be a non-negative integer: %S" new-count))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :info "Resetting semaphore %s to %d" sem-name new-count)
    (with-mutex! (concur-semaphore-lock sem)
        (:else (error "Semaphore lock is held during reset of %S" sem-name))
      (setf (concur-semaphore-count sem) new-count)
      (setf (concur-semaphore-queue sem) '())
      (setf (concur-semaphore-max-count sem) new-count)))
  sem)

;;;###autoload
(defun concur-semaphore-describe (sem)
  "Return a plist describing the state of SEM.

This function provides an overview of the semaphore's state, including
the number of available slots, the number of waiting tasks, and any
additional data associated with the semaphore.

Arguments:
- sem: The semaphore to describe.

Returns:
- A plist containing the semaphore's name, available slot count, the
  number of tasks waiting, and any additional data associated with
  the semaphore.

Throws:
  - An error if SEM is not a valid semaphore.
"
  (unless (concur-semaphore-p sem)
    (error "concur-semaphore-describe: SEM argument is not a semaphore: %S" sem))
  (let ((name (concur-semaphore--get-name sem)))
    (log! :debug "Describing semaphore: %s" name)
    `(:name ,name
      :count ,(concur-semaphore-count sem)
      :waiting ,(length (concur-semaphore-queue sem))
      :data ,(concur-semaphore-data sem)
      :max-count ,(concur-semaphore-max-count sem))))

;;###autoload
(defmacro with-semaphore! (sem wake-fn &rest body)
  "Run BODY in a cooperative critical section guarded by SEM.

This macro attempts to acquire the semaphore SEM before executing BODY.
The `body` forms are executed asynchronously within a success callback
if the semaphore is acquired. If the semaphore cannot be acquired
immediately (e.g., due to internal mutex contention), the `:else` forms
are executed.

Arguments:
- sem:     A symbol that, at *run time*, will be bound to the
           semaphore to acquire.
- wake-fn: The function to invoke to wake up a waiting task when the
           semaphore is released. This function is called with the
           woken task as its argument.
- body:    The body of code to execute while holding the semaphore.
           This should be a list of forms.

Keyword support:
  :else FORMS...   — If the semaphore cannot be acquired immediately, run these forms
                    instead of blocking.

Returns:
  - Nil, as the acquisition and body execution are now asynchronous. The actual
    result of BODY will be handled by the callbacks.

Throws:
  - An error if SEM is not a symbol (at macro expansion) or not a semaphore (at run time).
"
  (declare (indent defun))
  (unless (symbolp sem)
    (error "sem argument to with-semaphore! must be a symbol: %S" sem))
  (unless (symbolp wake-fn)
    (error "wake-fn argument to with-semaphore! must be a symbol or a function name: %S" wake-fn))

  (let* ((else-clause-forms (cdr (assoc :else body))) ; Extract forms after :else
         (body-forms (if else-clause-forms (cl-delete :else body :key #'car) body)) ; Remove :else from body
         (task-var (gensym "task")))

    `(let ((,task-var (or concur-current-task (current-time)))) ; Use current-time as default task ID
       (if (concur-semaphore-p ,sem) ; Run-time check for semaphore object
           (progn
             (log! :debug "with-semaphore!: Attempting asynchronous acquire for semaphore %S for task %S."
                           (concur-semaphore--get-name ,sem) ,task-var)
             (concur-semaphore-acquire
              ,sem ,task-var
              ;; Success callback for when semaphore is acquired
              (lambda ()
                (unwind-protect
                    (progn
                      (log! :debug "with-semaphore!: Acquired semaphore %S. Running body."
                                    (concur-semaphore--get-name ,sem))
                      ,@body-forms) ; Execute the main body
                  (log! :debug "with-semaphore!: Releasing semaphore %S for task %S."
                                (concur-semaphore--get-name ,sem) ,task-var)
                  (concur-semaphore-release ,sem ,wake-fn))) ; Release and wake next
              ;; Timeout/failure callback for when semaphore cannot be acquired
              :timeout-callback (lambda ()
                                  (log! :debug "with-semaphore!: Failed to acquire semaphore %S. Running :else clause."
                                                (concur-semaphore--get-name ,sem))
                                  ,@else-clause-forms)))
         (error "sem argument to with-semaphore! was not a semaphore at run time: %S" ,sem))
       nil)))

(provide 'concur-primitives)
;;; concur-primitives.el ends here