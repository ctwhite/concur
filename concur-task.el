;;; concur-task.el --- Concurrency primitives for shared resources ---

(require 'cl-lib)
(require 'ts)

(cl-defstruct (concur-task
               (:constructor nil) ; disable default
               (:constructor concur-make-task (&key semaphore cancel-token future 
                                              schedule meta name started-at ended-at priority)))
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
  - started-at: A timestamp representing when the task started executing.
  - ended-at: A timestamp representing when the task finished executing.
  - priority: An integer value representing the priority of the task. Higher values indicate higher priority."
  semaphore
  cancel-token
  future
  schedule 
  meta
  name
  created-at
  started-at
  ended-at
  priority)

(defvar concur-task-started-hook nil
  "Hook run when a task is marked as started. Called with the task as the only argument.")

(defvar concur-task-ended-hook nil
  "Hook run when a task is marked as ended. Called with the task as the only argument.")
  
;;;###autoload
(defun concur-task-create (&rest args)
  "Create a `concur-task` with the current timestamp set for `created-at`."
  (apply #'concur-make-task
         :created-at (ts-now)
         args))

;;;###autoload
(defun concur-task-mark-started (task)
  "Mark TASK as started by setting its `started-at` timestamp to the current time."
  (setf (concur-task-started-at task) (ts-now)))

;;;###autoload
(defun concur-task-mark-ended (task)
  "Mark TASK as ended by setting its `ended-at` timestamp to the current time."
  (setf (concur-task-ended-at task) (ts-now)))

;;;###autoload
(defun concur-task-status (task)
  "Return the current status of TASK: 'running, 'completed, 'canceled, or 'pending.
If the task has a cancel token, we check if it has been canceled."
  (cond
   ((concur-task-started-at task)
    (if (concur-task-ended-at task)
        'completed    ;; Task has finished executing
      'running))     ;; Task has started but not yet finished
   ((concur-task-cancel-token task)
    (if (concur-task-cancel-token-canceled? (concur-task-cancel-token task))
        'canceled     ;; Task has been canceled
      'pending))     ;; Task is still pending and has a cancel token
   (t 'pending)))    ;; Task is still pending and has no cancel token

;;;###autoload
(defun concur-task-duration (task)
  "Return the duration of TASK from start to end in seconds.
If the task has not started or ended, returns nil."
  (when (and (concur-task-started-at task) (concur-task-ended-at task))
    (let ((start-time (seconds-to-time (concur-task-started-at task)))
          (end-time (seconds-to-time (concur-task-ended-at task))))
      (float-time (time-subtract end-time start-time)))))

;;;###autoload
(defun concur-task-describe (task)
  "Return a plist describing the state of TASK.

This function provides an overview of the task's state, including its name, priority, creation time,
start time, end time, schedule, and other associated data.

Arguments:
  - task: The task to describe.

Returns:
  - A plist containing the task's name, priority, creation time, start time, end time,
    schedule, semaphore, cancel token, future, and metadata."
  `(:name ,(or (concur-task-name task) "N/A")
    :priority ,(concur-task-priority task)
    :created-at ,(format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time (concur-task-created-at task)))
    :started-at ,(if (concur-task-started-at task)
                     (format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time (concur-task-started-at task)))
                   "Not Started")
    :ended-at ,(if (concur-task-ended-at task)
                   (format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time (concur-task-ended-at task)))
                 "Not Ended")
    :status ,(concur-task-status task)                 
    :schedule ,(symbol-name (concur-task-schedule task))
    :semaphore ,(or (concur-task-semaphore task) "None")
    :cancel-token ,(or (concur-task-cancel-token task) "None")
    :future ,(or (concur-task-future task) "None")
    :meta ,(or (concur-task-meta task) "None")))

(provide 'concur-task)
;;; concur-task.el ends here