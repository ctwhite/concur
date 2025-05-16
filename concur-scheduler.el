;;; concur-scheduler.el --- Concurrency scheduler for managing asynchronous tasks -*- lexical-binding: t; -*-
;;
;; Commentary:
;;
;; This file defines a scheduler system for managing the execution of asynchronous tasks in
;; a concurrent environment. It allows tasks to be queued, prioritized, and executed according
;; to their defined scheduling criteria, while managing task cancellations and semaphores.
;;
;; The scheduler uses a priority queue to handle tasks with differing priorities, ensuring that
;; higher-priority tasks are executed first. Tasks can be scheduled to run immediately, 
;; asynchronously, or within the current event loop.
;;
;; The following structures and variables are defined:
;;
;; - `concur-scheduler--task-queue`: A priority queue that holds pending tasks, ensuring that tasks 
;;   are executed according to their priority.
;; 
;; - `concur-scheduler-max-queue-length`: A configurable maximum size for the task queue.
;;
;; Functions in this file include:
;; - `concur-scheduler-enqueue-task`: Adds a task to the scheduler queue, ensuring the queue 
;;   doesn't exceed the maximum size.
;; - `concur-scheduler-dequeue-task`: Removes the highest-priority task from the queue.
;; - `concur-scheduler-remove-task`: Removes a specific task from the scheduler queue.
;; - `concur-scheduler-start`: Starts the scheduler and begins processing tasks.
;; - `concur-scheduler-stop`: Stops the scheduler from processing tasks.
;; - `concur-scheduler-pending-count`: Returns the number of tasks currently pending in the 
;;   scheduler.
;;
;; This system is designed to support efficient task scheduling, priority-based task handling, 
;; and the ability to manage cancellation tokens, semaphores, and task dependencies.
;;
;;; Code:

