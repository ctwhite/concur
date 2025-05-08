;;; concur-task.el --- Cooperative async primitives for Emacs -*- lexical-binding: t; -*-

;; Author: Christian White
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (dash "2.19.1") (duque "0.1"))
;; Keywords: concurrency, async, promise, future
;; URL: https://github.com/ctwhite/concur

;;; Commentary:

;; `concur-task.el` provides lightweight cooperative concurrency for Emacs.
;; It introduces the `concur-async!` macro to run coroutines, with
;; `concur-await!` for async result waiting and `concur-with-semaphore!` for
;; cooperative critical sections. A task scheduler runs via idle timers
;; and requeues coroutines using `duque`.

;;; Code:

(require 'cl-lib)
(require 'concur-future)
(require 'concur-promise)
(require 'dash)
(require 'duque)

(cl-defstruct concur-semaphore
  "A semaphore to limit concurrent access to shared resources."
  count         ;; Number of available slots.
  queue         ;; Queue of waiting tasks (not promises!).
  lock          ;; Mutex to protect the state.
  data)         ;; Arbitrary user-defined metadata (opaque)

;;;###autoload
(defcustom concur-scheduler-max-queue-length 100
  "Maximum number of tasks allowed in the scheduler queue."
  :type 'integer
  :group 'concur)

;;;###autoload
(defcustom concur-scheduler-idle-delay 0.05
  "Delay (seconds) between scheduler ticks when idle."
  :type 'number
  :group 'concur)

(defcustom concur-await-poll-interval 0.005
  "Polling interval in seconds used by `concur-await!` when blocking outside the scheduler.
A small value (e.g. 0.005 = 5ms) gives more responsiveness, but may use more CPU."
  :type 'number
  :group 'concur)

(defvar concur-scheduler-error-hook nil
  "Hook run if a task throws during async scheduler execution.")

(defvar concur--task-queue
  (duque-make :max concur-scheduler-max-queue-length)
  "FIFO queue of pending tasks for the async scheduler.")

(defvar concur--scheduler-idle-timer nil
  "Idle timer that processes the async task queue.")

(defvar concur--inside-scheduler nil
  "Non-nil when executing within the concur scheduler.")

;;; Scheduler

;;;###autoload
(defun concur-scheduler-start ()
  "Start the asynchronous promise scheduler if it is not already running.

This function checks if the promise scheduler is already active by verifying
whether there is an existing idle timer. If no timer is active, it starts
a new timer to run the promise scheduler periodically.

The promise scheduler is responsible for running queued asynchronous tasks
when the Emacs event loop is idle.

Side Effects:
- Starts an idle timer to periodically run the promise scheduler.
- Logs the action using `concur--log!`."

  (unless (and concur--scheduler-idle-timer
               (memq concur--scheduler-idle-timer timer-idle-list))
    (setq concur--scheduler-idle-timer
          (run-with-idle-timer concur-scheduler-idle-delay t
                               #'concur-scheduler-run))
    (concur--log! "Started promise scheduler")))

;;;###autoload
(defun concur-scheduler-stop ()
  "Stop the asynchronous promise scheduler if it is running.

This function cancels the currently active idle timer if one exists and
clears the associated state. If the scheduler is running, it will stop
executing scheduled tasks.

Side Effects:
- Cancels the idle timer used to run the promise scheduler.
- Logs the action using `concur--log!`."

  (when (timerp concur--scheduler-idle-timer)
    (cancel-timer concur--scheduler-idle-timer)
    (setq concur--scheduler-idle-timer nil)
    (concur--log! "Stopped promise scheduler")))

(defun concur-scheduler-run ()
  "Run the next task in the asynchronous task queue, or stop if the queue is empty.

This function is triggered by the idle timer and will execute the next task
in the promise scheduler queue. If there are no tasks left in the queue,
it will stop the promise scheduler by calling `concur-scheduler-stop`.

Errors during task execution are caught and passed to `concur-scheduler-error-hook`
to handle any exceptions in the task execution.

Side Effects:
- Executes the next task in the queue.
- If the queue is empty, stops the promise scheduler.
- Logs any errors during task execution.

Error Handling:
- Any errors during task execution are caught by `condition-case`, and the error
  is passed to a hook (`concur-scheduler-error-hook`) for further handling."

  (if (duque-empty-p concur--task-queue)
      (concur-scheduler-stop)
    (let ((task (duque-pop! concur--task-queue))
          (concur--inside-scheduler t))  ;; Dynamically bind concur--inside-scheduler
      (condition-case err
          (funcall task)
        (error
         (run-hook-with-args 'concur-scheduler-error-hook err)
         (concur--log! "Task error: %S" err))))))

;;;###autoload
(defun concur-scheduler-queue-task (task)
  "Queue TASK into the asynchronous scheduler. If the queue is full, the oldest task will be dropped.

This function adds a new task (a function) to the promise scheduler task queue.
If the queue is at its capacity, it will discard the oldest task in favor of the new one.
The promise scheduler is started if it is not already running.

Arguments:
- TASK: A function to be scheduled for execution in the promise scheduler.

Side Effects:
- Adds the task to the task queue.
- Starts the promise scheduler if it is not already running.

Precondition:
- The TASK argument must be a function (`functionp`). An assertion is made to ensure this."

  (cl-assert (functionp task))
  (duque-push! concur--task-queue task)
  (concur-scheduler-start))

;;;###autoload
(defun concur-scheduler-reset-queue ()
  "Reset the task queue by clearing all pending tasks.

This function reinitializes the task queue to an empty state, ensuring that
all previously queued asynchronous tasks are removed. The queue is recreated
with a maximum length defined by `concur-scheduler-max-queue-length`.

Side Effects:
- Resets the task queue to an empty state using `duque-make`.
- The maximum length of the queue is determined by `concur-scheduler-max-queue-length`."

  (setq concur--task-queue
        (duque-make :max concur-scheduler-max-queue-length)))

;;;###autoload
(defsubst concur-scheduler-clear-queue ()
  "Clear all pending asynchronous tasks in the task queue.

This function is a shorthand for `concur-scheduler-reset-queue`, clearing the
queue of any tasks that are pending.

Side Effects:
- Calls `concur-scheduler-reset-queue` to clear the task queue."

  (concur-scheduler-reset-queue))

;;;###autoload
(defsubst concur-scheduler-pending-count ()
  "Return the number of pending tasks in the task queue.

This function simply returns the length of the task queue, which represents
the number of tasks that are currently queued for execution.

Return Value:
- The number of pending tasks in the task queue as an integer."

  (duque-length concur--task-queue))

;;; Cooperative tasking

(defun concur-block-until (test enqueue)
  "Block cooperatively until the TEST function returns non-nil.
If the TEST function returns nil, the ENQUEUE function is called to requeue
the task for later execution. This is a cooperative approach that allows
other tasks to run in the meantime.

Arguments:
- TEST: A function that checks whether the blocking condition is met.
- ENQUEUE: A function that requeues the task if TEST returns nil.

Side Effects:
- If TEST returns nil, the task is requeued via ENQUEUE and the function
  yields cooperatively using `throw`."
  
  (unless (funcall test)
    (funcall enqueue)
    (throw 'concur-yield nil)))

(defmacro concur-yield! ()
  "Yield cooperatively to the asynchronous scheduler.

This macro allows a task to yield control back to the async scheduler so
other tasks can be processed. It effectively suspends the current task,
allowing the event loop to handle other pending tasks.

Side Effects:
- Causes the current task to yield control back to the async scheduler using `throw`."

  `(throw 'concur-yield nil))

;;; Locking

(defmacro concur-once-do! (place fallback &rest body)
  "Run BODY once if PLACE is nil. Otherwise, run FALLBACK.

This macro ensures that a block of code is executed only once based on the
state of PLACE. If PLACE is nil, BODY is executed, and PLACE is set to `t`.
If PLACE is non-nil, FALLBACK is executed instead. FALLBACK can be either
a value or a list of forms to be evaluated.

Arguments:
- PLACE: A variable or place (could be a symbol or a generalized variable) 
  that determines whether the body of code should be executed.
- FALLBACK: The code to run if PLACE is non-nil. Can either be a value or
  a list of forms (e.g., `(:else FORM...)`).
- BODY: The code to run once if PLACE is nil.

Side Effects:
- Sets PLACE to `t` after executing BODY.
- If PLACE is non-nil, executes FALLBACK instead of BODY.

Example:
  (concur-once-do! my-variable '(:else (message \"Already done!\")) (message \"Doing it!\"))"
  
  (declare (indent 2))
  `(if ,place
       ,(if (and (consp fallback) (eq (car fallback) :else))
            `(progn ,@(cdr fallback))
          fallback)
     (progn
       ,(if (symbolp place)
            `(setf ,place t)  ;; Simple variable modification
          `(gv-letplace (getter setter) ,place
             (funcall setter t)))  ;; For generalized variables
       ,@body))

(defmacro concur-with-lock! (place fallback &rest body)
  "Acquire a lock on PLACE temporarily during the execution of BODY.

This macro ensures that the code in BODY will only execute if PLACE is not
locked. If PLACE is already locked (non-nil), FALLBACK will be executed instead.
The lock is released after the execution of BODY, regardless of whether BODY
is successful or not.

Arguments:
- PLACE: A place (e.g., a symbol or generalized variable) that acts as a lock.
- FALLBACK: Code to execute if PLACE is already locked (can be a value or
  `(:else FORMS...)`).
- BODY: Code that will run while PLACE is locked.

Side Effects:
- Modifies PLACE to `t` temporarily during the execution of BODY.
- Releases the lock on PLACE after executing BODY.

Example:
  (concur-with-lock! my-lock (:else (message \"Already locked!\")) (do-something))"

  (declare (indent 2))
  (let ((lock-held (make-symbol "lock-held")))
    `(if ,place
         ,(if (and (consp fallback) (eq (car fallback) :else))
              `(progn ,@(cdr fallback))
            fallback)
       (let ((,lock-held t))
         ,(if (symbolp place)
              `(setf ,place ,lock-held)  ;; Simple variable modification
            `(gv-letplace (getter setter) ,place
               (funcall setter ,lock-held)))  ;; For generalized variables
         (unwind-protect (progn ,@body)
           ,(if (symbolp place)
                `(setf ,place nil)  ;; Simple variable modification
              `(gv-letplace (getter setter) ,place
                 (funcall setter nil)))))))

(defmacro concur-with-mutex! (place fallback &rest body)
  "Generic lock macro with optional permanent form.
Acquire a lock on PLACE, and ensure that the lock persists across runs if 
needed.

PLACE may be of the form `(:permanent SYM)` to create a lock that persists
across multiple executions. If not permanent, the lock will only be held
during the execution of BODY. 

Arguments:
- PLACE: The place acting as a lock, which can be `(:permanent SYM)` to 
  indicate persistence or a symbol representing a simple lock.
- FALLBACK: Code to run if the lock cannot be acquired (can be a value or
  `(:else FORMS...)`).
- BODY: Code that will run while the lock is held.

Side Effects:
- Modifies PLACE to `t` temporarily during the execution of BODY.
- If PLACE is permanent, the lock persists across runs.
- Releases the lock on PLACE after executing BODY.

Example:
  (concur-with-mutex! my-mutex (:permanent my-lock) (do-something))"

  (declare (indent 2))
  (let ((real-place (make-symbol "real-place"))
        (permanent (make-symbol "perm")))
    `(let* ((,permanent (and (consp ,place) (eq (car ,place) :permanent)))
            (,real-place (if ,permanent (cadr ,place) ,place)))
       (if ,real-place
           ,(if (and (consp fallback) (eq (car fallback) :else))
                `(progn ,@(cdr fallback))
              fallback)
         (concur-with-lock! ,real-place
           (:else nil)
           (concur-once-do! (not ,real-place)
             (:else
              ,(if (symbolp real-place)
                   `(setf ,real-place t)  ;; Simple variable modification
                 `(gv-letplace (getter setter) ,real-place
                    (funcall setter t)))  ;; For generalized variables
              ,@body)))))))

(defun concur-semaphore-create (n)
  "Create a semaphore with N available slots.

A semaphore is used to limit access to a particular resource or critical
section by multiple tasks. The semaphore is initialized with N available
slots, which can be acquired or released by tasks.

Arguments:
  - N: The number of slots available in the semaphore. Tasks can acquire
    these slots to access the resource.

Returns:
  - A semaphore object, represented as a struct with a `:count` field for
    the number of available slots and a `:queue` for tasks waiting to acquire
    the semaphore.
"
  (make-concur-semaphore :count n :queue '()))

(defun concur-semaphore-acquire (sem task)
  "Acquire SEM for TASK, or requeue it if unavailable.

This function attempts to acquire a slot from the semaphore. If the semaphore
has available slots, it decrements the slot count and allows the task to proceed.
If no slots are available, the task is added to the semaphore's queue and will
be retried when a slot becomes available.

Arguments:
  - sem: The semaphore to acquire.
  - task: The task to be queued if the semaphore is unavailable.

Returns:
  - Nothing, but logs the state of the semaphore.
"
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    ;; Block until there is an available slot in the semaphore
    (concur-block-until
     (lambda () (> (concur-semaphore-count sem) 0))  ;; Test for available slot
     (lambda () 
       ;; Requeue the task if the semaphore is unavailable
       (concur--log! "Task queued for semaphore: %s" (concur--semaphore-name sem))
       (setf (concur-semaphore-queue sem)
             (nconc (concur-semaphore-queue sem) (list task)))) )  ;; FIFO Queue

    ;; Decrement available slots in semaphore
    (cl-decf (concur-semaphore-count sem))
    (concur--log! "Semaphore acquired: %s" sem)))

(defun concur-semaphore-try-acquire (sem task)
  "Try to acquire SEM for TASK without blocking.

This function attempts to acquire a slot from the semaphore, but does not block.
If the semaphore has available slots, the task acquires the slot and the function
returns `t`. Otherwise, it returns `nil` without modifying the semaphore or queue.

Arguments:
  - sem: The semaphore to try to acquire.
  - task: The task attempting to acquire the semaphore.

Returns:
  - t if the semaphore was successfully acquired, nil otherwise.
"
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    ;; Attempt non-blocking acquire
    (when (> (concur-semaphore-count sem) 0)
      (cl-decf (concur-semaphore-count sem))
      (concur--log! "Semaphore try-acquire successful: %s" sem)
      t)))

(defun concur-semaphore-release (sem)
  "Release SEM, waking one task from the queue if present.

When a task releases the semaphore, it increments the available slot count.
If there are tasks waiting in the queue, one of them is woken up and allowed
to acquire the semaphore.

Arguments:
  - sem: The semaphore to release.
  
Returns:
  - Nothing, but logs the state of the semaphore and the task being woken up.
"
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    ;; Increment the available slots in the semaphore
    (cl-incf (concur-semaphore-count sem))
    (concur--log! "Semaphore released: %s" (concur--semaphore-name sem))
    ;; Wake up the next task in the queue, if any
    (when-let ((next (pop (concur-semaphore-queue sem))))
      (concur--log! "Waking up task for semaphore: %s" (concur--semaphore-name sem))
      (concur-scheduler-queue-task next))))

(defun concur-semaphore-reset (sem new-count)
  "Reset SEM to NEW-COUNT and clear its queue.

This function resets the semaphore to the specified number of available slots
and clears any tasks that are currently waiting in the queue.

Arguments:
  - sem: The semaphore to reset.
  - new-count: The new number of available slots in the semaphore.

Returns:
  - Nothing, but the semaphore's count and queue are reset.
"
  (setf (concur-semaphore-count sem) new-count)
  (setf (concur-semaphore-queue sem) '()))

;;;###autoload
(defun concur-semaphore-describe (sem)
  "Return a plist describing the state of SEM.

This function provides an overview of the semaphore's state, including the
number of available slots, the number of waiting tasks, and any additional data
associated with the semaphore.

Arguments:
  - sem: The semaphore to describe.

Returns:
  - A plist containing the semaphore's name, available slot count, the number
    of tasks waiting, and any additional data associated with the semaphore.
"
  `(:name ,(concur--semaphore-name sem)
    :count ,(concur-semaphore-count sem)
    :waiting ,(length (concur-semaphore-queue sem))
    :data ,(concur-semaphore-data sem)))

(defun concur--semaphore-name (sem)
  "Return a human-readable name for SEM based on its data field.

This function returns a name for the semaphore, either from the `:name` field
in the semaphore's data or a generated name if no name is provided.

Arguments:
  - sem: The semaphore whose name is being requested.

Returns:
  - A string representing the semaphore's name.
"
  (let ((data (concur-semaphore-data sem)))
    (or (plist-get data :name)
        (symbol-name (gensym "sem")))))  ;; Fallback identifier if no name is provided

(defmacro concur-with-semaphore! (sem &rest body)
  "Run BODY in a cooperative critical section guarded by SEM.

This macro attempts to acquire the semaphore SEM before executing BODY. If
the semaphore is unavailable, it either blocks until it can be acquired or
runs an alternative set of forms (if :else is provided).

Arguments:
  - sem: The semaphore to acquire.
  - body: The body of code to execute while holding the semaphore.
  
Keyword support:
  :timeout SECONDS — Auto-release the lock after SECONDS.
  :else FORMS...   — If the semaphore is unavailable, run these forms instead of blocking.

Returns:
  - Nothing. If the semaphore is successfully acquired, BODY is executed
    in a critical section. If not, fallback forms are executed if :else is provided.
"
  (declare (indent defun))
  (-let* (((keys body-forms) (--split-with (lambda (x) (keywordp x)) body))
          (&plist :timeout timeout :else else) keys
          (acquired (gensym "acquired")))
    `(let ((,acquired nil))
       (unwind-protect
           (progn
             ;; Attempt non-blocking acquire if :else is present
             (if ,(if else t nil)
                 (setq ,acquired (concur-semaphore-try-acquire ,sem nil))
               (progn
                 (concur-semaphore-acquire ,sem nil)
                 (setq ,acquired t)))

             (if ,acquired
                 (progn
                   ;; Optional: auto-release after timeout
                   ,@(when timeout
                       `((concur-promise-timeout
                          ,timeout
                          (lambda ()
                            (when ,acquired
                              (setq ,acquired nil)
                              (concur-semaphore-release ,sem))))))

                   ;; Body of critical section
                   ,@body-forms)
               ;; Could not acquire; run fallback
               ,@(when else
                   `((progn ,@else)))))
         ;; Cleanup
         (when ,acquired
           (concur-semaphore-release ,sem))))))

(defmacro concur-async! (&rest args)
  "Run BODY asynchronously, optionally under a SEMAPHORE or bypassing the task pool.

Usage:
  (concur-async!
    (do-something))

  (concur-async! some-semaphore
    (do-limited-work))

  (concur-async! :schedule nil
    (do-immediate-async-work))

  (concur-async! some-semaphore :schedule nil
    (run-immediate-with-limited-concurrency))

Arguments:
  - SEMAPHORE (optional): A semaphore object for limiting concurrency.
  - :schedule nil: If present, bypasses the concur scheduler task pool.

Returns:
  A `promise` representing the result of the asynchronous computation."

  (declare (indent defun))
  (let* ((args* args)
         (semaphore nil)
         (schedule t)
         (body nil))

    ;; Extract keyword arguments
    (while (keywordp (car (last args*)))
      (let ((kw (car (last args*)))
            (val (car (last (butlast args*)))))
        (setq args* (butlast args* 2))
        (pcase kw
          (:schedule (setq schedule val))
          (_ (error "Unknown keyword %S in concur-async!" kw)))))

    ;; Detect positional SEMAPHORE if present
    (if (and args* (not (keywordp (car args*))))
        (setq semaphore (car args*)
              body (cdr args*))
      (setq body args*))

    ;; Generate symbols
    (let ((done     (gensym "done-"))
          (result   (gensym "result-"))
          (promise  (gensym "promise-"))
          (self     (gensym "self-")))

      `(let* ((,done nil)
              (,result nil)
              (,promise (concur-promise-new)))
         (cl-labels ((,self ()
                      (catch 'concur-yield
                        (setq ,result
                              ,(if ,semaphore
                                   `(concur-with-semaphore! ,semaphore ,@body)
                                 `(progn ,@body)))
                        (setq ,done t))))
           (concur-future-wrap
            (lambda ()
              (condition-case err
                  (progn
                    (,self)
                    (setq ,done t)
                    (when ,done
                      (concur-promise-resolve ,promise ,result)))
                (error
                 (concur-promise-reject ,promise err)
                 (concur--log! "concur-async! task error: %S" err)))))
           ,(if schedule
                ;; Use the task pool
                `(concur-scheduler-queue-task
                  (lambda () (concur-promise-task ,promise)))
              ;; Bypass the pool and run immediately
              `(progn
                 (concur--log! "Bypassing task pool with :schedule nil")
                 (concur-promise-task ,promise)))
           ,promise)))))

(defmacro concur-await! (form)
  "Await the result of FORM, which must evaluate to a `concur-future`.

This macro blocks execution until the `concur-future` represented by FORM has completed. It ensures 
that the result is available before proceeding. The future can be created either inside the scheduler 
or outside of it (e.g., using `:schedule nil` in `concur-async!`).

Behavior:
  - If called **inside the scheduler**, it yields cooperatively by re-queuing the task to the scheduler 
  until the future is completed.
  - If called **outside the scheduler**, it performs a polling loop, periodically checking the status of the 
  future with `sleep-for` to avoid blocking the Emacs event loop.

Arguments:
  - FORM: The expression that should evaluate to a `concur-future` (i.e., an asynchronous operation's result).

Returns:
  - The value stored in the future if successful, or signals an error if the future has encountered an error.

Error Handling:
  - If the future has encountered an error, it will be raised as a Lisp error using `signal`.
  
Example:
  (concur-await! (concur-async! (some-task)))
  ;; Wait until the asynchronous task completes, then continue execution.

If the future is completed inside the scheduler, this macro cooperatively yields. Otherwise, it uses 
a polling loop to wait for the result."

  (let ((val (gensym "val"))
        (future (gensym "future")))
    `(let* ((,future ,form)
            (,val nil))
       ;; Ensure FORM evaluates to a valid concur-future
       (cl-assert (concur-future-p ,future)
                  nil "Expected a concur-future, but got: %S" ,future)
       
       (if (boundp 'concur--inside-scheduler)
           ;; If inside scheduler: yield cooperatively by re-queuing the task
           (cl-labels
               ((self ()
                      (unless (concur-future-done-p ,future)
                        (concur-scheduler-queue-task #'self))))
             ;; Block until the future is done, using cooperative scheduling
             (concur-block-until
              (lambda () (concur-future-done-p ,future))
              #'self))
         
         ;; If outside scheduler: use polling loop with sleep to avoid blocking
         (while (not (concur-future-done-p ,future))
           (sleep-for concur-await-poll-interval)))

       ;; Check if the future has an error, signal it if so
       (if (concur-future-error-p ,future)
           (signal (car (concur-future-error ,future))
                   (cdr (concur-future-error ,future)))
         
         ;; Otherwise, return the resolved value
         (setq ,val (concur-future-value ,future)))

       ;; Return the value of the future
       ,val)))

;;;###autoload
(cl-defun concur-async-task-wrap (fn-or-val &key catch finally semaphore schedule)
  "Wrap FN-OR-VAL in an async task using `concur-async!`, with optional CATCH, FINALLY, SEMAPHORE, and SCHEDULE.

If FN-OR-VAL is a function, it is invoked asynchronously. If FN-OR-VAL is a value, it is resolved immediately 
using `concur-promise-resolve`.

Arguments:
  - FN-OR-VAL: Either a function to execute asynchronously or a value to resolve immediately.
  - CATCH (optional): A function to handle errors in the asynchronous task.
  - FINALLY (optional): A function to be invoked when the task finishes, regardless of success or failure.
  - SEMAPHORE (optional): A semaphore to limit concurrency.
  - SCHEDULE (optional): If non-nil, bypass the task pool and run the task immediately without scheduling.

Returns:
  A `concur-future` that represents the result of the task."

  (if (functionp fn-or-val)
      (if schedule
          ;; If `schedule` is non-nil, bypass the task pool and run the task immediately
          (concur-async!
           :catch catch
           :finally finally
           :semaphore semaphore
           :schedule nil  ;; Ensure the task is run without the scheduler
           (funcall fn-or-val))
        ;; Otherwise, schedule the task within the task pool
        (concur-async!
         :catch catch
         :finally finally
         :semaphore semaphore
         (funcall fn-or-val)))
    (concur-promise-resolve fn-or-val)))  ;; If FN-OR-VAL is already a value, resolve immediately

;;;###autoload
(cl-defun concur-async-task-pipe (initial &rest fns &key semaphore schedule)
  "Pipe INITIAL through FNS. Each function receives the result of the previous function.

This function executes each function in the sequence `fns` asynchronously, passing the result
from one function to the next. Optionally, SEMAPHORE can be used to limit concurrency.

Arguments:
  - INITIAL: The initial value passed into the first function in the pipeline.
  - FNS: A list of functions to apply in sequence to the result of the previous function.
  - SEMAPHORE (optional): A semaphore to control concurrency during the pipeline execution.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs the task immediately.

Returns:
  A `concur-future` representing the result of the last function in the pipeline."

  (let ((pipeline-fn
         (lambda (acc fn)
           (concur-promise-then acc
             (lambda (res)
               (concur-async-task-wrap (funcall fn res)
                                       :semaphore semaphore
                                       :schedule schedule))))))
    ;; Apply each function in FNS to the result of the previous function in the pipeline
    (--reduce-from pipeline-fn
                   (concur-async-task-wrap initial :semaphore semaphore :schedule schedule)
                   fns)))

;;;###autoload
(cl-defun concur-async-task-parallel (&rest tasks &key semaphore schedule)
  "Run TASKS concurrently, with optional SEMAPHORE to limit concurrency.

Each task in TASKS is executed asynchronously. Optionally, a SEMAPHORE can be passed to
control the number of concurrent tasks.

Arguments:
  - TASKS: A list of functions or values to execute asynchronously.
  - SEMAPHORE (optional): A semaphore to limit concurrent task execution.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of all tasks in parallel."

  (let ((wrapped (--map (lambda (task)
                          (concur-async-task-wrap task
                                                 :semaphore semaphore
                                                 :schedule schedule))
                        tasks)))
    ;; Wait for all tasks to complete and return their results
    (concur-promise-all wrapped)))

;;;###autoload
(cl-defun concur-async-task-map (fn items &key semaphore catch finally schedule)
  "Apply FN to each ITEM in ITEMS concurrently.
Each item in ITEMS is processed asynchronously, and the results are returned together.

Arguments:
  - FN: A function to apply to each item in ITEMS.
  - ITEMS: A list of items to apply FN to.
  - SEMAPHORE (optional): A semaphore to control concurrency.
  - CATCH (optional): A function to handle errors in the asynchronous task.
  - FINALLY (optional): A function to be invoked when the task finishes, regardless of success or failure.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs the task immediately.

Returns:
  A `concur-future` representing the results of applying FN to each item."

  (let ((wrap-item
         (lambda (item)
           (let ((task (lambda () (funcall fn item))))
             (concur-async-task-wrap task
                                    :semaphore semaphore
                                    :catch catch
                                    :finally finally
                                    :schedule schedule)))))
    ;; Apply FN to each item concurrently
    (concur-promise-all (--map wrap-item items))))

;;;###autoload
(cl-defun concur-async-task-chain (&rest tasks &key semaphore catch finally schedule)
  "Run TASKS sequentially, each depending on the result of the previous.
Each task in TASKS is executed in sequence, and the result of each task is passed to the next one.

Arguments:
  - TASKS: A list of tasks (functions) to execute sequentially.
  - SEMAPHORE (optional): A semaphore to control concurrency during execution.
  - CATCH (optional): A function to handle errors in the asynchronous task.
  - FINALLY (optional): A function to be invoked when the task finishes, regardless of success or failure.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the final result after executing all tasks sequentially."

  (concur-promise-let* ((results
                         (--reduce-from
                          (lambda (promise task)
                            (concur-promise-then promise
                              (lambda (acc)
                                (let* ((prev (car (last acc)))
                                       (run (lambda () (funcall task prev)))
                                       (next (concur-async-task-wrap run 
                                                                  :semaphore semaphore 
                                                                  :catch catch 
                                                                  :finally finally
                                                                  :schedule schedule)))
                                  (concur-promise-then next
                                    (lambda (res)
                                      (append acc (list res))))))))
                          (concur-promise-resolve '())
                          tasks)))
    results))

;;;###autoload
(cl-defun concur-async-task-reduce (fn init items &key semaphore schedule)
  "Reduce ITEMS sequentially using FN, which returns a promise.
Each step of the reduction is done asynchronously, and the result of each step is passed to the next.

Arguments:
  - FN: A function that takes the accumulator and item and returns a promise.
  - INIT: The initial value of the accumulator.
  - ITEMS: A list of items to reduce.
  - SEMAPHORE (optional): A semaphore to control concurrency during reduction.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the final result after reducing all items."

  (let ((step
         (lambda (acc item)
           (concur-promise-then acc
             (lambda (res)
               (let ((thunk (lambda () (funcall fn res item))))
                 (concur-async-task-wrap thunk
                                         :semaphore semaphore
                                         :schedule schedule)))))))
    ;; Sequential reduction using FN
    (--reduce-from step
                  (concur-promise-resolve init)
                  items)))

;;;###autoload
(cl-defun concur-async-task-with-retries (task &key (retries 3) schedule)
  "Run TASK (a thunk or function) with up to RETRIES attempts on failure.

Arguments:
  - TASK: A function or thunk to run.
  - RETRIES: The number of retry attempts (default: 3).
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of the task after retries, or an error if it fails."

  (concur-promise-catch
   (concur-async-task-wrap task
                           :schedule schedule)
   (lambda (err)
     (if (> retries 0)
         (concur-async-task-with-retries task :retries (1- retries) :schedule schedule)
       (concur-promise-reject err)))))

;;;###autoload
(cl-defun concur-async-task-timeout (task secs &key schedule)
  "Run TASK (a thunk or promise), but reject if it takes longer than SECS seconds.

Arguments:
  - TASK: A function or promise to execute.
  - SECS: The maximum time in seconds to wait for TASK to complete.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` that either resolves when the task completes or rejects if it times out."

  (concur-promise-race
   (list
    (concur-async-task-wrap task :schedule schedule)
    (concur-promise-then (concur-promise-delayed secs)
      (lambda (_) (concur-promise-reject "Timeout"))))))

;;;###autoload
(cl-defun concur-async-task-retry-while (task pred &key (delay 0.5) schedule)
  "Run TASK and retry if it fails and PRED returns non-nil on the error.
Wait DELAY seconds between retries.

Arguments:
  - TASK: A function or promise to run.
  - PRED: A predicate function that determines if the task should be retried.
  - DELAY: The delay in seconds between retries (default: 0.5).
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of the task, retrying on failure."

  (concur-promise-catch
   (concur-async-task-wrap task :schedule schedule)
   (lambda (err)
     (if (funcall pred err)
         (concur-promise-then (concur-promised-delayed delay)
           (lambda () (concur-async-task-retry-while task pred :delay delay :schedule schedule)))
       (concur-promise-reject err)))))

;;;###autoload
(defun concur-async-task-loop (fn &key schedule)
  "Continuously run FN as long as it returns a truthy value.
Each iteration waits for the previous to resolve.

Arguments:
  - FN: A function that returns a truthy value to continue the loop.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of the loop, or nil if the loop ends."

  (concur-promise-then (concur-async-task-wrap fn :schedule schedule)
    (lambda (res)
      (if res
          (concur-async-task-loop fn :schedule schedule)
        (concur-promise-resolve nil)))))

;;;###autoload
(cl-defun concur-async-task-debounce (fn &key (delay 0.5))
  "Return a debounced version of FN that runs only after DELAY seconds of inactivity.

Arguments:
  - FN: A function to debounce.
  - DELAY: The delay in seconds before FN is called (default: 0.5).

Returns:
  A debounced version of FN."

  (let ((timer nil))
    (lambda (&rest args)
      (when timer (cancel-timer timer))
      (setq timer
            (run-with-timer delay nil
                            (lambda () (apply fn args)))))))

;;;###autoload
(defun concur-async-task-with-progress (task on-progress)
  "Run TASK and call ON-PROGRESS with 1.0 when complete.
Use this for tasks that don't natively report progress but need a completion signal.

Arguments:
  - TASK: A function or promise to run.
  - ON-PROGRESS: A function to call with progress updates, including a final value of 1.0.

Returns:
  A `concur-future` representing the result of TASK after calling ON-PROGRESS."
  
  (concur-promise-then (concur-async-task-wrap task)
    (lambda (res)
      (funcall on-progress 1.0)
      res)))

;;; Aliases

(defalias 'cc-task-pipe 'concur-async-task-pipe)
(defalias 'cc-task-parallel 'concur-async-task-parallel)
(defalias 'cc-task-map 'concur-async-task-map)
(defalias 'cc-task-chain 'concur-async-task-chain)
(defalias 'cc-task-reduce 'concur-async-task-reduce)
(defalias 'cc-task-with-retries 'concur-async-task-with-retries)
(defalias 'cc-task-timeout 'concur-async-task-timeout)
(defalias 'cc-task-retry-while 'concur-async-retry-while)

(provide 'concur-task)
;;; concur.el ends here               