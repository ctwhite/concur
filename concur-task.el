;;; concur-task.el --- Cooperative async primitives for Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; `concur-task.el` provides lightweight cooperative concurrency for Emacs.
;; It introduces the `concur-async!` macro to run coroutines, with
;; `concur-await!` for async result waiting and `concur-with-semaphore!` for
;; cooperative critical sections. A task scheduler runs via idle timers
;; and requeues coroutines using `ring`.
;;
;;; Code:

(require 'cl-lib)
(require 'concur-future)
(require 'concur-lock)
(require 'concur-promise)
(require 'concur-util)
(require 'dash)
(require 'ring)

(cl-defstruct (concur-task (:constructor make-concur-task))
  "A structure representing an asynchronous task to be scheduled and executed.

Fields:
  - semaphore: A semaphore object used to control concurrent access to shared resources (optional).
  - cancel-token: A cancel token that can be used to cancel this task (optional).
  - future: The future object that represents the result of the asynchronous computation.
  - schedule: Specifies when the task should run. Possible values are:
      - 'immediate: Run the task immediately.
      - 'async: Run the task asynchronously.
      - 'event-loop: Run the task within the current event loop (after the current task finishes).
  - meta: Arbitrary metadata associated with the task. Can store extra information about the task.
  - name: A human-readable name for the task (optional).
  - created-at: A timestamp representing when the task was created.

The `concur-task` struct is used to define tasks that are scheduled and executed by the concur scheduler.
It encapsulates all the necessary information for task execution, cancellation, and resource management."
  semaphore
  cancel-token
  future
  schedule 
  meta
  name
  created-at)

(cl-defstruct concur-semaphore
  "A semaphore to limit concurrent access to shared resources.

Fields:
  - count: The number of available slots or resources. When `count` is greater than 0, 
      tasks can proceed.
  - queue: A queue of tasks waiting for access to the semaphore. These are tasks that are 
      blocked because there are no available resources.
  - lock: A mutex or lock used to protect the semaphore's state and prevent race conditions.
  - data: Arbitrary user-defined metadata that can be associated with the semaphore. This allows
      the user to store additional context (opaque data) relevant to the semaphore's usage.

The `concur-semaphore` struct is used to manage resource access in a concurrent environment, 
ensuring that a certain number of tasks can run concurrently while others wait in a queue."
  count        
  queue        
  lock         
  data)        

(cl-defstruct concur-cancel-token
  "A structure representing a cancel token that can be used to cancel asynchronous tasks.

Fields:
  - active: A boolean value indicating whether the cancel token is active. If `active` is 
      non-nil, tasks associated with this token can be canceled.
  - name: An optional human-readable name for the cancel token, which can be useful for 
      debugging or logging purposes.

The `concur-cancel-token` struct is used to signal cancellation for tasks. If a task checks 
for cancellation and finds that its associated cancel token is active, it can halt execution early."
  active
  name)

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
  (make-ring concur-scheduler-max-queue-length)
  "FIFO ring buffer of pending tasks for the async scheduler.")

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
  (if (ring-empty-p concur--task-queue)
      (concur-scheduler-stop)
    ;; Remove the task from the front
    (let ((task (ring-remove concur--task-queue)))  
      ;; Dynamically bind concur--inside-scheduler
      (let ((concur--inside-scheduler t))  
        (condition-case err
            (funcall task)
          (error
           (run-hook-with-args 'concur-scheduler-error-hook err)
           (concur--log! "Task error: %S" err)))))))

(defun concur-scheduler-run ()
  "Run the next task in the async queue, or stop if the queue is empty.

This function is responsible for executing the next task in the async task queue.
It checks the scheduling preferences of the task and runs it accordingly. If the
task queue is empty, the scheduler will stop. Otherwise, it dequeues the next task 
and processes it.

The scheduling behavior depends on the `:schedule` value associated with each task:
  - t: Runs the task immediately using `run-at-time` with a delay of 0 (essentially scheduling it for immediate execution).
  - nil: Runs the task immediately in the current context.
  - 'async: Schedules the task for asynchronous execution using `async-start`.
  - 'deferred: Schedules the task to run after the current event loop using `run-at-time`.

Error handling is done with `condition-case`, and any errors that occur during task
execution are passed to `concur-promise-reject` and logged using `concur--log!`.

This function interacts with:
  - `concur--task-queue`: A ring buffer that holds the tasks waiting to be executed.
  - `concur-task-future`: Accesses the future object associated with the task.
  - `concur-future-promise`: Resolves the promise once the task has finished executing.
  - `concur-task-schedule`: Fetches the task's scheduling preference.

Example of scheduling behavior:
  - If `:schedule` is `t`, the task is scheduled for immediate execution.
  - If `:schedule` is `nil`, the task is run immediately in the current context.
  - If `:schedule` is `'async`, the task will run asynchronously, allowing other operations to continue.
  - If `:schedule` is `'deferred`, the task will be deferred until after the current event loop.

Note:
  - If the queue is empty, the scheduler will stop.
  - Errors are handled gracefully and logged for debugging."
  (if (ring-empty-p concur--task-queue)
      (concur-scheduler-stop)  ;; Stop if the task queue is empty
    (let ((task (ring-remove concur--task-queue))        ;; Remove the task from the queue
          (future (concur-task-future task))            ;; Get the future associated with the task
          (promise (concur-future-promise future))      ;; Get the promise from the future
          (task-fn (concur-future-fn future))           ;; Get the function to run for the task
          (schedule (concur-task-schedule task)))       ;; Get the scheduling preference for the task

      (let ((concur--inside-scheduler t))  ;; Mark that we're inside the scheduler
        (condition-case err
            (cond
               ;; Defer the task execution until the current event loop finishes
             ((or (eq schedule t) (eq schedule 'deferred))
              (run-at-time 0 nil
                           (lambda ()
                             (funcall task-fn)  
                             (concur-promise-resolve promise result)))) 

             ;; Run the task immediately
             ((eq schedule nil)
              (funcall task-fn)  
              (concur-promise-resolve promise result))  

             ;; Run the task asynchronously
             ((eq schedule 'async)
              (async-start
               (lambda () (funcall task-fn)) 
               (lambda (result)  
                 (concur-promise-resolve promise result))))
             
             (t
              (error "Unknown :schedule value %S" schedule)))

          (error
           ;; Handle errors during task execution
           (concur-promise-reject promise err)  
           (run-hook-with-args 'concur-scheduler-error-hook err)  
           (concur--log! "Task error: %S" err)))))))

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
- The TASK argument must be a valid task object of type `concur-task`."
  (cl-assert (concur-task-p task))  
  
  ;; Add the task to the ring buffer (queue) for future processing
  (if (= (ring-length concur--task-queue) (ring-size concur--task-queue))
      ;; If the ring is full, remove the oldest task
      (ring-remove concur--task-queue)  
    ;; Insert the new task at the end of the ring
    (ring-insert concur--task-queue task))

  ;; Ensure the scheduler starts if it's not already running
  (concur-scheduler-start))

;;;###autoload
(defun concur-scheduler-clear-queue ()
  "Clear all pending asynchronous tasks in the task queue."
  (while (not (ring-empty-p concur--task-queue))
    (ring-remove concur--task-queue)))

;;;###autoload
(defsubst concur-scheduler-pending-count ()
  "Return the number of pending tasks in the task queue.

This function simply returns the length of the task queue, which represents
the number of tasks that are currently queued for execution.

Return Value:
- The number of pending tasks in the task queue as an integer."
  (ring-length concur--task-queue))  

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
    ;; Requeue the task for later execution
    (funcall enqueue)
    ;; Yield cooperatively to allow other tasks to run
    (throw 'concur-yield nil))
  ;; Continue execution if TEST returns non-nil
  t)

(defmacro concur-yield! ()
  "Yield cooperatively to the asynchronous scheduler.

This macro allows a task to yield control back to the async scheduler so
other tasks can be processed. It effectively suspends the current task,
allowing the event loop to handle other pending tasks.

Side Effects:
- Causes the current task to yield control back to the async scheduler using `throw`."
  `(throw 'concur-yield nil))

;;; Semaphore

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
    the semaphore."
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
  - Nothing, but logs the state of the semaphore."
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    ;; Block until there is an available slot in the semaphore
    (concur-block-until
     ;; Test for available slot
     (lambda () (> (concur-semaphore-count sem) 0))  
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
  - t if the semaphore was successfully acquired, nil otherwise."
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
  - Nothing, but logs the state of the semaphore and the task being woken up."
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
  - Nothing, but the semaphore's count and queue are reset."
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
    of tasks waiting, and any additional data associated with the semaphore."
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
  - A string representing the semaphore's name."
  (let ((data (concur-semaphore-data sem)))
    (or (plist-get data :name)
        ;; Fallback identifier if no name is provided
        (symbol-name (gensym "sem")))))  

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
    in a critical section. If not, fallback forms are executed if :else is provided."
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

;;; Cancel Token

;;;###autoload
(defun concur-cancel-token-create ()
  "Create and return a new cancel token.
This function creates a new cancel token and marks it as active by default.

Returns:
  A cancel token struct, initialized with an `:active` field set to t."
  (make-concur-cancel-token :active t))

;;;###autoload
(defun concur-cancel-token-cancel (token)
  "Cancel the given TOKEN, marking it as inactive.
This function sets the cancel token's `:active` field to nil to indicate the task
associated with this token should be canceled.

Arguments:
  - token: The cancel token to cancel. Should be a valid cancel token object.
  
Side Effects:
  - Sets the `:active` field of the token to nil, marking it as canceled.
  
Error Handling:
  - Signals an error if the token is not a valid cancel token."
  (if (not (concur-cancel-token-active-p token))
      (error "The token is either nil or already canceled. Cannot cancel again."))
  (setf (concur-cancel-token-active token) nil)
  (concur--log! "Cancel token %s: Marked as canceled" (concur-cancel-token-name token)))

;;;###autoload
(defun concur-cancel-token-active-p (token)
  "Check if the cancel TOKEN is still active (i.e., not canceled).
This function checks the `:active` field of the token to determine if the task
associated with this token should still be active.

Arguments:
  - token: The cancel token to check. Should be a valid cancel token object.
  
Returns:
  - t if the token is active (not canceled).
  - nil if the token is canceled or invalid."
  (if (not token)
      (error "Invalid token: nil"))
  (concur-cancel-token-active token))

;;;###autoload
(defun concur-cancel-token-check (token)
  "Check if the task should be canceled by evaluating the cancel TOKEN.
If the token is canceled, this function logs the cancellation and returns `t` to
indicate that the task should be canceled. If the token is still active, it returns `nil`.

Arguments:
  - token: The cancel token to check.
  
Returns:
  - t if the token is canceled (task should be canceled).
  - nil if the token is active (task should continue)."
  (if (not (concur-cancel-token-active-p token))
      (progn
        (concur--log! "Task canceled due to token %s." (concur-cancel-token-name token))
        t)  ;; Return t to indicate cancellation
    nil))  ;; Return nil if the task is still active

(defun concur-cancel-token-name (token)
  "Return a human-readable name for the cancel TOKEN.
If the token contains a `:name` field, return that; otherwise, generate a unique name."
  (or (plist-get (concur-cancel-token-data token) :name)
      (symbol-name (gensym "cancel-token-"))))

;;; Async

;;;###autoload
(defun concur-async-task (task &optional delay)
  "Run TASK (a function returning a promise or value) asynchronously.

If DELAY is non-nil, the task will be scheduled after that many seconds
using `run-at-time`. If DELAY is nil, the task is scheduled to run using
`async-start` for a truly asynchronous, non-blocking execution.

Returns a concur-promise resolving to the task result."
  (let ((promise (concur-promise-new))
        (wrapped-task (concur-future-wrap (lambda () (funcall task)))))
    (if delay
        (run-at-time (or delay 0) nil
                     (lambda () (concur-future-force wrapped-task)))  ;; Force the wrapped task after delay
      (async-start
       `(lambda () (concur-future-force ,wrapped-task))  ;; Force the wrapped task when async starts
       (lambda (result) 
         (concur-promise-resolve promise result))))
    promise))

;;;###autoload
(defmacro concur-async! (&rest args)
  "Run BODY asynchronously with optional SEMAPHORE, :schedule nil, :cancel TOKEN, and :meta METADATA.

This macro wraps a body of code and runs it asynchronously, supporting optional
parameters for concurrency control, task scheduling, cancellation, and metadata.

Arguments:
  - BODY: The code to be executed asynchronously.
  - :semaphore (optional): A semaphore object to limit the number of concurrent tasks.
  - :schedule (optional): A boolean that determines if the task should be scheduled 
    immediately or queued for later execution (defaults to t).
  - :cancel (optional): A cancellation token, which can be used to cancel the task.
  - :meta (optional): Metadata associated with the task, such as identifiers or tags.

Returns:
  - A `concur-future` representing the result of the task, which can be awaited with
    `concur-await!`.

Behavior:
  - The macro creates a new task, wraps it in a `concur-future`, and schedules it for 
    execution in the background.
  - If a semaphore is provided, the body of the task will be executed with the semaphore
    to limit concurrent executions.
  - If a cancel token is provided, the task checks for cancellation and may short-circuit
    if the cancellation token is active.
  - The task is then added to the scheduler, where it will be executed asynchronously.

Example:
  (concur-async! 
    :semaphore some-semaphore
    :schedule nil
    :cancel cancel-token
    :meta '("task1")
    (do-some-work))

  ;; This example runs the `(do-some-work)` body asynchronously with a semaphore
  ;; and cancellation token. It will be scheduled immediately as the `:schedule`
  ;; argument is `nil`.

Error Handling:
  - If an error occurs during the execution of the task, it will be propagated and
    logged with `concur-promise-reject`."
  (declare (indent defun))  
  (let* ((args* args)       
         (semaphore nil)    
         (schedule t)       
         (cancel-token nil) 
         (meta nil)         
         (body nil))        

    ;; Extract keyword arguments (e.g. :schedule, :cancel, :meta)
    (while (keywordp (car (last args*)))
      (let ((kw (car (last args*)))
            (val (car (last (butlast args*)))))
        (setq args* (butlast args* 2))  
        (pcase kw
          (:schedule (setq schedule val))   
          (:cancel   (setq cancel-token val)) 
          (:meta     (setq meta val))         
          (_ (error "Unknown keyword %S in concur-async!" kw))))) 

    ;; Detect optional semaphore: if it's not a keyword, assume it's the semaphore
    (if (and args* (not (keywordp (car args*))))
        (setq semaphore (car args*)      
              body (cdr args*))          
      (setq body args*))                 

    ;; Generate symbols to avoid conflicts
    (let ((done   (gensym "done-"))      
          (result (gensym "result-"))    
          (self   (gensym "self-"))      
          (future (gensym "future-"))    
          (promise (gensym "promise-"))) 

      `(let* ((,done nil)         
              (,result nil))      

         (cl-labels ((,self ()
                         ;; This catch block is used to allow the asynchronous task
                         ;; to "yield" control back to the scheduler at certain points.
                         ;; If the task needs to pause (e.g., waiting for a semaphore or
                         ;; a cancellation check), it will throw the control to the 'concur-yield
                         ;; label, allowing the scheduler to take over.
                         ;;
                         ;; This makes the task cooperative, meaning that it can voluntarily
                         ;; give up control back to the scheduler at appropriate points.
                         ;;
                         ;; The catch will not end the task, it just allows for cooperative
                         ;; multitasking where the task can resume later after the yield point.

                         ;; Cancellation-aware logic:
                       (catch 'concur-yield
                         ;; Cancellation-aware logic:
                         (when ,(if cancel-token
                                    `(concur-cancel-token-active-p ,cancel-token)
                                  t)  
                           ;; Execute the task with semaphore or without
                           (setq ,result
                                 ,(if semaphore
                                      `(concur-with-semaphore! ,semaphore ,@body)
                                    `(progn ,@body))) 
                           (setq ,done t)))))  

           ;; Create the future task and wrap it in the scheduler
           (let* ((,future
                   (concur-future-wrap
                    (lambda ()
                      (setq ,promise (concur-future-promise ,future))
                      (condition-case err
                          (progn
                            ;; Start the task body asynchronously
                            (,self)  
                            (when ,done
                              (when ,(if cancel-token
                                         `(concur-cancel-token-active-p ,cancel-token)
                                       t)
                                (concur-promise-resolve ,promise ,result))))
                        (error
                         ;; Handle errors in the task body
                         (concur-promise-reject ,promise err)
                         (concur--log! "concur-async! task error: %S" err)))))))

              (task
               (make-concur-task
                :future ,future        
                :promise ,promise      
                :schedule ,schedule    
                :cancel ,cancel-token  
                :meta ,meta))          

             ;; Add the task to the scheduler for execution
             (concur-scheduler-queue-task task)
             ,promise))))     

;;;###autoload
(defmacro concur-await! (form)
  "Await the result of FORM, which must evaluate to a `concur-future` or `concur-promise`.

This macro blocks execution until the result of FORM is available, whether it's a
`concur-future` or a `concur-promise`. The future or promise can be created either
inside the scheduler or outside of it.

Behavior:
  - If called **inside the scheduler**, it yields cooperatively by re-queuing the
    task to the scheduler until the task is completed.
  - If called **outside the scheduler**, it uses a polling loop, periodically
    checking the status of the task with `sleep-for` to avoid blocking the Emacs
    event loop.

Arguments:
  - FORM: The expression that should evaluate to a `concur-future` or `concur-promise`.

Returns:
  - The value stored in the future or promise if successful, or signals an error if
    encountered.

Error Handling:
  - If the future or promise has encountered an error, it will be raised as a Lisp
    error using `signal`.

Example:
  (concur-await! (concur-async! (some-task)))
  ;; Wait until the asynchronous task completes, then continue execution."
  (let ((val (gensym "val"))
        (task (gensym "task"))
        (result (gensym "result")))
    `(let* ((,task ,form)
            (,val nil))
       ;; Check if FORM evaluates to a future or a promise
       (cl-assert (or (concur-future-p ,task) (concur-promise-p ,task))
                  nil "Expected a concur-future or concur-promise, but got: %S" ,task)

       (if (boundp 'concur--inside-scheduler)
           ;; If inside scheduler: yield cooperatively by re-queuing the task
           (cl-labels ((self ()
                          (unless (or (concur-future-done-p ,task)
                                      (concur-promise-done-p ,task))
                            (concur-scheduler-queue-task #'self))))
             ;; Block until the future or promise is done, using cooperative scheduling
             (concur-block-until
              (lambda () (or (concur-future-done-p ,task)
                             (concur-promise-done-p ,task)))
              #'self))

         ;; If outside scheduler: use polling loop with sleep to avoid blocking
         (while (not (or (concur-future-done-p ,task) (concur-promise-done-p ,task)))
           (sleep-for concur-await-poll-interval)))

       ;; Handle the result depending on whether it's a future or a promise
       (if (concur-future-error-p ,task)
           (signal (car (concur-future-error ,task))
                   (cdr (concur-future-error ,task)))

         ;; If it's a promise, resolve it using `concur-promise-value`
         (if (concur-promise-p ,task)
             (setq ,val (concur-promise-value ,task))
           ;; Otherwise, resolve the future
           (setq ,val (concur-future-value ,task))))

       ;; Return the value of the future or promise
       ,val)))

;;;###autoload
(cl-defun concur-async-task-wrap (fn-or-val &key catch finally semaphore schedule cancel-token)
  "Wrap FN-OR-VAL in an async task using `concur-async!`, with optional CATCH, FINALLY, SEMAPHORE, 
  SCHEDULE, and CANCEL-TOKEN.

If FN-OR-VAL is a function, it is invoked asynchronously. If FN-OR-VAL is a value, it is 
resolved immediately using `concur-promise-resolve`.

Arguments:
  - FN-OR-VAL: Either a function to execute asynchronously or a value to resolve immediately.
  - CATCH (optional): A function to handle errors in the asynchronous task.
  - FINALLY (optional): A function to be invoked when the task finishes, regardless of success or failure.
  - SEMAPHORE (optional): A semaphore to limit concurrency.
  - SCHEDULE (optional): If non-nil, bypass the task pool and run the task immediately without scheduling.
  - CANCEL-TOKEN (optional): A symbol or function to check for cancellation. If provided, task execution may 
  be short-circuited based on the token.

Returns:
  A `concur-future` that represents the result of the task."
  (if (functionp fn-or-val)
      ;; Forward the schedule symbol directly to concur-async!
      (concur-async!
       :catch catch
       :finally finally
       :semaphore semaphore
       :cancel cancel-token  
       :schedule schedule ;; Forward the schedule symbol here
       (funcall fn-or-val))
    ;; If FN-OR-VAL is already a value, resolve immediately
    (concur-promise-resolved! fn-or-val)))

;;;###autoload
(cl-defun concur-async-task-pipe (initial &rest fns &key semaphore schedule cancel-token)
  "Pipe INITIAL through FNS. Each function receives the result of the previous function.

This function executes each function in the sequence `fns` asynchronously, passing the result
from one function to the next. Optionally, SEMAPHORE can be used to limit concurrency.

Arguments:
  - INITIAL: The initial value passed into the first function in the pipeline.
  - FNS: A list of functions to apply in sequence to the result of the previous function.
  - SEMAPHORE (optional): A semaphore to control concurrency during the pipeline execution.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs the task immediately.
  - CANCEL-TOKEN (optional): A symbol or function to check for cancelation. If provided, task execution 
  may be short-circuited based on the token.

Returns:
  A `concur-future` representing the result of the last function in the pipeline."
  (let ((pipeline-fn
         (lambda (acc fn)
           (concur-promise-then acc
             (lambda (res)
               (concur-async-task-wrap (funcall fn res)
                                       :semaphore semaphore
                                       :schedule schedule
                                       :cancel cancel-token))))))
    ;; Apply each function in FNS to the result of the previous function in the pipeline
    (--reduce-from pipeline-fn
                   (concur-async-task-wrap initial :semaphore semaphore :schedule schedule :cancel cancel-token)
                   fns)))

;;;###autoload
(cl-defun concur-async-task-parallel (&rest tasks &key semaphore schedule cancel-token)
  "Run TASKS concurrently, with optional SEMAPHORE to limit concurrency.

Each task in TASKS is executed asynchronously. Optionally, a SEMAPHORE can be passed to
control the number of concurrent tasks.

Arguments:
  - TASKS: A list of functions or values to execute asynchronously.
  - SEMAPHORE (optional): A semaphore to limit concurrent task execution.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.
  - CANCEL-TOKEN (optional): A symbol or function to check for cancelation. If provided, task execution 
  may be short-circuited based on the token.

Returns:
  A `concur-future` representing the result of all tasks in parallel."
  (let ((wrapped (--map (lambda (task)
                          (concur-async-task-wrap task
                                                 :semaphore semaphore
                                                 :schedule schedule
                                                 :cancel cancel-token))
                        tasks)))
    ;; Wait for all tasks to complete and return their results
    (concur-promise-all wrapped)))

;;;###autoload
(cl-defun concur-async-task-map (task-fn tasks &key (semaphore 1) (cancel nil))
  "Map a function (TASK-FN) across a sequence of TASKS asynchronously.
TASK-FN should be a function that returns a thunk (a function to execute).
If CANCEL is provided and the cancellation condition is met, remaining tasks will be cancelled.

TASK-FN will be called asynchronously with each task in the TASKS list.

If no semaphore is provided, no concurrency limit will be enforced.
If no cancel token is provided, cancellation will not be handled."

  (let ((tasks-done 0)                 ;; Counter to track completed tasks
        (called? nil)                  ;; Flag to ensure callback is called once
        (total-tasks (length tasks))  ;; Total tasks to track
        (controller (make-symbol "concur-async-task-map-cancel-token"))
        (fallback-callback (lambda ()
                              (when (and (not called?) (>= tasks-done total-tasks))
                                (funcall cancel nil)))))
    
    (cl-labels
        ((should-cancel-p ()
           (or (and cancel (funcall cancel))
               (symbol-value controller)))

         (wrapped-task-fn (task)
           (lambda ()
             (unless (should-cancel-p)
               (funcall task)
               (setq tasks-done (1+ tasks-done))
               (when (and (not called?) (>= tasks-done total-tasks))
                 (funcall fallback-callback))))))
      
      ;; Apply wrapped task function to each task
      (mapc (lambda (task)
              (funcall (wrapped-task-fn task)))
            tasks)

      ;; Return a cancellation function
      (lambda ()
        (setf (symbol-value controller) t)))))

;;;###autoload
(cl-defun concur-async-task-race (task-fn tasks &key (semaphore 1) (cancel nil) (timeout-seconds nil))
  "Race across a sequence of tasks asynchronously, invoking the callback with the first successful result.

TASK-FN should be a function that takes a task and returns a thunk (a function to execute).
Each task is wrapped via `concur-async-task-wrap` and raced via `concur-promise-race`.

If CANCEL is provided (a cancel token), remaining tasks will be cancelled when the token becomes inactive.
If TIMEOUT-SECONDS is provided, each task will be subject to a timeout."
  (let* ((cancel-token (or cancel (concur-cancel-token-create)))
         (promises
          (--map (let* ((thunk (funcall task-fn it))
                        (wrapped (concur-async-task-wrap
                                  thunk
                                  :semaphore semaphore
                                  :cancel-token cancel-token)))
                   (if timeout-seconds
                       (concur-promise-timeout wrapped timeout-seconds)
                     wrapped))
                 tasks)))
    (concur-promise-race promises)))
    
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
         (concur-promise-then (concur-promise-delayed delay)
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

(defmacro concur-do-with-yield! (&rest forms)
  "Execute a sequence of forms, yielding control after each form.

This macro allows multiple forms to be executed in sequence, yielding control to
the asynchronous scheduler after each form. This ensures cooperative multitasking
and allows other tasks to be processed in between forms.

Arguments:
  - FORMS: A sequence of forms to be executed.

Returns:
  - The result of the last form executed."
  (let ((result (gensym "result-")))
    `(let ((,result nil))
       (catch 'concur-yield
         ,@(mapcar (lambda (form)
                    `(setq ,result (progn ,form))
                    (concur-yield!))
                  forms)
         ,result))))

(defmacro concur-do-with-conditional-yield! (condition &rest forms)
  "Execute a sequence of forms, yielding control after each form based on CONDITION.

Each form is executed in sequence, and after each form, the task yields control
to the scheduler if CONDITION is met.

Arguments:
  - CONDITION: The condition under which to yield.
  - FORMS: A sequence of forms to be executed.

Returns:
  - The result of the last form executed if no yields occurred."
  (let ((result (gensym "result-")))
    `(let ((,result nil))
       (catch 'concur-yield
         ,@(mapcar (lambda (form)
                    `(setq ,result (progn ,form))
                    `(when ,condition
                       (concur-yield!)))
                  forms)
         ,result))))


;; (defmacro concur-do-with-retry! (task &optional (max-retries 3) (delay 1))
;;   "Retry TASK up to MAX-RETRIES times, yielding between retries if necessary.

;; Arguments:
;;   - TASK: A task to retry.
;;   - MAX-RETRIES: The maximum number of retry attempts (default: 3).
;;   - DELAY: The delay in seconds between retries (default: 1).

;; Returns:
;;   - The result of TASK after retries or `nil` if it fails."
;;   (let ((attempts (gensym "attempts"))
;;         (result (gensym "result")))
;;     `(let ((,attempts 0)
;;            (,result nil))
;;        (catch 'concur-yield
;;          (while (< ,attempts ,max-retries)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (progn
;;                (setq ,attempts (1+ ,attempts))
;;                (concur-yield!)))
;;          ,result)))))

;; (defmacro concur-do-with-conditional-retry! (task condition &optional (max-retries 3) (delay 1))
;;   "Retry TASK if CONDITION is met, yielding control between retries."
;;   (let ((attempts (gensym "attempts"))
;;         (result (gensym "result")))
;;     `(let ((,attempts 0)
;;            (,result nil))
;;        (catch 'concur-yield
;;          (while (< ,attempts ,max-retries)
;;            (setq ,result (funcall ,task))
;;            (if (and ,result ,condition)
;;                (throw 'concur-yield ,result)
;;              (progn
;;                (setq ,attempts (1+ ,attempts))
;;                (concur-yield!)))
;;          ,result))))         

;; (defmacro concur-do-with-timeout! (task &optional (timeout 10))
;;   "Execute TASK with a timeout, yielding control periodically.

;; Arguments:
;;   - TASK: The task to execute.
;;   - TIMEOUT: The maximum time in seconds to allow for execution (default: 10).

;; Returns:
;;   - The result of TASK if it completes within the timeout, otherwise throws an error."
;;   (let ((start-time (gensym "start-time"))
;;         (elapsed-time (gensym "elapsed-time"))
;;         (result (gensym "result")))
;;     `(let ((,start-time (current-time))
;;            (,elapsed-time 0)
;;            (,result nil))
;;        (catch 'concur-yield
;;          (while (< ,elapsed-time ,timeout)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (progn
;;                (setq ,elapsed-time (float-time (time-subtract (current-time) ,start-time)))
;;                (concur-yield!)))
;;          (error "Timeout exceeded for task."))))))

;; (defmacro concur-do-with-exponential-backoff! (task &optional (max-retries 5) (initial-delay 1))
;;   "Retry TASK with exponential backoff, yielding between retries.

;; Arguments:
;;   - TASK: A task to retry.
;;   - MAX-RETRIES: The maximum number of retry attempts (default: 5).
;;   - INITIAL-DELAY: The initial delay in seconds between retries (default: 1).

;; Returns:
;;   - The result of TASK after retries or `nil` if it fails."
;;   (let ((attempts (gensym "attempts"))
;;         (delay (gensym "delay"))
;;         (result (gensym "result")))
;;     `(let ((,attempts 0)
;;            (,delay ,initial-delay)
;;            (,result nil))
;;        (catch 'concur-yield
;;          (while (< ,attempts ,max-retries)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (progn
;;                (setq ,attempts (1+ ,attempts))
;;                (setq ,delay (* 2 ,delay))  ;; Exponential backoff
;;                (concur-yield!)))
;;          ,result)))))

;; (defmacro concur-async-with-progress! (tasks &optional (progress-fn 'message))
;;   "Execute TASKS, yielding periodically and updating progress via PROGRESS-FN.

;; Arguments:
;;   - TASKS: A list of tasks to execute.
;;   - PROGRESS-FN: A function to report progress (default: `message`).

;; Returns:
;;   - The result of the last task executed, or `nil` if no tasks complete."
;;   (let ((task (gensym "task"))
;;         (total (gensym "total"))
;;         (current (gensym "current"))
;;         (result (gensym "result")))
;;     `(let ((,total (length ,tasks))
;;            (,current 0)
;;            (,result nil))
;;        (catch 'concur-yield
;;          (dolist (,task ,tasks)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (progn
;;                (funcall ,progress-fn (format "Progress: %d/%d" ,current ,total))
;;                (setq ,current (1+ ,current))
;;                (concur-yield!)))
;;          ,result))))

;; (defmacro concur-do-with-dependency! (tasks)
;;   "Execute TASKS with dependencies, yielding between each step.

;; Each task in TASKS is executed in order, and the task yields after each step.

;; Arguments:
;;   - TASKS: A list of tasks to execute.

;; Returns:
;;   - The result of the last task executed, or `nil` if no tasks complete."
;;   (let ((task (gensym "task"))
;;         (result (gensym "result")))
;;     `(let ((,result nil))
;;        (catch 'concur-yield
;;          (dolist (,task ,tasks)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (concur-yield!)))
;;          ,result))))

;; (defmacro concur-do-with-pause! (tasks &optional (pause-time 1))
;;   "Execute TASKS with a pause of PAUSE-TIME seconds between each, yielding control.

;; Arguments:
;;   - TASKS: A list of tasks to execute.
;;   - PAUSE-TIME: The time in seconds to pause between tasks (default: 1).

;; Returns:
;;   - The result of the last task executed, or `nil` if no tasks complete."
;;   (let ((task (gensym "task"))
;;         (result (gensym "result")))
;;     `(let ((,result nil))
;;        (catch 'concur-yield
;;          (dolist (,task ,tasks)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (sleep-for ,pause-time)
;;              (concur-yield!)))
;;          ,result))))

;; (defmacro concur-do-with-batch! (tasks)
;;   "Execute a batch of TASKS, yielding control after each one."
;;   (let ((task (gensym "task"))
;;         (result (gensym "result")))
;;     `(let ((,result nil))
;;        (catch 'concur-yield
;;          (dolist (,task ,tasks)
;;            (setq ,result (funcall ,task))
;;            (if ,result
;;                (throw 'concur-yield ,result)
;;              (concur-yield!)))
;;          ,result))))

;; (defmacro concur-do-with-async-map! (func items)
;;   "Apply FUNC to each item in ITEMS asynchronously, yielding control after each."
;;   `(concur-do-with-yield!
;;      (-each ,items
;;             (lambda (,item)
;;               (funcall ,func ,item)))))

;; (defmacro concur-do-with-async-chain! (tasks)
;;   "Chain a series of asynchronous TASKS, yielding after each task."
;;   `(concur-do-with-yield!
;;      (-reduce-from
;;       (lambda (,accumulated ,task)
;;         (let ((result (funcall ,task ,accumulated)))
;;           ;; Process the result of the task
;;           (message "Result: %s" result)
;;           (concur-yield!)
;;           result)
;;       nil
;;       ,tasks)))

;; (defmacro concur-do-with-periodic-task! (task &optional (interval 1))
;;   "Execute TASK periodically with a delay of INTERVAL seconds, yielding after each execution."
;;   `(concur-do-with-yield!
;;      (while t
;;        (funcall ,task)
;;        (sleep-for ,interval)
;;        (concur-yield!))))

;; (defmacro concur-schedule-task! (task)
;;   "Schedule TASK to run asynchronously, yielding control after each step."
;;   `(concur-do-with-yield! 
;;     (funcall ,task)))

;; (defmacro concur-process-queue! (queue)
;;   "Process items in the QUEUE asynchronously, yielding after each item."
;;   `(concur-do-with-yield!
;;      (while (not (queue-empty-p ,queue))
;;        (let ((item (queue-dequeue ,queue)))
;;          ;; Process the item here
;;          (message "Processing item: %s" item)
;;          (concur-yield!))))

;;; Aliases

(defalias 'concur-task-pipe 'concur-async-task-pipe)
(defalias 'concur-task-parallel 'concur-async-task-parallel)
(defalias 'concur-task-map 'concur-async-task-map)
(defalias 'concur-task-race 'concur-async-task-race)
(defalias 'concur-task-chain 'concur-async-task-chain)
(defalias 'concur-task-reduce 'concur-async-task-reduce)
(defalias 'concur-task-with-retries 'concur-async-task-with-retries)
(defalias 'concur-task-timeout 'concur-async-task-timeout)
(defalias 'concur-task-retry-while 'concur-async-retry-while)

(provide 'concur-task)
;;; concur.el ends here               