(require 'cl-lib)
(require 'concur-cancel)
(require 'concur-future)
(require 'concur-primitives)
(require 'concur-promise)
(require 'concur-priority-queue)
(require 'ht)
(require 'scribe)

(declare-function concur-task-priority "concur-task")

(defcustom concur-scheduler-max-queue-length 100
  "Maximum number of tasks allowed in the scheduler queue."
  :type 'integer
  :group 'concur)

(defcustom concur-scheduler-idle-delay nil
  "Delay (seconds) between scheduler ticks when idle."
  :type 'number
  :group 'concur)

(defvar concur-scheduler-error-hook nil
  "Hook run if a task throws during async scheduler execution.")

(defvar concur-scheduler--task-queue
  (concur-priority-queue-create :comparator #'concur-scheduler--priority-comparator)
  "Priority queue of pending `concur-task` objects for the async scheduler.")

(defvar concur-scheduler--running nil
  "Non-nil when executing within the concur scheduler.")

(defvar concur-scheduler--idle-timer nil
  "Idle timer that processes the async task queue.")

(defun concur-scheduler--priority-comparator (task-a task-b)
  "Compare the priorities of TASK-A and TASK-B, which are `concur-task` objects."
  (let ((priority-a (concur-task-priority task-a))
        (priority-b (concur-task-priority task-b)))
    (< priority-a priority-b)))

(defun concur-scheduler--delay-for-size (n)
  "Return a dynamic delay based on queue size N.
Fast (~1ms) when backlog is large; slower (~200ms) when idle."
  (let ((min-delay 0.001)
        (max-delay 0.2))
    (-> (/ 0.1 (log (1+ n) 2))
        (min max-delay)
        (max min-delay))))

(defun concur-scheduler-computed-delay ()
  "Compute delay based on current queue size."
  (concur-scheduler--delay-for-size (concur-scheduler-pending-count)))

(defun concur-scheduler-start ()
  "Start the asynchronous promise scheduler if it is not already running.

This function checks if the promise scheduler is already active by verifying
whether there is an existing idle timer. If no timer is active, it starts
a new timer to run the promise scheduler periodically.

The promise scheduler is responsible for running queued asynchronous tasks
when the Emacs event loop is idle.

Side Effects:
- Starts an idle timer to periodically run the promise scheduler.
- Logs the action using `log!`." 
 (unless (and concur-scheduler--idle-timer
               (memq concur-scheduler--idle-timer timer-idle-list))
    (setq concur-scheduler--idle-timer
          (run-with-idle-timer (or concur-scheduler-idle-delay (concur-scheduler-computed-delay)) t
                               #'concur-scheduler-run))
    (log! "Started promise scheduler")))

(defun concur-scheduler-stop ()
  "Stop the asynchronous promise scheduler if it is running.

This function cancels the currently active idle timer if one exists and
clears the associated state. If the scheduler is running, it will stop
executing scheduled tasks.

Side Effects:
- Cancels the idle timer used to run the promise scheduler.
- Logs the action using `log!`."
  (when (timerp concur-scheduler--idle-timer)
    (cancel-timer concur-scheduler--idle-timer)
    (setq concur-scheduler--idle-timer nil)
    (log! "Stopped promise scheduler")))

(defun concur-scheduler-run ()
  "Run the next task in the async queue, or stop if the queue is empty.

This function is responsible for executing the next task in the async task queue.
It checks the scheduling preferences of the task and runs it accordingly. If the
task queue is empty, the scheduler will stop. Otherwise, it dequeues the next task 
and processes it.

The scheduling behavior depends on the `:schedule` value associated with each task:
  - t: Runs the task immediately using `run-at-time` with a delay of 0 (essentially 
    scheduling it for immediate execution).
  - nil: Runs the task immediately in the current context.
  - 'async: Schedules the task for asynchronous execution using `async-start`.
  - 'deferred: Schedules the task to run after the current event loop using `run-at-time`.

Error handling is done with `condition-case`, and any errors that occur during task
execution are passed to `concur-promise-reject` and logged using `log!`.

This function interacts with:
  - `concur-scheduler--task-queue`: A ring buffer that holds the tasks waiting to be executed.
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
  (if (null concur-scheduler--running)
    (let ((concur-scheduler--running t))
      (unwind-protect
          (log! "Checking for tasks to run")
          (if (concur-priority-queue-empty? concur-scheduler--task-queue)
              (concur-scheduler-stop)
            (progn
              (log! "Running next task")
              (let ((task (concur-priority-queue-pop concur-scheduler--task-queue)))
                (concur--run-task task))))
        (setq concur-scheduler--running nil)))
    (log! "Promise scheduler already running")))

(defun concur--run-task (task)
  "Run TASK according to its schedule strategy with error handling and tracing support."
  (unless (eq (concur-task-status task) 'success)
    (let* ((name (or (concur-task-name task) "<unnamed>"))
           (future (concur-task-future task))
           (thunk (concur-future-thunk future))
           (schedule (concur-task-schedule task)))

      (log! "[%s] Starting task execution (schedule: %s)" name schedule :level 'info)

      ;; Wrap the thunk in error-handling and tracing logic
      (let ((wrapped-fn
             (lambda ()
               (condition-case err
                   (progn
                     (log! "[%s] Invoking task thunk..." name :level 'debug)
                     (funcall thunk))
                 (error
                  (run-hook-with-args 'concur-scheduler-error-hook err)
                  (log! "[%s] Task error: %S" name err :level 'error :trace)
                  (signal 'concur-task-error (list err)))))))

        ;; Run the thunk via `concur-async!`, which handles scheduling strategy
        (let ((promise (concur-async! wrapped-fn schedule)))
          (setf (concur-future-promise future) promise)
          (log! "[%s] Task dispatched (promise: %s)" name promise :level 'debug :trace))))))

;;;###autoload
(defun concur-scheduler-enqueue-task (task)
  "Queue TASK into the asynchronous scheduler. If the queue is full, the lowest-priority 
task will be removed.

TASK must be a `concur-task' object. This adds it to the task queue, registers
any cancel token, and ensures the scheduler is running."  
  (cl-assert (concur-task-p task))
  (log! "Enqueuing task: %s" task)

  ;; Log current queue size before insertion
  (let ((pending (concur-scheduler-pending-count)))
    (log! "Current pending tasks: %d (max allowed: %d)"
          pending concur-scheduler-max-queue-length)
    ;; Check if the queue is full, and remove the lowest-priority task if necessary
    (when (>= pending concur-scheduler-max-queue-length)
      (log! "Queue full; removing lowest-priority task before enqueue")
      (concur-priority-queue-remove-n concur-scheduler--task-queue 1)
      (log! "Lowest-priority task removed")))

  ;; Insert the task into the priority queue
  (concur-priority-queue-insert concur-scheduler--task-queue task)
  (log! "Task inserted; new pending count: %d" (concur-scheduler-pending-count))

  ;; Register cancel token if present
  (when-let ((token (concur-task-cancel-token task)))
    (log! "Registering cancel token: %s for task: %s" token task)
    (concur-cancel-register-token token task
                                 (lambda () 
                                   (log! "Cancel token triggered, removing task: %s" task)
                                   ;; Callback to remove the task from the queue when the token is canceled
                                   (concur-scheduler-remove-task task))))

  ;; Boost throughput under load
  (when (> (concur-scheduler-pending-count) 10)
    (log! "Pending tasks > 10, restarting scheduler to boost throughput")
    (concur-scheduler-stop)
    (concur-scheduler-start)
    (log! "Scheduler restarted"))

  ;; Ensure scheduler is running
  (concur-scheduler-start)
  (log! "Scheduler started (or ensured running)"))

;;;###autoload
(defsubst concur-scheduler-clear-queue ()
  "Clear all pending asynchronous tasks in the task queue."
  (concur-priority-queue-clear concur-scheduler--task-queue))

;;;###autoload
(defsubst concur-scheduler-pending-count ()
  "Return the number of pending tasks in the task queue.

This function simply returns the length of the task queue, which represents
the number of tasks that are currently queued for execution.

Return Value:
- The number of pending tasks in the task queue as an integer."
  (concur-priority-queue-length concur-scheduler--task-queue))

;;;###autoload
(defun concur-scheduler-remove-task (task)
  "Remove TASK from the scheduler priority queue."
  ;; Remove the task from the priority queue
  (concur-priority-queue-remove concur-scheduler--task-queue task)

  ;; Optionally restart the scheduler if needed
  (when (> (concur-scheduler-pending-count) 10)
    (concur-scheduler-stop)
    (concur-scheduler-start)))

;;;###autoload
(defun concur-scheduler-status ()
  "Return an alist describing the scheduler state."
  (let* ((pending (concur-scheduler-pending-count))
         (capacity concur-scheduler-max-queue-length))
    `((running . ,(timerp concur-scheduler--idle-timer))
      (pending . ,pending)
      (capacity . ,capacity)
      (saturation . ,(if (zerop capacity) 0 (/ (float pending) capacity)))
      (delay . ,(concur-scheduler--delay-for-size pending))
      (idle . ,(zerop pending)))))

(provide 'concur-scheduler)
;;; concur-scheduler.el ends here