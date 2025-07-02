;;; concur-abstract-pool.el --- Abstract Worker Pool Core -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a generic, thread-safe, and highly configurable
;; abstract worker pool. It manages the lifecycle of worker processes,
;; task queuing, dispatching, and error handling.
;;
;; It also includes the `concur:define-pool-type!` macro, which acts as
;; a factory for generating the boilerplate required for a new, specialized
;; pool type (e.g., for shell commands or Lisp evaluation).

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'json)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-priority-queue)
(require 'concur-log)
(require 'concur-nursery)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-abstract-pool-error "Generic pool error." 'concur-error)
(define-error 'concur-invalid-abstract-pool-error "Invalid pool object."
  'concur-abstract-pool-error)
(define-error 'concur-abstract-pool-shutdown "Pool was shut down."
  'concur-abstract-pool-error)
(define-error 'concur-abstract-pool-task-error "Task execution failed."
  'concur-abstract-pool-error)
(define-error 'concur-abstract-pool-poison-pill
  "Task repeatedly crashed workers."
  'concur-abstract-pool-error)

(defcustom concur-abstract-pool-default-size 4
  "The default number of workers in an abstract pool."
  :type 'integer :group 'concur)

(defcustom concur-abstract-pool-max-worker-restarts 3
  "Maximum consecutive restart attempts for a failed worker.
If a worker fails more than this, it's marked as permanently failed."
  :type 'integer :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-abstract-task (:constructor %%make-abstract-task))
  "Represents a generic task for the abstract worker pool.

Fields:
  promise: The `concur-promise` associated with the task's result.
  id: A unique string identifier for the task.
  payload: The actual data or command to be processed by the worker.
  context: A plist for additional data (e.g., :vars, :cwd).
  on-message-fn: A function `(lambda (payload))` called for progress updates.
  priority: The scheduling priority, where a lower value means higher priority.
  retries: The number of times the task has been retried after a worker crash.
  worker: The `concur-abstract-worker` currently executing the task, if any.
  cancel-token: An optional `concur-cancel-token` to request task cancellation."
  (promise nil :type concur-promise)
  (id nil :type string)
  (payload nil)
  (context nil :type plist)
  (on-message-fn nil :type (or null function))
  (priority 50 :type integer)
  (retries 0 :type integer)
  (worker nil :type (or null concur-abstract-worker))
  (cancel-token nil :type (or null concur-cancel-token)))

(cl-defstruct (concur-abstract-worker (:constructor %%make-abstract-worker))
  "Represents a single generic worker in an abstract pool.

Fields:
  process: The underlying Emacs `process` object for the worker.
  id: A unique integer identifier for the worker within the pool.
  status: The current state of the worker, one of :idle, :busy, :reserved,
    :restarting, :dead, :failed.
  current-task: The `concur-abstract-task` currently assigned to this worker.
  restart-attempts: The number of consecutive restart attempts for this worker."
  (process nil :type (or null process))
  (id nil :type integer)
  (status :idle :type (member :idle :busy :reserved :restarting :dead :failed))
  (current-task nil :type (or null concur-abstract-task))
  (restart-attempts 0 :type integer))

(cl-defstruct (concur-abstract-pool (:constructor %%make-abstract-pool))
  "Represents a generic pool of persistent worker processes.

Fields:
  name: A descriptive string name for the pool.
  workers: A list of `concur-abstract-worker` instances in the pool.
  lock: A `concur-lock` to ensure thread-safe operations on the pool.
  task-queue: The queue for pending tasks (`concur-queue` or `concur-priority-queue`).
  waiter-queue: A `concur-queue` for sessions waiting for a dedicated worker.
  worker-factory-fn: A function `(lambda (worker pool))` to create a worker process.
  worker-ipc-filter-fn: A function `(lambda (worker chunk pool))` to process raw output.
  worker-ipc-sentinel-fn: A function `(lambda (worker event pool))` to handle worker death.
  task-serializer-fn: A function `(lambda (payload context))` to serialize a task.
  result-parser-fn: A function `(lambda (string))` to parse a result string.
  error-parser-fn: A function `(lambda (string))` to parse an error string.
  message-parser-fn: A function `(lambda (string))` to parse a progress message.
  shutdown-p: A boolean that is `t` if the pool is shutting down."
  (name nil :type string)
  (workers nil :type (or null list))
  (lock nil :type concur-lock)
  (task-queue nil :type (or concur-queue concur-priority-queue))
  (waiter-queue nil :type concur-queue)
  (worker-factory-fn nil :type function)
  (worker-ipc-filter-fn nil :type function)
  (worker-ipc-sentinel-fn nil :type function)
  (task-serializer-fn nil :type function)
  (result-parser-fn nil :type function)
  (error-parser-fn nil :type function)
  (message-parser-fn nil :type function)
  (shutdown-p nil :type boolean))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Common Pool Logic

(defun concur--validate-abstract-pool (pool function-name)
  "Signal an error if POOL is not a `concur-abstract-pool`.

Arguments:
  POOL: The object to validate.
  FUNCTION-NAME: The symbol of the calling function for the error message.

Returns:
  nil.

Signals:
  `concur-invalid-abstract-pool-error`: If POOL is not a valid pool object."
  (unless (concur-abstract-pool-p pool)
    (signal 'concur-invalid-abstract-pool-error
            (list (format "%s: Invalid pool object" function-name) pool))))

(defun concur--abstract-worker-sentinel-dispatcher (process event pool)
  "Generic sentinel dispatcher. Calls the pool-specific sentinel handler.

Arguments:
  PROCESS: The worker process that triggered the event.
  EVENT: The process event string (e.g., \"finished\").
  POOL: The pool that owns the worker.

Returns:
  nil."
  (when-let ((worker (process-get process 'concur-abstract-worker)))
    (funcall (concur-abstract-pool-worker-ipc-sentinel-fn pool)
             worker event pool)))

(defun concur--abstract-worker-filter-dispatcher (process chunk pool)
  "Generic filter dispatcher. Calls the pool-specific filter handler.

Arguments:
  PROCESS: The worker process that produced the output.
  CHUNK: The string of output from the process.
  POOL: The pool that owns the worker.

Returns:
  nil."
  (when-let ((worker (process-get process 'concur-abstract-worker)))
    (funcall (concur-abstract-pool-worker-ipc-filter-fn pool)
             worker chunk pool)))

(defun concur--abstract-pool-start-worker (worker pool)
  "Start a worker using the pool's factory and configure its IPC handlers.

Arguments:
  WORKER: The `concur-abstract-worker` instance to start.
  POOL: The pool to which the worker belongs.

Returns:
  nil."
  (funcall (concur-abstract-pool-worker-factory-fn pool) worker pool)
  (let ((process (concur-abstract-worker-process worker)))
    (process-put process 'concur-abstract-worker worker)
    (set-process-sentinel process
                          (lambda (p e)
                            (concur--abstract-worker-sentinel-dispatcher p e pool)))
    (set-process-filter process
                        (lambda (p c)
                          (concur--abstract-worker-filter-dispatcher p c pool)))))

(defun concur--abstract-pool-release-worker (worker pool)
  "Release a worker back to the pool, making it available for new tasks.

Arguments:
  WORKER: The `concur-abstract-worker` to release.
  POOL: The pool to which the worker belongs.

Returns:
  nil."
  (concur:with-mutex! (concur-abstract-pool-lock pool)
    (setf (concur-abstract-worker-status worker) :idle)
    (setf (concur-abstract-worker-current-task worker) nil)
    (setf (concur-abstract-worker-restart-attempts worker) 0)
    (concur--abstract-pool-dispatch-next-task pool)))

(defun concur--abstract-pool-handle-worker-output (worker task output pool)
  "Handle a single parsed OUTPUT from a WORKER.
Dispatches based on message type (`:result`, `:error`, `:message`).

Arguments:
  WORKER: The `concur-abstract-worker` that sent the output.
  TASK: The `concur-abstract-task` that was executing.
  OUTPUT: A plist from the filter, e.g., `(:type TYPE :payload RAW-PAYLOAD)`.
  POOL: The `concur-abstract-pool` owning the worker.

Returns:
  nil."
  (pcase (plist-get output :type)
    (:result
     (let* ((raw-payload (plist-get output :payload))
            (result (funcall (concur-abstract-pool-result-parser-fn pool) raw-payload)))
       (concur:resolve (concur-abstract-task-promise task) result))
     (concur--abstract-pool-release-worker worker pool))

    (:error
     (let* ((raw-payload (plist-get output :payload))
            (cause (funcall (concur-abstract-pool-error-parser-fn pool) raw-payload)))
       (concur:reject (concur-abstract-task-promise task)
                      (concur:make-error
                       :type 'concur-abstract-pool-task-error
                       :message "Task failed in worker."
                       :cause cause)))
     (concur--abstract-pool-release-worker worker pool))

    (:message
     (when-let ((on-message-fn (concur-abstract-task-on-message-fn task)))
       (let* ((raw-payload (plist-get output :payload))
              (message (funcall (concur-abstract-pool-message-parser-fn pool) raw-payload)))
         (funcall on-message-fn message))))

    (_
     (concur--log :warn (concur-abstract-worker-id worker)
                  "Unknown message type from worker: %S" output))))

(defun concur--abstract-pool-requeue-or-reject-failed-task (task pool)
  "Handle a task that was running when its worker died.

It re-queues the task if it has remaining retries, otherwise it
rejects the task's promise, marking it as a 'poison pill'.

Arguments:
  TASK: The `concur-abstract-task` to process.
  POOL: The `concur-abstract-pool`.

Returns:
  nil."
  (cl-incf (concur-abstract-task-retries task))
  (if (> (concur-abstract-task-retries task) concur-abstract-pool-max-worker-restarts)
      (progn
        (concur--log :error nil "Task %s repeatedly crashed workers. Rejecting."
                     (concur-abstract-task-id task))
        (concur:reject
         (concur-abstract-task-promise task)
         (concur:make-error
          :type 'concur-abstract-pool-poison-pill
          :message (format "Task %s repeatedly crashed workers."
                           (concur-abstract-task-id task)))))
    (concur--log :info nil "Re-queuing task %s (retry %d)."
                 (concur-abstract-task-id task) (concur-abstract-task-retries task))
    (concur:with-mutex! (concur-abstract-pool-lock pool)
      (let ((task-queue (concur-abstract-pool-task-queue pool)))
        (funcall (if (eq (type-of task-queue) 'concur-priority-queue)
                     #'concur:priority-queue-insert
                   #'concur:queue-enqueue)
                 task-queue task)))))

(defun concur--abstract-pool-restart-or-fail-worker (worker pool)
  "Restart a dead worker or mark it as permanently failed.
MUST be called from within the pool's lock.

Arguments:
  WORKER: The dead `concur-abstract-worker`.
  POOL: The `concur-abstract-pool`.

Returns:
  nil."
  (setf (concur-abstract-worker-status worker) :dead)
  (unless (concur-abstract-pool-shutdown-p pool)
    (cl-incf (concur-abstract-worker-restart-attempts worker))
    (if (> (concur-abstract-worker-restart-attempts worker)
           concur-abstract-pool-max-worker-restarts)
        (progn
          (setf (concur-abstract-worker-status worker) :failed)
          (concur--log :error (concur-abstract-worker-id worker)
                       "Worker failed permanently; not restarting."))
      (progn
        (setf (concur-abstract-worker-status worker) :restarting)
        (concur--log :info (concur-abstract-worker-id worker)
                     "Restarting worker (attempt %d)..."
                     (concur-abstract-worker-restart-attempts worker))
        (concur--abstract-pool-start-worker worker pool)))))

(defun concur--abstract-pool-handle-worker-death (worker event pool)
  "Handle worker death, managing restarts and re-queuing its task.

Arguments:
  WORKER: The `concur-abstract-worker` that died.
  EVENT: The process event string from the sentinel.
  POOL: The pool to which the worker belongs.

Returns:
  nil."
  (concur--log :warn (concur-abstract-worker-id worker) "Worker (%s) died. Event: %s"
               (process-name (concur-abstract-worker-process worker))
               event)

  (when-let ((task (concur-abstract-worker-current-task worker)))
    (concur--abstract-pool-requeue-or-reject-failed-task task pool))

  (concur:with-mutex! (concur-abstract-pool-lock pool)
    (concur--abstract-pool-restart-or-fail-worker worker pool)
    (concur--abstract-pool-dispatch-next-task pool)))

(defun concur--worker-ipc-read-line ()
  "Read a single line from stdin for IPC.
Returns nil on EOF, which signals the worker to exit.

Returns:
  (or string null): The line read from stdin, or nil on EOF."
  (condition-case nil
      (let ((line (read-from-minibuffer "")))
        (if (string-empty-p line) nil line))
    (end-of-file nil)))

(defun concur--worker-execute-and-report-task (task-data task-executor-fn pid)
  "Execute a single task and report its result or error via stdout.

Arguments:
  TASK-DATA: A plist of the deserialized task data.
  TASK-EXECUTOR-FN: The function `(payload context)` to run the task.
  PID: The Process ID of this worker, for logging.

Returns:
  nil."
  (let* ((id (plist-get task-data :id))
         (payload (plist-get task-data :payload))
         (context (plist-get task-data :context)))
    (concur--log :debug pid "Executing task %s." id)
    (condition-case err
        (let ((result (funcall task-executor-fn payload context)))
          (concur--log :debug pid "Task %s finished. Sending result." id)
          (princ (format "R:%s\n" (json-encode `(:id ,id :result ,result)))))
      (error
       (concur--log :error pid "Task %s failed: %S" id err)
       (princ (format "E:%s\n"
                      (json-encode
                       `(:id ,id :error ,(concur-serialize-error err)))))))))

(defun concur--abstract-worker-entry-point (task-executor-fn init-fn)
  "Generic main entry point for a background worker process.
This runs in a loop, reading tasks from stdin, executing them,
and writing results/errors to stdout.

Arguments:
  TASK-EXECUTOR-FN: `(lambda (payload context))` that performs the task's work.
  INIT-FN: An optional `(lambda ())` function for one-time worker setup.

Returns:
  This function never returns. It exits via `kill-emacs` on EOF."
  (let ((print-escape-nonascii t)
        (pid (emacs-pid)))
    (concur--log :info pid "Process started.")
    (when init-fn (funcall init-fn))
    (concur--log :info pid "Entering main task loop.")

    (while t
      (concur--log :debug pid "Waiting for task on stdin...")
      (let ((json-object-type 'plist)
            (line (concur--worker-ipc-read-line)))
        (if line
            (condition-case err
                (let ((task-data (json-read-from-string line)))
                  (concur--worker-execute-and-report-task
                   task-data task-executor-fn pid))
              (error
               (concur--log :error pid
                            (concat "FATAL: Failed to parse JSON. "
                                    "Line: '%s'. Error: %S")
                            line err)
               (kill-emacs 1)))
          (concur--log :info pid "Received EOF. Exiting.")
          (kill-emacs 0))))))

(defun concur--abstract-pool-dispatch-to-waiter (waiter worker)
  "Assign a dedicated WORKER to a waiting session (WAITER).

Arguments:
  WAITER: The `(cons resolve-fn reject-fn)` for the session.
  WORKER: The idle `concur-abstract-worker` to reserve.

Returns:
  nil."
  (concur--log :debug (concur-abstract-worker-id worker)
               "Servicing a session waiter.")
  (setf (concur-abstract-worker-status worker) :reserved)
  (setf (concur-abstract-worker-restart-attempts worker) 0)
  (funcall (car waiter) worker))

(defun concur--abstract-pool-dispatch-to-task (task worker pool)
  "Assign a TASK to an idle WORKER.

Arguments:
  TASK: The `concur-abstract-task` to execute.
  WORKER: The idle `concur-abstract-worker`.
  POOL: The `concur-abstract-pool`.

Returns:
  nil."
  (let ((serialized-task
         (funcall (concur-abstract-pool-task-serializer-fn pool)
                  (concur-abstract-task-payload task)
                  (concur-abstract-task-context task))))
    (concur--log :debug (concur-abstract-worker-id worker)
                 "Dispatching task %s." (concur-abstract-task-id task))
    (setf (concur-abstract-worker-status worker) :busy)
    (setf (concur-abstract-worker-current-task worker) task)
    (setf (concur-abstract-task-worker task) worker)
    (condition-case err
        (process-send-string (concur-abstract-worker-process worker)
                             (concat serialized-task "\n"))
      (error
       (concur--log :error (concur-abstract-worker-id worker)
                    "Failed to send task. Error: %S" err)
       (let ((task-queue (concur-abstract-pool-task-queue pool)))
         (funcall (if (eq (type-of task-queue) 'concur-priority-queue)
                      (lambda (q t) (concur:priority-queue-insert q t 0))
                    #'concur:queue-enqueue-front)
                  task-queue task))
       (delete-process (concur-abstract-worker-process worker))))))

(defun concur--abstract-pool-dispatch-next-task (pool)
  "Find an idle worker and dispatch the next task or waiting session.
MUST be called from within the pool's lock.

Arguments:
  POOL: The `concur-abstract-pool`.

Returns:
  nil."
  (unless (concur-abstract-pool-shutdown-p pool)
    (if-let ((worker (cl-find-if (lambda (w)
                                   (eq (concur-abstract-worker-status w) :idle))
                                 (concur-abstract-pool-workers pool))))
        (if-let ((waiter (concur:queue-dequeue
                          (concur-abstract-pool-waiter-queue pool))))
            (concur--abstract-pool-dispatch-to-waiter waiter worker)
          (let ((task-queue (concur-abstract-pool-task-queue pool)))
            (unless (concur:queue-empty-p task-queue)
              (let ((task (concur:queue-dequeue task-queue)))
                (concur--abstract-pool-dispatch-to-task task worker pool)))))
      (concur--log :debug nil
                   "Dispatcher finished: no idle workers available."))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Pool Management and Task Submission

(cl-defun concur-abstract-pool-create (&key name
                                            (size concur-abstract-pool-default-size)
                                            (task-queue-type :fifo)
                                            worker-factory-fn
                                            worker-ipc-filter-fn
                                            worker-ipc-sentinel-fn
                                            task-serializer-fn
                                            result-parser-fn
                                            error-parser-fn
                                            message-parser-fn)
  "Create and initialize a new abstract worker pool.

Arguments:
  :name (string): A descriptive name for the pool.
  :size (integer): The number of worker processes to create.
  :task-queue-type (keyword): `:fifo` or `:priority`.
  :worker-factory-fn (function): REQUIRED. `(lambda (worker pool))` that
    creates and returns a worker `process`.
  :worker-ipc-filter-fn (function): REQUIRED. `(lambda (worker chunk pool))`
    that handles raw output from a worker.
  :worker-ipc-sentinel-fn (function): REQUIRED. `(lambda (worker event pool))`
    that handles worker process death.
  :task-serializer-fn (function): REQUIRED. `(lambda (payload context))`
    that serializes a task to a string for IPC.
  :result-parser-fn (function): REQUIRED. `(lambda (string))` that parses
    a result string from a worker.
  :error-parser-fn (function): REQUIRED. `(lambda (string))` that parses
    an error string from a worker.
  :message-parser-fn (function): REQUIRED. `(lambda (string))` that parses
    a progress message string from a worker.

Returns:
  (concur-abstract-pool): The new, initialized abstract worker pool instance.

Signals:
  `error`: If required arguments are missing or invalid."
  (unless (and (integerp size) (> size 0))
    (error "Pool size must be a positive integer: %S" size))
  (--each `((:worker-factory-fn . ,worker-factory-fn)
            (:worker-ipc-filter-fn . ,worker-ipc-filter-fn)
            (:worker-ipc-sentinel-fn . ,worker-ipc-sentinel-fn)
            (:task-serializer-fn . ,task-serializer-fn)
            (:result-parser-fn . ,result-parser-fn)
            (:error-parser-fn . ,error-parser-fn)
            (:message-parser-fn . ,message-parser-fn))
    (unless (functionp (cdr it)) (error "%s must be a function." (car it))))

  (let* ((pool-name (or name (format "abstract-pool-%s" (make-temp-name ""))))
         (task-queue (pcase task-queue-type
                       (:fifo (concur-queue-create))
                       (:priority (concur-priority-queue-create))
                       (_ (error "Invalid :task-queue-type: %S"
                                 task-queue-type))))
         (pool (%%make-abstract-pool
                :name pool-name
                :lock (concur:make-lock (format "pool-lock-%s" pool-name))
                :task-queue task-queue
                :waiter-queue (concur-queue-create)
                :worker-factory-fn worker-factory-fn
                :worker-ipc-filter-fn worker-ipc-filter-fn
                :worker-ipc-sentinel-fn worker-ipc-sentinel-fn
                :task-serializer-fn task-serializer-fn
                :result-parser-fn result-parser-fn
                :error-parser-fn error-parser-fn
                :message-parser-fn message-parser-fn)))
    (setf (concur-abstract-pool-workers pool)
          (cl-loop for i from 1 to size collect
                   (let ((worker (%%make-abstract-worker :id i)))
                     (concur--abstract-pool-start-worker worker pool)
                     worker)))
    (concur:with-mutex! (concur-abstract-pool-lock pool)
      (concur--abstract-pool-dispatch-next-task pool))
    pool))

(defun concur--abstract-pool-setup-task-cancellation (task pool)
  "Set up the cancellation logic for a task.

Arguments:
  TASK: The `concur-abstract-task` to add cancellation logic to.
  POOL: The `concur-abstract-pool` the task belongs to.

Returns:
  nil."
  (concur:cancel-token-add-callback
   (concur-abstract-task-cancel-token task)
   (lambda ()
     (concur--log :info nil "Cancellation requested for task %s."
                  (concur-abstract-task-id task))
     (concur:with-mutex! (concur-abstract-pool-lock pool)
       (let* ((task-queue (concur-abstract-pool-task-queue pool))
              (was-removed
               (funcall (if (eq (type-of task-queue) 'concur-priority-queue)
                            #'concur:priority-queue-remove
                          #'concur:queue-remove)
                        task-queue task)))
         (unless was-removed
           (when-let* ((worker (concur-abstract-task-worker task))
                       (process (concur-abstract-worker-process worker)))
             (when (and (eq (concur-abstract-worker-current-task worker) task)
                        (process-live-p process))
               (concur--log :debug (concur-abstract-worker-id worker)
                            "Killing worker for task %s cancellation."
                            (concur-abstract-task-id task))
               (delete-process process)))))))))

(defun concur--abstract-pool-submit-session-task (task worker pool)
  "Submit a task to a specific, reserved worker for a session.

Arguments:
  TASK: The `concur-abstract-task` to submit.
  WORKER: The reserved `concur-abstract-worker`.
  POOL: The `concur-abstract-pool`.

Returns:
  nil."
  (let ((serialized-task
         (funcall (concur-abstract-pool-task-serializer-fn pool)
                  (concur-abstract-task-payload task)
                  (concur-abstract-task-context task))))
    (setf (concur-abstract-worker-status worker) :busy)
    (setf (concur-abstract-worker-current-task worker) task)
    (process-send-string (concur-abstract-worker-process worker)
                         (concat serialized-task "\n"))))

(cl-defun concur-abstract-pool-submit-task (pool payload
                                                 &key on-message
                                                      context
                                                      priority
                                                      cancel-token
                                                      worker)
  "Submit a `PAYLOAD` to the worker `POOL`.

Arguments:
  POOL: The `concur-abstract-pool` to submit the task to.
  PAYLOAD: The data, form, or command for the worker to process.
  :on-message (function): A `(lambda (payload))` callback for progress updates.
  :context (plist): Additional context data for the worker.
  :priority (integer): Scheduling priority (lower is higher).
  :cancel-token (concur-cancel-token): A token to request task cancellation.
  :worker (concur-abstract-worker): If provided, submits the task to this
    specific, reserved worker (for sessions).

Returns:
  (concur-promise): A promise that resolves with the task's result.

Signals:
  `concur-invalid-abstract-pool-error`: If POOL is not a valid pool object.
  `concur-abstract-pool-shutdown`: If the pool is shutting down."
  (concur--validate-abstract-pool pool 'concur-abstract-pool-submit-task)
  (let* ((promise (concur:make-promise :cancel-token cancel-token))
         (task (%%make-abstract-task
                :promise promise
                :id (format "task-%s" (make-temp-name ""))
                :payload payload
                :context context
                :on-message-fn on-message
                :priority (or priority 50)
                :cancel-token cancel-token
                :worker worker)))
    (when cancel-token
      (concur--abstract-pool-setup-task-cancellation task pool))

    (concur:with-mutex! (concur-abstract-pool-lock pool)
      (if (concur-abstract-pool-shutdown-p pool)
          (concur:reject promise
                         (concur:make-error
                          :type 'concur-abstract-pool-shutdown))
        (if worker
            (concur--abstract-pool-submit-session-task task worker pool)
          (let ((task-queue (concur-abstract-pool-task-queue pool)))
            (funcall (if (eq (type-of task-queue) 'concur-priority-queue)
                         #'concur:priority-queue-insert
                       #'concur:queue-enqueue)
                     task-queue task))
          (concur--abstract-pool-dispatch-next-task pool))))
    promise))

(cl-defmacro concur-abstract-pool-session ((session-var &key pool) &rest body)
  "Reserve a single worker from a `POOL` for a sequence of stateful commands.

Arguments:
  SESSION-VAR: A variable that will be bound to a function for submitting tasks
    to the reserved worker. The function has the signature
    `(lambda (payload &rest context-keys))`.
  :pool (concur-abstract-pool): The pool from which to reserve the worker.
  BODY: The forms to execute using the reserved worker. The result of the last
    form in BODY becomes the result of the session promise.

Returns:
  (concur-promise): A promise that resolves with the result of the final form.

Signals:
  `concur-invalid-abstract-pool-error`: If POOL is not a valid pool object.
  `concur-abstract-pool-shutdown`: If the pool is shutting down while waiting."
  (let ((pool-sym (gensym "pool-"))
        (worker-sym (gensym "worker-")))
    `(let ((,pool-sym ,pool))
       (concur--validate-abstract-pool ,pool-sym 'concur-abstract-pool-session)
       (concur:chain
           (concur:with-executor (resolve-worker reject-worker)
             (concur:with-mutex! (concur-abstract-pool-lock ,pool-sym)
               (if (concur-abstract-pool-shutdown-p ,pool-sym)
                   (funcall reject-worker
                            (concur:make-error
                             :type 'concur-abstract-pool-shutdown))
                 (concur:queue-enqueue
                  (concur-abstract-pool-waiter-queue ,pool-sym)
                  (cons resolve-worker reject-worker))
                 (concur--abstract-pool-dispatch-next-task ,pool-sym))))
           (lambda (,worker-sym)
             (let ((,session-var
                    (lambda (payload &rest context-keys)
                      (concur-abstract-pool-submit-task
                       ,pool-sym payload
                       :worker ,worker-sym :context context-keys))))
               (concur:unwind-protect!
                   (progn ,@body)
                 (lambda ()
                   (concur--abstract-pool-release-worker
                    ,worker-sym ,pool-sym)))))))))

(defun concur-abstract-pool-shutdown! (pool)
  "Gracefully shut down an abstract worker `POOL`.
Terminates all workers and rejects all pending/running tasks and sessions.

Arguments:
  POOL: The `concur-abstract-pool` to shut down.

Returns:
  nil.

Signals:
  `concur-invalid-abstract-pool-error`: If POOL is not a valid object."
  (interactive)
  (concur--validate-abstract-pool pool 'concur-abstract-pool-shutdown!)
  (concur--log :info nil "Shutting down abstract pool %S..."
               (concur-abstract-pool-name pool))

  (concur:with-mutex! (concur-abstract-pool-lock pool)
    (unless (concur-abstract-pool-shutdown-p pool)
      (setf (concur-abstract-pool-shutdown-p pool) t)

      (dolist (worker (concur-abstract-pool-workers pool))
        (when-let ((task (concur-abstract-worker-current-task worker)))
          (concur:reject (concur-abstract-task-promise task)
                         (concur:make-error
                          :type 'concur-abstract-pool-shutdown)))
        (when-let ((proc (concur-abstract-worker-process worker)))
          (when (process-live-p proc) (delete-process proc))))

      (let ((task-queue (concur-abstract-pool-task-queue pool)))
        (while-let ((task (concur:queue-dequeue task-queue)))
          (concur:reject (concur-abstract-task-promise task)
                         (concur:make-error
                          :type 'concur-abstract-pool-shutdown))))

      (while-let ((waiter (concur:queue-dequeue
                           (concur-abstract-pool-waiter-queue pool))))
        (funcall (cdr waiter)
                 (concur:make-error
                  :type 'concur-abstract-pool-shutdown)))

      (setf (concur-abstract-pool-workers pool) nil)))
  nil)

(defun concur-abstract-pool-status (pool)
  "Return a property list with a snapshot of the `POOL`'s current status.

Arguments:
  POOL: The `concur-abstract-pool` to inspect.

Returns:
  (plist): A property list containing detailed status information.

Signals:
  `concur-invalid-abstract-pool-error`: If POOL is not a valid object."
  (interactive)
  (concur--validate-abstract-pool pool 'concur-abstract-pool-status)
  (concur:with-mutex! (concur-abstract-pool-lock pool)
    (let* ((workers (concur-abstract-pool-workers pool))
           (task-queue (concur-abstract-pool-task-queue pool)))
      `(:name             ,(concur-abstract-pool-name pool)
        :size             ,(length workers)
        :idle-workers     ,(-count (lambda (w)
                                     (eq (concur-abstract-worker-status w)
                                         :idle))
                                   workers)
        :busy-workers     ,(-count (lambda (w)
                                     (eq (concur-abstract-worker-status w)
                                         :busy))
                                   workers)
        :reserved-workers ,(-count (lambda (w)
                                     (eq (concur-abstract-worker-status w)
                                         :reserved))
                                   workers)
        :failed-workers   ,(-count (lambda (w)
                                     (eq (concur-abstract-worker-status w)
                                         :failed))
                                   workers)
        :queued-tasks     ,(concur:queue-length task-queue)
        :waiting-sessions ,(concur:queue-length
                            (concur-abstract-pool-waiter-queue pool))
        :is-shutdown      ,(concur-abstract-pool-shutdown-p pool)))))

(provide 'concur-abstract-pool)
;;; concur-abstract-pool.el ends here