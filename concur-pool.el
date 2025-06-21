;;; concur-pool.el --- Persistent Worker Pool for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a persistent worker pool for executing asynchronous
;; tasks in background Emacs processes. It is a high-performance backend for
;; `(concur:async! ... :mode 'async)`.
;;
;; Instead of incurring the high cost of starting a new Emacs process for
;; every task, this module creates a fixed-size pool of worker processes that
;; persist for the duration of the Emacs session. Tasks are sent to idle
;; workers from a priority queue, dramatically improving throughput.
;;
;; Key Components:
;;
;; - The Pool Manager (`concur-pool` struct): A central object that manages
;;   the lifecycle of worker processes, tracks their status, and maintains a
;;   priority queue of pending tasks.
;;
;; - The Worker Process: A background Emacs process running a simple,
;;   persistent loop to evaluate tasks sent via JSON IPC.
;;
;; - Robustness Features: The pool includes task timeouts, graceful shutdown,
;;   and detection of "poison pill" tasks that repeatedly crash workers.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'async)
(require 'concur-core)
(require 'concur-lock)
(require 'concur-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization & Errors

(defcustom concur-pool-default-size 4
  "Default number of worker processes in the global pool."
  :type 'integer :group 'concur)

(defcustom concur-pool-max-worker-restart-attempts 3
  "Maximum consecutive restart attempts for a worker before it's marked failed."
  :type 'integer :group 'concur)

(defcustom concur-pool-max-queued-tasks 1000
  "Maximum number of tasks allowed in the pool's queue.
If exceeded, `concur-pool-submit-task` rejects new tasks (backpressure)."
  :type 'integer :group 'concur)

(define-error 'concur-pool-error "Error in the worker pool." 'concur-error)
(define-error 'concur-pool-shutdown-error "Pool was shut down." 'concur-pool-error)
(define-error 'concur-pool-task-error "Error executing task in worker."
  'concur-pool-error)
(define-error 'concur-pool-task-timeout-error "Task in worker timed out."
  'concur-pool-task-error)
(define-error 'concur-pool-poison-pill-error "Task repeatedly crashed workers."
  'concur-pool-task-error)
(define-error 'concur-pool-worker-restart-failed "Worker failed to restart."
  'concur-pool-error)
(define-error 'concur-pool-worker-terminated-mid-task
  "Worker terminated while busy." 'concur-pool-error)
(define-error 'concur-pool-queue-full-error
  "Pool queue is full, task rejected." 'concur-pool-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-pool-task (:constructor %%make-concur-pool-task))
  "Represents a task to be executed by the worker pool.

Fields:
- `promise` (concur-promise): The promise to settle with the task's result.
- `id` (string): A unique ID to correlate requests and responses.
- `form` (any): The Lisp form to be evaluated by the worker.
- `require` (list): A list of features for the worker to `require`.
- `priority` (integer): The task's priority (lower is higher).
- `timeout` (number or nil): Optional timeout in seconds for this task.
- `retries` (integer): Internal counter for poison pill detection."
  promise id form require
  (priority 50 :type integer)
  (timeout nil :type (or null number))
  (retries 0 :type integer))

(cl-defstruct (concur-worker (:constructor %%make-concur-worker))
  "Represents a single worker process in the pool.

Fields:
- `process` (process): The underlying Emacs process object.
- `id` (integer): A unique ID for this worker slot.
- `status` (keyword): Current status (`:idle`, `:busy`, `:dead`, etc.).
- `current-task` (concur-pool-task): The task it is currently executing.
- `timeout-timer` (timer or nil): Main Emacs-side timer for the task.
- `restart-attempts` (integer): Consecutive failed restart counter."
  process id
  (status :idle :type (member :idle :busy :dead :restarting :failed))
  current-task timeout-timer
  (restart-attempts 0 :type integer))

(cl-defstruct (concur-pool (:constructor %%make-concur-pool))
  "Represents a pool of persistent worker processes.

Fields:
- `lock` (concur-lock): A mutex protecting the pool's internal state.
- `workers` (list): A list of all `concur-worker` structs in the pool.
- `task-queue` (concur-priority-queue): Priority queue of pending tasks.
- `name` (string): A descriptive name for the pool.
- `init-fn` (function): A function run once in each new worker on startup.
- `shutdown-p` (boolean): `t` if the pool is shutting down."
  (lock (concur:make-lock "pool-lock" :mode :thread))
  workers
  (task-queue (concur-priority-queue-create
               :comparator (lambda (t1 t2)
                             (< (concur-pool-task-priority t1)
                                (concur-pool-task-priority t2)))))
  name init-fn
  (shutdown-p nil :type boolean))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Default Pool Management

(defvar concur--default-pool nil
  "The global, default instance of the worker pool.")
(defvar concur--default-pool-lock (concur:make-lock "default-pool-init-lock")
  "A mutex to protect the one-time initialization of the default pool.")

(defun concur-pool-get-default ()
  "Return the default global worker pool, creating it if necessary.
This function is thread-safe.

Returns:
  (concur-pool) The default pool instance."
  (or concur--default-pool
      (progn
        (concur:with-mutex! concur--default-pool-lock
          (unless concur--default-pool
            (setq concur--default-pool (concur-pool-create))))
        concur--default-pool)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker Process Logic

(defun concur--worker-script-form (init-fn)
  "Generate the Elisp code a background worker process will execute."
  `(lambda ()
     (require 'json)
     (let ((load-path ,load-path) (default-directory ,default-directory))
       (when ,init-fn (funcall ,init-fn))
       (while t
         (let* ((json-string (read-line))
                (task-data (json-read-from-string json-string))
                (task-id (cdr (assoc 'id task-data)))
                (form (cdr (assoc 'form task-data)))
                (features (cdr (assoc 'require task-data)))
                response)
           (dolist (feature features) (require feature nil t))
           (setq response
                 (condition-case err
                     (list :id task-id :result (eval form))
                   (error (list :id task-id
                                :error `(:type :task-exec-error
                                         :message ,(error-message-string err)
                                         :task-id ,task-id)))))
           (princ (json-serialize response))
           (princ "\n")
           (finish-output (standard-output)))))))

(defun concur--worker-filter (worker chunk)
  "The filter for worker processes, processing JSON responses from a worker."
  (let* ((pool (concur-pool-get-default))
         (response (json-read-from-string chunk))
         (task-id (cdr (assoc 'id response)))
         (task (concur-worker-current-task worker))
         (promise (and task (concur-pool-task-promise task))))

    (when-let (timer (concur-worker-timeout-timer worker))
      (cancel-timer timer)
      (setf (concur-worker-timeout-timer worker) nil))

    (if (and task (equal task-id (concur-pool-task-id task)))
        (progn
          (if-let ((worker-err (cdr (assoc 'error response))))
              (concur:reject
               promise
               (concur:make-error :type :pool-task-error
                                  :message (format "Worker %d task failed: %s"
                                                   (concur-worker-id worker)
                                                   (cdr (assoc 'message worker-err)))
                                  :cause worker-err))
            (concur:resolve promise (cdr (assoc 'result response))))
          (concur:with-mutex! (concur-pool-lock pool)
            (setf (concur-worker-status worker) :idle)
            (setf (concur-worker-current-task worker) nil)
            (setf (concur-worker-restart-attempts worker) 0)
            (concur--pool-dispatch-next-task pool)))
      (warn "Concur-pool: Received mismatched response ID: %s for worker %d."
            task-id (concur-worker-id worker)))))

(defun concur--handle-task-timeout (worker)
  "Handle a timed out task by killing the worker and rejecting the promise."
  (let ((task (concur-worker-current-task worker)))
    (warn "Concur-pool: Task '%s' in worker %d timed out. Killing worker."
          (concur-pool-task-id task) (concur-worker-id worker))
    (delete-process (concur-worker-process worker))
    (when-let (promise (and task (concur-pool-task-promise task)))
      (concur:reject
       promise
       (concur:make-error :type :pool-task-timeout-error
                          :message (format "Task exceeded timeout of %ss"
                                           (concur-pool-task-timeout task)))))))

(defun concur--worker-sentinel (worker event)
  "The sentinel for worker processes. Handles unexpected termination."
  (let* ((pool (concur-pool-get-default))
         (task (concur-worker-current-task worker)))
    (warn "Concur-pool: Worker %d died unexpectedly. Event: %s"
          (concur-worker-id worker) event)

    (when-let (timer (concur-worker-timeout-timer worker)) (cancel-timer timer))

    (when task
      (cl-incf (concur-pool-task-retries task))
      (if (> (concur-pool-task-retries task) concur-pool-max-worker-restart-attempts)
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type :pool-poison-pill-error))
        (concur:with-mutex! (concur-pool-lock pool)
          (concur-priority-queue-insert (concur-pool-task-queue pool) task))))

    (concur:with-mutex! (concur-pool-lock pool)
      (setf (concur-worker-current-task worker) nil)
      (setf (concur-worker-status worker) :dead)
      (unless (concur-pool-shutdown-p pool)
        (cl-incf (concur-worker-restart-attempts worker))
        (if (> (concur-worker-restart-attempts worker)
               concur-pool-max-worker-restart-attempts)
            (setf (concur-worker-status worker) :failed)
          (setf (concur-worker-status worker) :restarting)
          (setf (concur-worker-process worker)
                (concur--pool-start-worker worker pool))))
      (concur--pool-dispatch-next-task pool))))

(defun concur--pool-start-worker (worker pool)
  "Create and start a single background worker process."
  (condition-case err
      (let ((proc (async-start
                   (concur--worker-script-form (concur-pool-init-fn pool)))))
        (set-process-filter proc (lambda (_p c) (concur--worker-filter worker c)))
        (set-process-sentinel proc (lambda (_p e) (concur--worker-sentinel worker e)))
        proc)
    (error
     (warn "Concur-pool: Failed to start worker %d: %S" (concur-worker-id worker) err)
     (setf (concur-worker-status worker) :failed)
     nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Pool Management

;;;###autoload
(cl-defun concur-pool-create (&key (name "default-pool")
                                  (size concur-pool-default-size)
                                  (init-fn nil))
  "Create and initialize a new worker pool.

Arguments:
- `:name` (string): A descriptive name for the pool.
- `:size` (integer): The fixed number of workers in the pool.
- `:init-fn` (function): A nullary function to run once in each new
  worker process upon startup.

Returns:
  (concur-pool) A new, initialized pool object."
  (let ((pool (%%make-concur-pool :name name :init-fn init-fn)))
    (setf (concur-pool-workers pool)
          (cl-loop for i from 1 to size
                   collect (let ((worker (%%make-concur-worker :id i :status :idle)))
                             (setf (concur-worker-process worker)
                                   (concur--pool-start-worker worker pool))
                             worker)))
    pool))

(defun concur--pool-dispatch-next-task (pool)
  "Find an idle worker and dispatch the next task from the queue.
Must be called from within the pool's lock."
  (unless (or (concur-priority-queue-empty-p (concur-pool-task-queue pool))
              (concur-pool-shutdown-p pool))
    (when-let ((worker (-find-if (lambda (w) (eq (concur-worker-status w) :idle))
                                 (concur-pool-workers pool))))
      (let* ((task (concur-priority-queue-pop (concur-pool-task-queue pool)))
             (json (json-serialize `((id . ,(concur-pool-task-id task))
                                     (form . ,(concur-pool-task-form task))
                                     (require . ,(concur-pool-task-require task))))))
        (setf (concur-worker-status worker) :busy)
        (setf (concur-worker-current-task worker) task)
        (when-let (timeout (concur-pool-task-timeout task))
          (setf (concur-worker-timeout-timer worker)
                (run-at-time timeout nil #'concur--handle-task-timeout worker)))
        (process-send-string (concur-worker-process worker) (concat json "\n"))))))

;;;###autoload
(cl-defun concur:pool-submit-task (pool promise form require
                                       &key (priority 50) timeout)
  "Submit a task to the worker POOL.
Creates a task and enqueues it. Implements backpressure by rejecting
tasks if the queue is full.

Arguments:
- `POOL` (concur-pool): The pool to submit the task to.
- `PROMISE` (concur-promise): The promise to settle with the task's result.
- `FORM` (any): The Lisp form to be evaluated by the worker.
- `REQUIRE` (list): A list of features for the worker to `require`.
- `:PRIORITY` (integer, optional): Task priority (lower is higher).
- `:TIMEOUT` (number, optional): Optional timeout in seconds for this task.

Returns:
  nil."
  (let ((task (%%make-concur-pool-task
               :promise promise :id (format "task-%s" (random))
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
- `POOL` (concur-pool, optional): The pool to shut down. Defaults to the global pool.

Returns:
  nil."
  (let ((p (or pool (concur-pool-get-default))))
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
              (delete-process proc))))
        ;; Reject all tasks still remaining in the queue.
        (while-let ((task (concur-priority-queue-pop (concur-pool-task-queue p))))
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type :pool-shutdown-error)))
        (setf (concur-pool-workers p) nil)))))

;;;###autoload
(defun concur:pool-status (&optional pool)
  "Return a snapshot of the POOL's current status.

Arguments:
- `POOL` (concur-pool, optional): The pool to inspect. Defaults to the global pool.

Returns:
  (plist) A property list with pool metrics."
  (let* ((p (or pool (concur-pool-get-default))))
    (concur:with-mutex! (concur-pool-lock p)
      `(:name ,(concur-pool-name p)
        :size ,(length (concur-pool-workers p))
        :idle-workers ,(-count (lambda (w) (eq (concur-worker-status w) :idle))
                               (concur-pool-workers p))
        :busy-workers ,(-count (lambda (w) (eq (concur-worker-status w) :busy))
                               (concur-pool-workers p))
        :queued-tasks ,(concur-priority-queue-length
                        (concur-pool-task-queue p))
        :is-shutdown ,(concur-pool-shutdown-p p)))))

(provide 'concur-pool)
;;; concur-pool.el ends here