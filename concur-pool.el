;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-pool.el --- Persistent Worker Pool for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:

;; This library provides a persistent worker pool for executing asynchronous
;; tasks in background Emacs processes. It is a high-performance backend for
;; `(concur:async! ... :mode 'async)`, specifically for evaluating Emacs Lisp
;; forms in parallel worker processes.
;;
;; Instead of incurring the high cost of starting a new Emacs process for
;; every task, this module creates a fixed-size pool of worker processes that
;; persist for the duration of the Emacs session. Tasks are sent to idle
;; workers from a priority queue, dramatically improving throughput and
;; responsiveness for CPU-bound or blocking Lisp operations.
;;
;; Key Components:
;;
;; - The Pool Manager (`concur-pool` struct): A central object that manages
;;   the lifecycle of worker processes, tracks their status, and maintains a
;;   priority queue of pending tasks.
;;
;; - The Worker Process: A background Emacs process running a simple,
;;   persistent loop to evaluate Lisp forms sent via JSON IPC.
;;
;; - Robustness Features: The pool includes task timeouts, graceful shutdown,
;;   automatic worker restarts, and detection of "poison pill" tasks that
;;   repeatedly crash workers.

;;; Code:

(require 'cl-lib)             ; For cl-loop, cl-find-if, etc.
(require 'json)               ; For inter-process communication (IPC)
(require 'async)              ; For `async-start` and background processes
(require 'concur-core)        ; Core Concur promises and future management
(require 'concur-lock)        ; For mutexes to protect shared pool state
(require 'concur-priority-queue) ; For task prioritization

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customization & Errors

(defcustom concur-pool-default-size 4
  "Default number of worker processes in the global pool.
This determines the default maximum number of concurrent Lisp tasks."
  :type 'integer
  :group 'concur)

(defcustom concur-pool-max-worker-restart-attempts 3
  "Maximum consecutive restart attempts for a worker process.
If a worker crashes more than this many times in a row, it's marked
as failed and removed from the pool to prevent infinite restart loops."
  :type 'integer
  :group 'concur)

(defcustom concur-pool-max-queued-tasks 1000
  "Maximum number of tasks allowed in the pool's queue.
If exceeded, `concur:pool-submit-task` will reject new tasks (backpressure)
to prevent unbounded memory growth."
  :type 'integer
  :group 'concur)

;; Define custom error types for concur-pool, inheriting from `concur-error`.
(define-error 'concur-pool-error
  "A generic error occurred in the worker pool."
  'concur-error)
(define-error 'concur-pool-shutdown-error
  "The worker pool was shut down, and a task could not be processed."
  'concur-pool-error)
(define-error 'concur-pool-task-error
  "An error occurred while executing a task in a worker process."
  'concur-pool-error)
(define-error 'concur-pool-task-timeout-error
  "A task submitted to the worker pool timed out before completion."
  'concur-pool-task-error)
(define-error 'concur-pool-poison-pill-error
  "A task repeatedly crashed worker processes, indicating a problematic
  task that is being dropped."
  'concur-pool-task-error)
(define-error 'concur-pool-worker-restart-failed
  "A worker process failed to restart after multiple attempts."
  'concur-pool-error)
(define-error 'concur-pool-worker-terminated-mid-task
  "A worker process terminated while it was busy executing a task."
  'concur-pool-error)
(define-error 'concur-pool-queue-full-error
  "The worker pool's task queue is full, and a new task was rejected."
  'concur-pool-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures

(cl-defstruct (concur-pool-task (:constructor %%make-concur-pool-task))
  "Represents a task to be executed by the worker pool.

  Arguments:
  - `promise` (concur-promise): The `concur-promise` that will be settled
    with the task's result or rejected on failure.
  - `id` (string): A unique identifier (typically a `gensym` formatted string)
    to correlate requests and responses between the main Emacs process and
    the worker process.
  - `form` (any): The Emacs Lisp form to be evaluated by the worker process.
  - `require` (list): A list of feature symbols that the worker process
    should `require` before attempting to evaluate the `form`.
  - `priority` (integer): The task's priority (lower integer means higher
    priority). Tasks with higher priority are picked from the queue first.
    Defaults to 50.
  - `timeout` (number or nil): An optional timeout (in seconds) for this
    specific task. If the task exceeds this duration, it will be
    forcibly terminated and its promise rejected. Defaults to `nil`.
  - `retries` (integer): An internal counter used for poison pill detection.
    It tracks how many times this task has been re-enqueued due to a worker
    crash. Initialized to 0."
  (promise nil :type (satisfies concur-promise-p))
  (id nil :type string)
  (form nil)
  (require nil :type (or list null))
  (priority 50 :type integer)
  (timeout nil :type (or number null))
  (retries 0 :type integer))

(cl-defstruct (concur-worker (:constructor %%make-concur-worker))
  "Represents a single worker process in the pool.

  Arguments:
  - `process` (process): The underlying Emacs `async` process object that
    serves as the worker. Defaults to `nil` (initialized during worker start).
  - `id` (integer): A unique identifier for this worker slot within the pool
    (e.g., 1, 2, 3...).
  - `status` (keyword): The current status of the worker. Possible values:
    - `:idle`: The worker is ready and waiting for a new task.
    - `:busy`: The worker is currently executing a task.
    - `:dead`: The worker process has terminated unexpectedly.
    - `:restarting`: The worker process is being restarted after a crash.
    - `:failed`: The worker has exceeded `concur-pool-max-worker-restart-attempts`
      and will not be restarted.
  - `current-task` (concur-pool-task or nil): The `concur-pool-task` object
    that this worker is currently executing. `nil` if idle.
  - `timeout-timer` (timer or nil): The Emacs-side timer object used to enforce
    task-specific timeouts. `nil` if no timeout is active or if the task completed.
  - `restart-attempts` (integer): A counter for consecutive failed restart
    attempts. This is reset to 0 upon successful task completion. Initialized to 0."
  (process nil :type (or process null))
  (id nil :type integer)
  (status :idle :type (member :idle :busy :dead :restarting :failed))
  (current-task nil :type (or null (satisfies concur-pool-task-p)))
  (timeout-timer nil :type (or timer null))
  (restart-attempts 0 :type integer))

(cl-defstruct (concur-pool (:constructor %%make-concur-pool))
  "Represents a pool of persistent worker processes.

  Arguments:
  - `lock` (concur-lock): A `concur-lock` (mutex) protecting the pool's
    internal state. All operations modifying shared resources (like the
    `workers` list or `task-queue`) must acquire this lock to ensure
    thread-safety. Defaults to a new `:thread` mode `concur-lock`.
  - `workers` (list): A list of all `concur-worker` structs currently
    managed by this pool. Defaults to `nil`.
  - `task-queue` (concur-priority-queue): The priority queue (`concur-priority-queue`)
    holding `concur-pool-task` objects that are awaiting execution by an idle
    worker. Tasks are prioritized based on their `priority` field. Defaults
    to a new `concur-priority-queue` instance.
  - `name` (string): A descriptive name for the pool instance. Defaults to
    \"unnamed-pool\" or a unique `gensym` name if unspecified in constructor.
  - `init-fn` (function or nil): An optional nullary function that will be
    run once in each new worker process upon its startup. This is useful for
    setting up `load-path`s or requiring common libraries in the worker.
  - `shutdown-p` (boolean): `t` if the pool is in the process of shutting
    down (e.g., during Emacs exit). No new tasks will be accepted or
    dispatched. Defaults to `nil`."
  (lock nil :type (or null (satisfies concur-lock-p))) ; Initialized in pool-create
  (workers nil :type (or null (list (satisfies concur-worker-p))))
  (task-queue nil :type (or null (satisfies concur-priority-queue-p))) ; Initialized in pool-create
  (name "<unnamed-pool>" :type string)
  (init-fn nil :type (or function null))
  (shutdown-p nil :type boolean))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Global Default Pool Management

(defvar concur--default-pool nil
  "The global, default instance of the worker pool.
This pool is created lazily the first time `concur-pool-get-default`
is called.")

(defvar concur--default-pool-init-lock
  (concur:make-lock "default-pool-init-lock")
  "A mutex to protect the one-time initialization of the default pool.
Ensures `concur--default-pool` is a singleton.")

(defun concur-pool-get-default ()
  "Return the default global worker pool, creating it if necessary.
This function is thread-safe and ensures the default pool is a singleton.
If the pool has not been created yet, it will be initialized
with `concur-pool-default-size` workers.

  Returns:
  - (concur-pool): The default pool instance."
  (or concur--default-pool
      (concur:with-mutex! concur--default-pool-init-lock
        (unless concur--default-pool ; Double-check inside lock
          (setq concur--default-pool (concur-pool-create
                                      :name "global-default-pool"))
          ;; Add hook to gracefully shut down pool when Emacs exits
          (add-hook 'kill-emacs-hook #'concur-pool-shutdown-default-pool))
        concur--default-pool)))

(defun concur-pool-shutdown-default-pool ()
  "Shut down the default worker pool gracefully when Emacs exits.
This function is automatically added to `kill-emacs-hook` when the
default pool is first accessed. It ensures all worker processes are
terminated and pending tasks are cleaned up."
  (interactive)
  (when concur--default-pool
    (message "Concur-pool: Shutting down default pool...")
    (concur:with-mutex! (concur-pool-lock concur--default-pool)
      (unless (concur-pool-shutdown-p concur--default-pool)
        (setf (concur-pool-shutdown-p concur--default-pool) t)
        ;; Kill all worker processes.
        (dolist (worker (concur-pool-workers concur--default-pool))
          (when-let (proc (concur-worker-process worker))
            (when (process-live-p proc)
              ;; Explicitly reject the task of a busy worker.
              (when-let (task (concur-worker-current-task worker))
                (concur:reject (concur-pool-task-promise task)
                               (concur:make-error
                                :type 'concur-pool-worker-terminated-mid-task)))
              (delete-process proc)
              (message "Concur-pool: Killed worker %d."
                       (concur-worker-id worker)))))
        ;; Reject all tasks still remaining in the queue.
        (while-let ((task (concur-priority-queue-pop
                           (concur-pool-task-queue concur--default-pool))))
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type :pool-shutdown-error)))
        ;; Clear the workers list
        (setf (concur-pool-workers concur--default-pool) nil)
        (message "Concur-pool: Default pool shut down."))))
  (setq concur--default-pool nil)) ; Clear the global variable

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Worker Process Logic

(defun concur--worker-script-form (init-fn)
  "Generate the Emacs Lisp code a background worker process will execute.
This script is sent to the `async` process and forms its main loop.
It receives JSON-serialized tasks, evaluates them, and sends back
JSON-serialized results or errors.

  Arguments:
  - `init-fn` (function or nil): An optional function to run once
    in the worker process at startup.

  Returns:
  - (lambda): An Emacs Lisp lambda form suitable for `async-start`."
  `(lambda ()
     ;; Ensure `json` and `cl-lib` are available in the worker process
     (require 'json)
     (require 'cl-lib) ; Ensure cl-lib is available in worker for general use
     (let ((load-path ,load-path) ; Inherit load-path from main Emacs
           (default-directory ,default-directory))
       (when ,init-fn (funcall ,init-fn)) ; Run worker-specific init function
       ;; Main worker loop: read task, evaluate, send response
       (while t
         (let* ((json-string (read-line)) ; Read task JSON from main process
                (task-data (json-read-from-string json-string))
                (task-id (cdr (assoc 'id task-data)))
                (form (cdr (assoc 'form task-data)))
                (features (cdr (assoc 'require task-data)))
                response)
           ;; Require necessary features for the task
           (dolist (feature features) (require feature nil t))
           (setq response
                 (condition-case err
                     ;; Evaluate the Lisp form safely
                     (list :id task-id :result (eval form))
                   (error (list :id task-id
                                :error `(:type :task-exec-error
                                         :message ,(error-message-string err)
                                         :task-id ,task-id)))))
           ;; Send JSON response back to main process
           (princ (json-serialize response))
           (princ "\n")
           (finish-output (standard-output)))))))

(defun concur--worker-filter (worker chunk)
  "The filter for worker processes, processing JSON responses from a worker.
This function is called when a chunk of output is received from a worker.

  Arguments:
  - `worker` (concur-worker): The worker process sending data.
  - `chunk` (string): The raw output chunk received from the worker,
    expected to be a JSON string.

  Returns:
  - `nil` (side-effect: processes response and updates worker/task state)."
  (let* ((pool (concur-pool-get-default))
         (response (json-read-from-string chunk))
         (task-id (cdr (assoc 'id response)))
         (task (concur-worker-current-task worker))
         (promise (and task (concur-pool-task-promise task))))

    ;; Cancel timeout timer once response is received
    (when-let (timer (concur-worker-timeout-timer worker))
      (cancel-timer timer)
      (setf (concur-worker-timeout-timer worker) nil))

    ;; Verify that the response corresponds to the currently active task
    (if (and task (equal task-id (concur-pool-task-id task)))
        (progn
          (if-let ((worker-err (cdr (assoc 'error response))))
              ;; Task execution failed in the worker
              (concur:reject
               promise
               (concur:make-error :type :pool-task-error
                                  :message (format "Worker %d task failed: %s"
                                                   (concur-worker-id worker)
                                                   (cdr (assoc 'message worker-err)))
                                  :cause worker-err))
            ;; Task executed successfully
            (concur:resolve promise (cdr (assoc 'result response))))
          ;; Reset worker state and dispatch next task within lock
          (concur:with-mutex! (concur-pool-lock pool)
            (setf (concur-worker-status worker) :idle)
            (setf (concur-worker-current-task worker) nil)
            (setf (concur-worker-restart-attempts worker) 0) ; Success resets counter
            (concur--pool-dispatch-next-task pool)))
      ;; Mismatched ID indicates a serious issue or orphaned response
      (warn "Concur-pool: Received mismatched response ID: %s for worker %d. \
             Expected task ID: %S. Response: %S"
            task-id (concur-worker-id worker)
            (and task (concur-pool-task-id task))
            response))))

(defun concur--handle-task-timeout (worker)
  "Handle a timed out task by killing the worker and rejecting the promise.
This function is called by the task's timeout timer.

  Arguments:
  - `worker` (concur-worker): The worker whose current task timed out.

  Returns:
  - `nil` (side-effect: kills worker process, rejects task promise)."
  (let ((task (concur-worker-current-task worker)))
    (warn "Concur-pool: Task '%s' in worker %d timed out. Killing worker."
          (concur-pool-task-id task) (concur-worker-id worker))
    ;; Kill the worker process; its sentinel will handle restart
    (when-let (proc (concur-worker-process worker))
      (when (process-live-p proc)
        (delete-process proc)))
    ;; Reject the task's promise if it's still pending
    (when-let (promise (and task (concur-pool-task-promise task)))
      (when (concur:pending-p promise)
        (concur:reject
         promise
         (concur:make-error :type :pool-task-timeout-error
                            :message (format "Task exceeded timeout of %ss"
                                             (concur-pool-task-timeout task))))))))

(defun concur--worker-sentinel (worker event)
  "The sentinel for worker processes. Handles unexpected termination
  and initiates restarts.

  Arguments:
  - `worker` (concur-worker): The worker that triggered the sentinel.
  - `event` (string): The event string from Emacs (e.g., \"exited abnormally\").

  Returns:
  - `nil` (side-effect: manages worker state and pool dispatch)."
  (message "Concur-pool: Worker %d died unexpectedly. Event: %s"
           (concur-worker-id worker) event)
  (let* ((pool (concur-pool-get-default))
         (task (concur-worker-current-task worker)))
    ;; Cancel any active timeout timer for the worker
    (when-let (timer (concur-worker-timeout-timer worker))
      (cancel-timer timer)
      (setf (concur-worker-timeout-timer worker) nil))

    ;; Handle the task that was running when the worker died
    (when task
      (cl-incf (concur-pool-task-retries task))
      (if (> (concur-pool-task-retries task)
             concur-pool-max-worker-restart-attempts)
          ;; Task is a poison pill, reject its promise
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type :pool-poison-pill-error
                                            :message (format "Task %s repeatedly \
                                                              crashed workers."
                                                              (concur-pool-task-id task))))
        ;; Re-enqueue task for retry
        (concur:with-mutex! (concur-pool-lock pool)
          (concur-priority-queue-insert (concur-pool-task-queue pool) task))))

    ;; Update worker status and try to restart or mark as failed
    (concur:with-mutex! (concur-pool-lock pool)
      (setf (concur-worker-current-task worker) nil) ; Clear active task
      (setf (concur-worker-status worker) :dead)

      (unless (concur-pool-shutdown-p pool)
        (cl-incf (concur-worker-restart-attempts worker))
        (if (> (concur-worker-restart-attempts worker)
               concur-pool-max-worker-restart-attempts)
            (progn
              (setf (concur-worker-status worker) :failed)
              (message "Concur-pool: Worker %d permanently failed after %d \
                        restarts."
                       (concur-worker-id worker)
                       concur-pool-max-worker-restart-attempts))
          (setf (concur-worker-status worker) :restarting)
          (message "Concur-pool: Restarting worker %d (Attempt %d)."
                   (concur-worker-id worker)
                   (concur-worker-restart-attempts worker))
          (setf (concur-worker-process worker)
                (concur--pool-start-worker worker pool))))
      ;; Attempt to dispatch the next task if any are waiting
      (concur--pool-dispatch-next-task pool))))

(defun concur--pool-start-worker (worker pool-instance)
  "Create and start a single background worker process.

  Arguments:
  - `worker` (concur-worker): The worker struct to initialize.
  - `pool-instance` (concur-pool): The pool this worker belongs to.

  Returns:
  - (process or nil): The new Emacs process object, or nil if creation fails."
  (message "Concur-pool: Starting worker %d..."
           (concur-worker-id worker))
  (condition-case err
      (let ((proc (async-start
                   (concur--worker-script-form (concur-pool-init-fn pool-instance)))))
        (set-process-filter proc (lambda (_p c) (concur--worker-filter worker c)))
        (set-process-sentinel proc (lambda (_p e) (concur--worker-sentinel worker e)))
        (setf (concur-worker-status worker) :idle) ; Worker is ready
        (setf (concur-worker-restart-attempts worker) 0) ; Reset on successful start
        proc)
    (error
     (message "Concur-pool: Failed to start worker %d: %S"
              (concur-worker-id worker) err)
     (setf (concur-worker-status worker) :failed)
     nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Pool and Dispatch Management

(defun concur--pool-dispatch-next-task (pool-instance)
  "Find an idle worker and dispatch the next task from the queue.
This function MUST be called from within the pool's lock (`concur-pool-lock`).

  Arguments:
  - `pool-instance` (concur-pool): The pool to manage tasks for.

  Returns:
  - `nil` (side-effect: dispatches tasks)."
  (unless (or (concur-priority-queue-empty-p
               (concur-pool-task-queue pool-instance))
              (concur-pool-shutdown-p pool-instance))
    (when-let ((worker (cl-find-if
                        (lambda (w) (eq (concur-worker-status w) :idle))
                        (concur-pool-workers pool-instance))))
      (let* ((task (concur-priority-queue-pop
                    (concur-pool-task-queue pool-instance)))
             (json (json-serialize `((id . ,(concur-pool-task-id task))
                                     (form . ,(concur-pool-task-form task))
                                     (require . ,(concur-pool-task-require task))))))
        (setf (concur-worker-status worker) :busy)
        (setf (concur-worker-current-task worker) task)
        ;; Schedule timeout timer for the task
        (when-let (timeout (concur-pool-task-timeout task))
          (setf (concur-worker-timeout-timer worker)
                (run-at-time timeout nil #'concur--handle-task-timeout worker)))
        (process-send-string (concur-worker-process worker)
                             (concat json "\n"))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Pool Management

;;;###autoload
(cl-defun concur-pool-create (&key (name (format "pool-%S" (gensym)))
                                  (size concur-pool-default-size)
                                  (init-fn nil))
  "Create and initialize a new worker pool.

  Arguments:
  - `:name` (string): A descriptive name for the pool. Defaults to a
    unique `gensym`-based name.
  - `:size` (integer): The fixed number of workers in the pool. Defaults
    to `concur-pool-default-size`.
  - `:init-fn` (function or nil): A nullary function to run once in each new
    worker process upon its startup. This is useful for setting up
    `load-path`s or requiring common libraries in the worker.

  Returns:
  - (concur-pool): A new, initialized pool object."
  (message "Concur-pool: Creating new pool %S with %d workers."
           name size)
  (let ((pool (%%make-concur-pool
               :name name
               :lock (concur:make-lock (format "pool-lock-%s" name))
               :task-queue (concur-priority-queue-create)
               :init-fn init-fn)))
    (setf (concur-pool-workers pool)
          (cl-loop for i from 1 to size
                   collect (let ((worker (%%make-concur-worker :id i)))
                             (setf (concur-worker-process worker)
                                   (concur--pool-start-worker worker pool))
                             worker)))
    pool))

;;;###autoload
(cl-defun concur:pool-submit-task (pool promise form require
                                       &key (priority 50) timeout)
  "Submit a task to the worker POOL.
Creates a task and enqueues it into the pool's priority queue.
Implements backpressure by rejecting tasks if the queue is full.

  Arguments:
  - `POOL` (concur-pool): The pool to submit the task to.
  - `PROMISE` (concur-promise): The promise to settle with the task's result.
  - `FORM` (any): The Emacs Lisp form to be evaluated by the worker.
  - `REQUIRE` (list): A list of feature symbols for the worker to `require`
    before evaluating the form.
  - `:PRIORITY` (integer, optional): Task priority (lower integer means higher
    priority). Defaults to 50.
  - `:TIMEOUT` (number, optional): Optional timeout in seconds for this task.
    If the task exceeds this duration, it will be terminated.

  Returns:
  - `nil` (side-effect: enqueues task or rejects promise)."
  (let ((task (%%make-concur-pool-task
               :promise promise
               :id (format "task-%s" (gensym "task"))
               :form form :require require
               :priority priority :timeout timeout)))
    (concur:with-mutex! (concur-pool-lock pool)
      (cond
       ((concur-pool-shutdown-p pool)
        (concur:reject promise (concur:make-error :type :pool-shutdown-error)))
       ((>= (concur-priority-queue-length (concur-pool-task-queue pool))
            concur-pool-max-queued-tasks)
        (concur:reject promise (concur:make-error :type :pool-queue-full-error)))
       (t
        (concur-priority-queue-insert (concur-pool-task-queue pool) task)
        (concur--pool-dispatch-next-task pool))))))

;;;###autoload
(defun concur:pool-shutdown! (&optional pool)
  "Gracefully shut down a worker POOL.
Terminates all worker processes and rejects any pending tasks.

  Arguments:
  - `POOL` (concur-pool, optional): The pool to shut down.
    Defaults to the global default worker pool.

  Returns:
  - `nil`."
  (interactive)
  (let ((p (or pool concur--default-pool)))
    (unless p
      (user-error "Concur-pool: No pool is active to shut down."))
    (message "Concur-pool: Shutting down pool %S..."
             (concur-pool-name p))
    (concur:with-mutex! (concur-pool-lock p)
      (unless (concur-pool-shutdown-p p)
        (setf (concur-pool-shutdown-p p) t)
        ;; Kill all worker processes.
        (dolist (worker (concur-pool-workers p))
          (when-let (proc (concur-worker-process worker))
            (when (process-live-p proc)
              ;; Explicitly reject the task of a busy worker.
              (when-let (task (concur-worker-current-task worker))
                (concur:reject (concur-pool-task-promise task)
                               (concur:make-error
                                :type 'concur-pool-worker-terminated-mid-task)))
              (delete-process proc)
              (message "Concur-pool: Killed worker %d."
                       (concur-worker-id worker)))))
        ;; Reject all tasks still remaining in the queue.
        (while-let ((task (concur-priority-queue-pop
                           (concur-pool-task-queue p))))
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type :pool-shutdown-error)))
        ;; Clear the workers list
        (setf (concur-pool-workers p) nil)
        (message "Concur-pool: Pool %S shut down."
                 (concur-pool-name p))))
    (when (eq p concur--default-pool)
      (setq concur--default-pool nil)))) ; Clear global variable

;;;###autoload
(defun concur:pool-status (&optional pool)
  "Return a snapshot of the POOL's current status.

  Arguments:
  - `POOL` (concur-pool, optional): The pool to inspect.
    Defaults to the global default worker pool.

  Returns:
  - (plist): A property list with pool metrics:
    `:name`: Name of the pool.
    `:size`: Total number of worker slots.
    `:idle-workers`: Number of workers currently idle.
    `:busy-workers`: Number of workers currently busy.
    `:restarting-workers`: Number of workers currently restarting.
    `:failed-workers`: List of IDs of workers marked as permanently failed.
    `:queued-tasks`: Number of tasks awaiting execution in the queue.
    `:is-shutdown`: Whether the pool is in shutdown state."
  (interactive)
  (let* ((p (or pool concur--default-pool)))
    (unless p
      (user-error "Concur-pool: No pool is active to inspect."))
    (concur:with-mutex! (concur-pool-lock p)
      `(:name ,(concur-pool-name p)
        :size ,(length (concur-pool-workers p))
        :idle-workers ,(cl-loop for w in (concur-pool-workers p)
                                when (eq (concur-worker-status w) :idle)
                                count t)
        :busy-workers ,(cl-loop for w in (concur-pool-workers p)
                                when (eq (concur-worker-status w) :busy)
                                count t)
        :restarting-workers ,(cl-loop for w in (concur-pool-workers p)
                                      when (eq (concur-worker-status w) :restarting)
                                      count t)
        :failed-workers ,(cl-loop for w in (concur-pool-workers p)
                                  when (eq (concur-worker-status w) :failed)
                                  collect (concur-worker-id w))
        :queued-tasks ,(concur-priority-queue-length
                        (concur-pool-task-queue p))
        :is-shutdown ,(concur-pool-shutdown-p p)))))

(provide 'concur-pool)
;;; concur-pool.el ends here