;;; concur-pool.el --- Persistent Worker Pool for Emacs Lisp -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a high-performance, persistent worker pool for executing
;; asynchronous tasks in background Emacs processes. It is the primary backend
;; for CPU-bound or blocking Emacs Lisp operations.
;;
;; Key Features:
;; - Robust Workers: Uses `concur-async.el` primitives to reliably start workers.
;; - Stateful Sessions: The `concur:pool-session` macro allows for reserving a
;;   single worker for a sequence of stateful commands.
;; - Two-Way Message Passing: Tasks can send progress updates back to the parent
;;   process via an `:on-message` callback.
;; - Cancellation: Tasks can be cancelled via `concur-cancel-token`, which will
;;   either remove them from the queue or terminate the running worker.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-priority-queue)
(require 'concur-log)
(require 'concur-async)
(require 'concur-nursery)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-pool-error "Generic error in the worker pool." 'concur-error)
(define-error 'concur-invalid-pool-error "Invalid pool object." 'concur-pool-error)
(define-error 'concur-pool-shutdown "Pool was shut down during task execution." 'concur-pool-error)
(define-error 'concur-pool-task-error "An error occurred during task execution." 'concur-pool-error)
(define-error 'concur-pool-poison-pill "A task repeatedly crashed workers." 'concur-pool-error)

(defcustom concur-pool-default-size 4
  "The number of worker processes in the default pool."
  :type 'integer :group 'concur)

(defcustom concur-pool-max-worker-restarts 3
  "Maximum consecutive restart attempts for a failed worker."
  :type 'integer :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-pool-task (:constructor %%make-pool-task))
  "Represents a task for the worker pool."
  promise id form vars on-message-fn (priority 50)
  (retries 0) worker cancel-token)

(cl-defstruct (concur-worker (:constructor %%make-worker))
  "Represents a single worker process in the pool."
  process id status current-task (restart-attempts 0))

(cl-defstruct (concur-pool (:constructor %%make-pool))
  "Represents a pool of persistent worker processes."
  name workers lock task-queue waiter-queue worker-env (shutdown-p nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Default Pool Management

(defvar concur--default-pool nil
  "The global, default instance of the worker pool.")
(defvar concur--default-pool-init-lock (concur:make-lock "default-pool-init-lock")
  "A lock to protect the one-time initialization of the default pool.")

(defun concur--pool-get-default ()
  "Return the default global worker pool, creating it if it doesn't exist."
  (unless concur--default-pool
    (concur:with-mutex! concur--default-pool-init-lock
      (unless concur--default-pool
        (setq concur--default-pool (concur-pool-create))
        (add-hook 'kill-emacs-hook #'concur--pool-shutdown-default-pool))))
  concur--default-pool)

(defun concur--pool-shutdown-default-pool ()
  "Hook function to shut down the default pool when Emacs exits."
  (when concur--default-pool
    (concur:pool-shutdown! concur--default-pool)))

(defun concur--validate-pool (pool function-name)
  "Signal an error if POOL is not a `concur-pool`."
  (unless (concur-pool-p pool)
    (signal 'concur-invalid-pool-error
            (list (format "%s: Invalid pool object" function-name) pool))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker Logic & IPC

;; This function is intended to be run inside the worker process.
(defun concur:pool-send-message (payload)
  "Send a progress message `PAYLOAD` from a worker to the parent process.
This function is only available within code executed by a `concur:pool-eval`.

Arguments:
- `PAYLOAD` (any): The Lisp object to send as a message."
  (princ (format "M:%S\n" (prin1-to-string payload)))
  (finish-output))

(defun concur--pool-worker-entry-point ()
  "The main entry point for a background worker process.
This function runs in a loop, reading tasks, executing them,
and sending back results, errors, or messages."
  (require 'cl-extra)
  ;; Main loop: read a task S-exp, evaluate it, send response.
  (while t
    (let* ((task-sexp (read))
           (id (plist-get task-sexp :id))
           (form (plist-get task-sexp :form))
           (vars (plist-get task-sexp :vars)))
      (condition-case err
          ;; The `let` binding makes user-provided variables available.
          (let ((result (eval `(let ,vars ,form) t)))
            (princ (format "R:%S\n" (prin1-to-string (list :id id :result result)))))
        (error
         (princ (format "E:%S\n"
                        (prin1-to-string
                         (list :id id
                               :error (cl-serialize-error err)))))))
      (finish-output))))

(defun concur--pool-handle-worker-output (worker task output)
  "Handle a single parsed `OUTPUT` object from a `WORKER` for a `TASK`.

Arguments:
- `WORKER` (concur-worker): The worker that produced the output.
- `TASK` (concur-pool-task): The task associated with the output.
- `OUTPUT` (plist): The parsed S-expression from the worker."
  (pcase (plist-get output :type)
    ;; Result (R)
    (:result
     (concur:resolve (concur-pool-task-promise task)
                     (plist-get output :payload))
     (concur--pool-release-worker worker))
    ;; Error (E)
    (:error
     (concur:reject (concur-pool-task-promise task)
                    (concur:make-error
                     :type 'concur-pool-task-error
                     :message "Task failed in worker."
                     :cause (cl-deserialize-error
                             (plist-get output :payload))))
     (concur--pool-release-worker worker))
    ;; Message (M)
    (:message
     (when-let (cb (concur-pool-task-on-message-fn task))
       (funcall cb (plist-get output :payload))))
    ;; Unknown
    (_
     (concur--log :warn "Mismatched response for worker %d: %S"
                  (concur-worker-id worker) output))))

(defun concur--pool-start-worker (worker pool)
  "Create and start a single background worker process.
This now uses `concur:async-stream` to get a reliable, streaming
connection to the worker's stdout.

Arguments:
- `WORKER` (concur-worker): The worker struct to initialize.
- `POOL` (concur-pool): The parent pool."
  (let* ((worker-env (concur-pool-worker-env pool))
         (stream (concur:async-stream
                  `(progn
                     ;; The worker needs its own code to run.
                     (require 'concur-pool)
                     (concur--pool-worker-entry-point))
                  :load-path (plist-get worker-env :load-path)
                  :require (append (plist-get worker-env :require)
                                   '(cl-extra)))))
    ;; The stream's associated process is the worker process.
    (setf (concur-worker-process worker) (process-get stream 'process))
    ;; Process messages from the worker's stdout stream.
    (concur:stream-for-each
     stream
     (lambda (response)
       (let* ((task (concur-worker-current-task worker))
              (task-id (and task (concur-pool-task-id task))))
         (when (and task (equal task-id (plist-get response :id)))
           (concur--pool-handle-worker-output worker task response)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Lifecycle & Dispatch

(defun concur--worker-sentinel (worker event pool)
  "Sentinel for worker processes. Handles unexpected termination and restart."
  (concur--log :warn nil "Pool worker %d died. Event: %s"
               (concur-worker-id worker) event)
  (let ((task (concur-worker-current-task worker)))
    ;; If the worker was busy, handle the task.
    (when task
      (cl-incf (concur-pool-task-retries task))
      (if (> (concur-pool-task-retries task) concur-pool-max-worker-restarts)
          ;; This task is a "poison pill".
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type 'concur-pool-poison-pill))
        ;; Re-queue the task to be tried on another worker.
        (concur:with-mutex! (concur-pool-lock pool)
          (concur-priority-queue-insert (concur-pool-task-queue pool) task))))
    ;; Attempt to restart the worker.
    (concur:with-mutex! (concur-pool-lock pool)
      (setf (concur-worker-status worker) :dead)
      (unless (concur-pool-shutdown-p pool)
        (cl-incf (concur-worker-restart-attempts worker))
        (if (> (concur-worker-restart-attempts worker) concur-pool-max-worker-restarts)
            (progn (setf (concur-worker-status worker) :failed)
                   (concur--log :error nil "Worker %d failed permanently."
                                (concur-worker-id worker)))
          (setf (concur-worker-status worker) :restarting)
          (concur--pool-start-worker worker pool)))
      (concur--pool-dispatch-next-task pool))))

(defun concur--pool-release-worker (worker)
  "Release a worker back to the pool, making it available for new tasks."
  (let ((pool (concur--pool-get-default)))
    (concur:with-mutex! (concur-pool-lock pool)
      (setf (concur-worker-status worker) :idle)
      (setf (concur-worker-current-task worker) nil)
      (concur--pool-dispatch-next-task pool))))

(defun concur--pool-dispatch-next-task (pool)
  "Find an idle worker and dispatch the next task or waiting session.
This function MUST be called from within the pool's lock."
  (unless (concur-pool-shutdown-p pool)
    ;; Prioritize sessions waiting for a worker.
    (if-let ((waiter (pop (concur-pool-waiter-queue pool))))
        (if-let ((worker (cl-find-if (lambda (w) (eq (concur-worker-status w) :idle))
                                    (concur-pool-workers pool))))
            (progn (setf (concur-worker-status worker) :reserved)
                   (funcall (car waiter) worker)) ; Resolve waiter's promise.
          (push waiter (concur-pool-waiter-queue pool))) ; Re-queue if no worker.
      ;; If no waiting sessions, check the general task queue.
      (unless (concur-priority-queue-empty-p (concur-pool-task-queue pool))
        (when-let ((worker (cl-find-if (lambda (w) (eq (concur-worker-status w) :idle))
                                      (concur-pool-workers pool))))
          (let* ((task (concur-priority-queue-pop (concur-pool-task-queue pool)))
                 (payload `(:id ,(concur-pool-task-id task)
                                :form ,(concur-pool-task-form task)
                                :vars ,(concur-pool-task-vars task))))
            (setf (concur-worker-status worker) :busy)
            (setf (concur-worker-current-task worker) task)
            (setf (concur-pool-task-worker task) worker)
            (process-send-string (concur-worker-process worker)
                                 (prin1-to-string payload))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur-pool-create (&key (name (format "pool-%S" (gensym)))
                                  (size concur-pool-default-size)
                                  init-fn load-path require)
  "Create and initialize a new worker pool.

Arguments:
- `:NAME` (string): A descriptive name for the pool.
- `:SIZE` (integer): The fixed number of workers in the pool.
- `:INIT-FN` (function): A nullary function to run once in each new
  worker at startup.
- `:LOAD-PATH` (list): A list of directory strings to prepend to the
  worker's `load-path`.
- `:REQUIRE` (list): A list of feature symbols to `require` in each
  worker at startup.

Returns:
- `(concur-pool)`: A new, initialized pool object."
  (let* ((worker-env `(:init-fn ,init-fn :load-path ,load-path :require ,require))
         (pool (%%make-pool
                :name name
                :lock (concur:make-lock (format "pool-lock-%s" name))
                :task-queue (concur-priority-queue-create
                             :comparator (lambda (a b)
                                           (< (concur-pool-task-priority a)
                                              (concur-pool-task-priority b))))
                :worker-env worker-env)))
    (setf (concur-pool-workers pool)
          (cl-loop for i from 1 to size
                   collect (let ((worker (%%make-worker :id i)))
                             (concur--pool-start-worker worker pool)
                             worker)))
    pool))

;;;###autoload
(cl-defun concur:pool-submit-task (pool form &key on-message vars
                                                 priority cancel-token)
  "Submit a task to the worker `POOL`. (Low-level)

Arguments:
- `POOL` (concur-pool): The pool to submit the task to.
- `FORM` (any): The Emacs Lisp form to be evaluated by the worker.
- `:ON-MESSAGE` (function): Callback for progress messages from the worker.
- `:VARS` (alist): `let`-bindings for the worker's execution context.
- `:PRIORITY` (integer): Task priority (lower is higher).
- `:CANCEL-TOKEN` (concur-cancel-token): A token to cancel the task.

Returns:
- (concur-promise): A new promise for the task's result."
  (concur--validate-pool pool 'concur:pool-submit-task)
  (let* ((promise (concur:make-promise :cancel-token cancel-token))
         (task (%%make-pool-task
                :promise promise :id (format "task-%s" (make-temp-name ""))
                :form form :on-message-fn on-message :vars vars
                :priority (or priority 50) :cancel-token cancel-token)))
    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (concur:with-mutex! (concur-pool-lock pool)
           ;; Try to remove from queue first.
           (unless (concur-priority-queue-remove (concur-pool-task-queue pool) task)
             ;; If not in queue, it must be running. Kill its worker.
             (when-let ((worker (concur-pool-task-worker task)))
               (when (eq (concur-worker-current-task worker) task)
                 (delete-process (concur-worker-process worker)))))))))
    (concur:with-mutex! (concur-pool-lock pool)
      (concur-priority-queue-insert (concur-pool-task-queue pool) task)
      (concur--pool-dispatch-next-task pool))
    promise))

;;;###autoload
(cl-defmacro concur:pool-eval (form &rest keys)
  "Evaluate `FORM` in the default worker pool, returning a promise.
This is the primary high-level entry point for running Elisp code in
the background.

Arguments:
- `FORM` (form): The Lisp form to execute in a background worker.
- `KEYS` (plist): A property list of options passed to
  `concur:pool-submit-task`, e.g., `:on-message`, `:vars`,
  `:priority`, `:cancel-token`.

Returns:
- (concur-promise): A promise that resolves with the result of `FORM`."
  `(apply #'concur:pool-submit-task
          (concur--pool-get-default) ',form ',keys))

;;;###autoload
(cl-defmacro concur:pool-session ((session-var &key pool) &rest body)
  "Reserve a single worker for a sequence of stateful commands.
`SESSION-VAR` is bound to a runner function that sends tasks to the
dedicated worker. The runner has the signature:
  `(lambda (form &key on-message vars priority))`

Arguments:
- `SESSION-VAR` (symbol): A variable to bind to the session's runner function.
- `:POOL` (concur-pool, optional): The pool to use.
- `BODY` (forms): The code to execute within the session.

Returns:
- (concur-promise): A promise for the result of the last form in `BODY`."
  (let ((pool-sym (gensym "pool-")) (worker-sym (gensym "worker-")))
    `(let ((,pool-sym (or ,pool (concur--pool-get-default))))
       (concur--validate-pool ,pool-sym 'concur:pool-session)
       (concur:chain
           (concur:with-executor (resolve _reject)
             (concur:with-mutex! (concur-pool-lock ,pool-sym)
               (if-let ((worker (cl-find-if
                                 (lambda (w) (eq (concur-worker-status w) :idle))
                                 (concur-pool-workers ,pool-sym))))
                   (progn (setf (concur-worker-status worker) :reserved)
                          (funcall resolve worker))
                 (push (cons resolve _reject) (concur-pool-waiter-queue ,pool-sym)))))
         (lambda (,worker-sym)
           (let ((,session-var
                  (lambda (form &rest keys)
                    (apply #'concur:pool-submit-task
                           ,pool-sym form :worker ,worker-sym keys))))
             (concur:unwind-protect! (progn ,@body)
               (lambda () (concur--pool-release-worker ,worker-sym)))))))))

;;;###autoload
(defun concur:pool-map (func items &key (pool (concur--pool-get-default))
                                        (concurrency 4))
  "Apply `FUNC` to each of `ITEMS` in parallel using `POOL`.
This function distributes work across the pool's workers, managing
the concurrency level, and returns a single promise that resolves with
a list of all the results in the original order.

Arguments:
- `FUNC` (function): The function to apply to each item.
- `ITEMS` (list): The list of items to process.
- `:POOL` (concur-pool, optional): The pool to use.
- `:CONCURRENCY` (integer, optional): Max number of items to process at once.

Returns:
- `(concur-promise)`: A promise that resolves with the list of results."
  (concur:with-nursery (n :concurrency concurrency)
    (concur:all
     (mapcar
      (lambda (item)
        (concur:nursery-start-soon
         n (lambda () (concur:pool-eval `(funcall ',func ',item) :pool pool))))
      items))))

;;;###autoload
(defun concur:pool-shutdown! (&optional pool)
  "Gracefully shut down a worker `POOL`.

Arguments:
- `POOL` (concur-pool, optional): The pool to shut down. Defaults to the
  global default pool.

Returns:
- `nil`."
  (interactive)
  (let ((p (or pool (concur--pool-get-default))))
    (concur--validate-pool p 'concur:pool-shutdown!)
    (concur--log :info nil "Shutting down pool %S..." (concur-pool-name p))
    (concur:with-mutex! (concur-pool-lock p)
      (unless (concur-pool-shutdown-p p)
        (setf (concur-pool-shutdown-p p) t)
        (dolist (worker (concur-pool-workers p))
          (when-let (proc (concur-worker-process worker))
            (when (process-live-p proc)
              (when-let (task (concur-worker-current-task worker))
                (concur:reject (concur-pool-task-promise task)
                               (concur:make-error :type 'concur-pool-shutdown)))
              (delete-process proc))))
        (while-let ((task (concur-priority-queue-pop (concur-pool-task-queue p))))
          (concur:reject (concur-pool-task-promise task)
                         (concur:make-error :type 'concur-pool-shutdown)))
        (setf (concur-pool-workers p) nil)))
    (when (eq p concur--default-pool)
      (setq concur--default-pool nil))))

;;;###autoload
(defun concur:pool-status (&optional pool)
  "Return a snapshot of the `POOL`'s current status.

Arguments:
- `POOL` (concur-pool, optional): The pool to inspect. Defaults to the
  global default pool.

Returns:
- (plist): A property list with pool metrics."
  (interactive)
  (let* ((p (or pool (concur--pool-get-default))))
    (unless p (error "No active pool to inspect."))
    (concur--validate-pool p 'concur:pool-status)
    (concur:with-mutex! (concur-pool-lock p)
      `(:name ,(concur-pool-name p)
        :size ,(length (concur-pool-workers p))
        :idle-workers ,(-count (lambda (w) (eq (concur-worker-status w) :idle))
                               (concur-pool-workers p))
        :busy-workers ,(-count (lambda (w) (eq (concur-worker-status w) :busy))
                               (concur-pool-workers p))
        :reserved-workers ,(-count (lambda (w) (eq (concur-worker-status w) :reserved))
                                   (concur-pool-workers p))
        :failed-workers ,(-count (lambda (w) (eq (concur-worker-status w) :failed))
                                 (concur-pool-workers p))
        :queued-tasks ,(concur-priority-queue-length (concur-pool-task-queue p))
        :waiting-sessions ,(length (concur-pool-waiter-queue p))
        :is-shutdown ,(concur-pool-shutdown-p p)))))

(provide 'concur-pool)
;;; concur-pool.el ends here