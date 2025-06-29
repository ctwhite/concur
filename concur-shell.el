;;; concur-shell.el --- Enhanced Persistent Shell Pool -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a high-performance, persistent pool of reusable shell
;; processes for executing external commands asynchronously.
;;
;; Key Features:
;; - High-Performance Pool: Reuses persistent shells to avoid process startup
;;   overhead.
;; - Stateful Sessions: `concur:shell-session` allows for reserving a single
;;   worker for a sequence of stateful commands (e.g., changing directories).
;; - Streaming I/O: The API returns `concur-stream` instances, allowing for
;;   efficient, real-time processing of stdout and stderr.
;; - Environment & Cancellation: Supports passing per-command environment
;;   variables and cancellation via `concur-cancel-token`.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'json)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-stream)
(require 'concur-log)
(require 'concur-async)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(defgroup concur nil "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defcustom concur-shell-pool-size 4
  "The number of persistent shell processes in the default pool."
  :type 'integer :group 'concur)

(defcustom concur-shell-program "/bin/bash"
  "The shell program to use for worker processes.
It MUST be a shell that supports process substitution (e.g., bash, zsh)."
  :type 'string :group 'concur)

(defcustom concur-shell-max-worker-restarts 3
  "Maximum consecutive restart attempts for a worker before it is marked as failed."
  :type 'integer :group 'concur)

(defcustom concur-shell-command-timeout-default 30.0
  "Default timeout (in seconds) for shell commands if not specified otherwise."
  :type '(choice (number :min 0.0 :tag "Seconds")
                 (const :tag "No Timeout" nil))
  :group 'concur)

(define-error 'concur-shell-error "A generic error in the shell pool." 'concur-error)
(define-error 'concur-shell-invalid-pool-error "Invalid pool object." 'concur-shell-error)
(define-error 'concur-shell-command-error "A shell command failed." 'concur-shell-error)
(define-error 'concur-shell-timeout "A shell command timed out." 'concur-shell-command-error)
(define-error 'concur-shell-poison-pill "A command repeatedly crashed workers." 'concur-shell-error)
(define-error 'concur-shell-session-error "Error within a shell session." 'concur-shell-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-shell-task (:constructor %%make-shell-task))
  "Represents a command to be executed by a shell worker."
  id command cwd env stdout stderr promise timeout retries stderr-buffer)

(cl-defstruct (concur-shell-worker (:constructor %%make-shell-worker))
  "Represents a single persistent shell worker process in the pool."
  process id status current-task timeout-timer (restart-attempts 0))

(cl-defstruct (concur-shell-pool (:constructor %%make-shell-pool))
  "Represents a pool of persistent shell processes."
  name workers lock task-queue waiter-queue (shutdown-p nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Default Shell Pool Management

(defvar concur--default-shell-pool nil
  "The global, default instance of the persistent shell pool.")

(defvar concur--default-shell-pool-init-lock
  (concur:make-lock "default-shell-pool-init-lock")
  "A lock to protect the one-time initialization of the default pool.")

(defun concur--shell-pool-get-default ()
  "Return the default shell pool, creating it if it doesn't exist."
  (unless concur--default-shell-pool
    (concur:with-mutex! concur--default-shell-pool-init-lock
      (unless concur--default-shell-pool
        (setq concur--default-shell-pool (concur-shell-pool-create))
        (add-hook 'kill-emacs-hook #'concur--shell-pool-shutdown-default-pool))))
  concur--default-shell-pool)

(defun concur--shell-pool-shutdown-default-pool ()
  "Hook function to shut down the default pool when Emacs exits."
  (when concur--default-shell-pool
    (concur:shell-pool-shutdown! concur--default-shell-pool)))

(defun concur--validate-pool (pool function-name)
  "Signal an error if POOL is not a `concur-shell-pool`."
  (unless (concur-shell-pool-p pool)
    (signal 'concur-shell-invalid-pool-error
            (list (format "%s: Invalid pool object" function-name) pool))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker Launching & IPC

(defun concur--shell-worker-script-form ()
  "Generate the Elisp code that a shell worker process will execute."
  `(lambda ()
     (require 'json)
     (require 's)
     ;; Start the persistent sub-shell process (e.g., bash).
     (let ((shell-proc (start-process "concur-internal-shell" (current-buffer)
                                    concur-shell-program)))
       (set-process-coding-system shell-proc 'utf-8 'utf-8)
       (set-process-query-on-exit-flag shell-proc nil)
       (set-process-filter shell-proc (lambda (_p c) (princ c)))
       ;; Main loop: read a JSON task, execute it in the sub-shell, repeat.
       (while t
         (let* ((json-string (read-line))
                (task-data (json-read-from-string json-string))
                (command (cdr (assoc 'command task-data)))
                (cwd (cdr (assoc 'cwd task-data)))
                (env (cdr (assoc 'env task-data)))
                (env-prefix (s-join " " (--map (format "%s=%s"
                                                       (shell-quote-argument (car it))
                                                       (shell-quote-argument (cdr it)))
                                              env)))
                (effective-cmd (if cwd (format "cd %s && %s"
                                               (shell-quote-argument cwd) command)
                                 command))
                ;; This is the core trick: use process substitution to create
                ;; two background pipes. The command's stdout and stderr are
                ;; redirected to these pipes. Inside each pipe, a `while read`
                ;; loop prefixes each line with "O:" or "E:" respectively.
                (multiplex-cmd
                 (format (concat "{ %s %s; } "
                                 "1> >(while IFS= read -r line; do "
                                 "echo \"O:$line\"; done) "
                                 "2> >(while IFS= read -r line; do "
                                 "echo \"E:$line\"; done)")
                         env-prefix effective-cmd))
                ;; After the command finishes, we echo its exit code,
                ;; prefixed with "X:".
                (final-command (format "%s; echo \"X:$?\";\n" multiplex-cmd)))
           (process-send-string shell-proc final-command))))))

(defun concur--shell-start-worker (worker pool)
  "Create and start a single background worker process."
  (setf (concur-shell-worker-process worker)
        (concur:async-launch
         (concur--shell-worker-script-form)
         :name (format "concur-shell-worker-%d" (concur-shell-worker-id worker))
         :filter (lambda (_p c) (concur--shell-filter worker c))
         :sentinel (lambda (_p e) (concur--shell-sentinel worker e pool)))))

(defun concur--shell-filter (worker chunk)
  "Filter for worker processes, de-multiplexing responses from the shell."
  (let ((buffer (get-buffer-create
                 (format "*concur-shell-%d-filter*" (concur-shell-worker-id worker)))))
    (with-current-buffer buffer
      (goto-char (point-max)) (insert chunk) (goto-char (point-min))
      (while (re-search-forward "^\\([OEX]\\):\\(.*\\)\n" nil t)
        (let* ((prefix (match-string 1))
               (content (match-string 2))
               (task (concur-shell-worker-current-task worker)))
          (when task
            (pcase prefix
              ("O" (when-let (s (concur-shell-task-stdout task))
                     (concur:stream-write s (concat content "\n"))))
              ("E" (setf (concur-shell-task-stderr-buffer task)
                         (concat (concur-shell-task-stderr-buffer task)
                                 content "\n"))
                   (when-let (s (concur-shell-task-stderr task))
                     (concur:stream-write s (concat content "\n"))))
              ("X" (let ((exit-code (string-to-number content)))
                     (concur--shell-finish-command worker task exit-code))))))
        (replace-match "" nil nil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Lifecycle, Error Handling, and Dispatch

(defun concur--shell-finish-command (worker task exit-code)
  "Process a finished command, settling its promise and streams."
  (let ((promise (concur-shell-task-promise task)))
    (when-let (timer (concur-shell-worker-timeout-timer worker))
      (setf (concur-shell-worker-timeout-timer worker) nil) (cancel-timer timer))

    (when-let (s (concur-shell-task-stdout task)) (concur:stream-close s))
    (when-let (s (concur-shell-task-stderr task)) (concur:stream-close s))

    (cond
     ((= exit-code 0) (concur:resolve promise t))
     ((= exit-code -1) ; Special code for timeout.
      (concur:reject promise (concur:make-error :type 'concur-shell-timeout)))
     (t (concur:reject
         promise (concur:make-error
                  :type 'concur-shell-command-error
                  :message (format "Command failed (code %d)" exit-code)
                  :exit-code exit-code
                  :stderr (s-trim (concur-shell-task-stderr-buffer task))
                  :cmd (concur-shell-task-command task))))))
  (concur--pool-release-worker worker))

(defun concur--shell-handle-command-timeout (worker task)
  "Handle a timed out task by killing the worker process."
  (concur--log :warn nil "Command '%s' (Worker %d) timed out. Killing worker."
               (s-truncate 40 (concur-shell-task-command task))
               (concur-shell-worker-id worker))
  ;; Killing the process triggers the sentinel, which handles cleanup.
  (when-let (proc (concur-shell-worker-process worker))
    (ignore-errors (delete-process proc))))

(defun concur--shell-sentinel (worker event pool)
  "Sentinel for worker processes. Handles unexpected termination and restart."
  (concur--log :warn nil "Shell worker %d died. Event: %s"
               (concur-shell-worker-id worker) event)
  (let ((task (concur-shell-worker-current-task worker)))
    (when-let (timer (concur-shell-worker-timeout-timer worker)) (cancel-timer timer))
    ;; If the worker was busy, handle the task.
    (when task
      (cl-incf (concur-shell-task-retries task))
      (if (> (concur-shell-task-retries task) concur-shell-max-worker-restarts)
          ;; This task is a "poison pill".
          (concur:reject (concur-shell-task-promise task)
                         (concur:make-error :type 'concur-shell-poison-pill))
        ;; Re-queue the task to be tried on another worker.
        (concur:with-mutex! (concur-shell-pool-lock pool)
          (concur-queue-enqueue (concur-shell-pool-task-queue pool) task))))
    ;; Attempt to restart the worker.
    (concur:with-mutex! (concur-shell-pool-lock pool)
      (setf (concur-shell-worker-status worker) :dead)
      (unless (concur-shell-pool-shutdown-p pool)
        (cl-incf (concur-shell-worker-restart-attempts worker))
        (if (> (concur-shell-worker-restart-attempts worker)
               concur-shell-max-worker-restarts)
            (progn (setf (concur-shell-worker-status worker) :failed)
                   (concur--log :error nil "Worker %d failed permanently."
                                (concur-shell-worker-id worker)))
          (setf (concur-shell-worker-status worker) :restarting)
          (concur--shell-start-worker worker pool)))
      (concur--shell-dispatch-next-task pool))))

(defun concur--pool-release-worker (worker)
  "Release a worker back to the pool, making it available for new tasks."
  (let ((pool (concur--shell-pool-get-default)))
    (concur:with-mutex! (concur-shell-pool-lock pool)
      (setf (concur-shell-worker-status worker) :idle)
      (setf (concur-shell-worker-current-task worker) nil)
      ;; After releasing, check if there's pending work.
      (concur--shell-dispatch-next-task pool))))

(defun concur--shell-dispatch-next-task (pool)
  "Find an idle worker and dispatch the next task or waiting session.
This function MUST be called from within the pool's lock."
  (unless (concur-shell-pool-shutdown-p pool)
    ;; Prioritize sessions waiting for a worker.
    (if-let ((waiter (pop (concur-shell-pool-waiter-queue pool))))
        (if-let ((worker (cl-find-if (lambda (w) (eq (concur-shell-worker-status w) :idle))
                                    (concur-shell-pool-workers pool))))
            (progn
              (setf (concur-shell-worker-status worker) :reserved)
              (funcall (car waiter) worker)) ; Resolve the waiter's promise.
          (push waiter (concur-shell-pool-waiter-queue pool))) ; Re-queue if no worker.
      ;; If no waiting sessions, check the general task queue.
      (unless (concur-queue-empty-p (concur-shell-pool-task-queue pool))
        (when-let ((worker (cl-find-if (lambda (w) (eq (concur-shell-worker-status w) :idle))
                                      (concur-shell-pool-workers pool))))
          (let* ((task (concur-queue-dequeue (concur-shell-pool-task-queue pool)))
                 (payload `((command . ,(concur-shell-task-command task))
                            (cwd . ,(concur-shell-task-cwd task))
                            (env . ,(concur-shell-task-env task)))))
            (setf (concur-shell-worker-status worker) :busy)
            (setf (concur-shell-worker-current-task worker) task)
            (when-let (timeout (or (concur-shell-task-timeout task)
                                   concur-shell-command-timeout-default))
              (setf (concur-shell-worker-timeout-timer worker)
                    (run-at-time timeout nil #'concur--shell-handle-command-timeout
                                 worker task)))
            (process-send-string (concur-shell-worker-process worker)
                                 (json-encode-to-string payload))
            (process-send-string (concur-shell-worker-process worker) "\n")))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Pool Management

;;;###autoload
(cl-defun concur-shell-pool-create (&key (name (format "shell-pool-%S" (gensym)))
                                        (size concur-shell-pool-size))
  "Create and start a new persistent shell pool.

Arguments:
- `:NAME` (string, optional): A descriptive name for the pool.
- `:SIZE` (integer, optional): The number of worker shells in the pool.

Returns:
- `(concur-shell-pool)`: A new, initialized pool object."
  (concur--log :info nil "Creating new shell pool '%s' with %d workers." name size)
  (let ((new-pool (%%make-shell-pool
                   :name name :lock (concur:make-lock "shell-pool-lock")
                   :task-queue (concur-queue-create))))
    (setf (concur-shell-pool-workers new-pool)
          (cl-loop for i from 1 to size
                   collect
                   (let ((worker (%%make-shell-worker :id i :status :idle)))
                     (concur--shell-start-worker worker new-pool)
                     worker)))
    new-pool))

;;;###autoload
(defun concur:shell-pool-shutdown! (&optional pool)
  "Gracefully shut down a worker `POOL`.

Arguments:
- `POOL` (concur-shell-pool, optional): The pool to shut down. Defaults to the
  global default pool.

Returns:
- `nil`."
  (interactive)
  (let ((p (or pool (concur--shell-pool-get-default))))
    (concur--validate-pool p 'concur:shell-pool-shutdown!)
    (concur--log :info nil "Shutting down pool %S..." (concur-shell-pool-name p))
    (concur:with-mutex! (concur-shell-pool-lock p)
      (unless (concur-shell-pool-shutdown-p p)
        (setf (concur-shell-pool-shutdown-p p) t)
        (dolist (worker (concur-shell-pool-workers p))
          (when-let (proc (concur-shell-worker-process worker))
            (when (process-live-p proc)
              (when-let (task (concur-shell-worker-current-task worker))
                (concur:reject (concur-shell-task-promise task)
                               (concur:make-error :type 'concur-shell-shutdown)))
              (delete-process proc))))
        (while-let ((task (concur-queue-dequeue (concur-shell-pool-task-queue p))))
          (concur:reject (concur-shell-task-promise task)
                         (concur:make-error :type 'concur-shell-shutdown)))
        (setf (concur-shell-pool-workers p) nil)))
    (when (eq p concur--default-shell-pool)
      (setq concur--default-shell-pool nil))))

;;;###autoload
(defun concur:shell-pool-status (&optional pool)
  "Return a snapshot of the `POOL`'s current status.

Arguments:
- `POOL` (concur-shell-pool, optional): The pool to inspect. Defaults to the
  global default pool.

Returns:
- (plist): A property list with pool metrics."
  (interactive)
  (let* ((p (or pool (concur--shell-pool-get-default))))
    (unless p (error "No active shell pool to inspect."))
    (concur--validate-pool p 'concur:shell-pool-status)
    (concur:with-mutex! (concur-shell-pool-lock p)
      `(:name ,(concur-shell-pool-name p)
        :size ,(length (concur-shell-pool-workers p))
        :idle-workers ,(-count (lambda (w) (eq (concur-shell-worker-status w) :idle))
                               (concur-shell-pool-workers p))
        :busy-workers ,(-count (lambda (w) (eq (concur-shell-worker-status w) :busy))
                               (concur-shell-pool-workers p))
        :reserved-workers ,(-count (lambda (w) (eq (concur-shell-worker-status w) :reserved))
                                   (concur-shell-pool-workers p))
        :failed-workers ,(-count (lambda (w) (eq (concur-shell-worker-status w) :failed))
                                 (concur-shell-pool-workers p))
        :queued-tasks ,(concur-queue-length (concur-shell-pool-task-queue p))
        :waiting-sessions ,(length (concur-shell-pool-waiter-queue p))
        :is-shutdown ,(concur-shell-pool-shutdown-p p)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Command Execution

;;;###autoload
(cl-defun concur:shell-submit-command (command
                                       &key cwd env timeout cancel-token
                                       pool worker)
  "Submit a single `COMMAND` to the shell pool. (Low-level)
This is the primary low-level interface. It immediately returns a list
containing streams for stdout and stderr, and a promise that settles
when the command finishes.

Arguments:
- `COMMAND` (string): The shell command string to execute.
- `:CWD` (string, optional): The working directory for the command.
- `:ENV` (alist, optional): An alist of `(VAR . VAL)` strings to set as
  environment variables for the command.
- `:TIMEOUT` (number, optional): A command-specific timeout in seconds.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel the command.
- `:POOL` (concur-shell-pool, internal): The pool to use.
- `:WORKER` (concur-shell-worker, internal): Direct task to this worker.

Returns:
- (list): A three-element list: `(STDOUT-STREAM STDERR-STREAM PROMISE)`."
  (let ((stdout (concur:stream-create))
        (stderr (concur:stream-create))
        (promise (concur:make-promise :cancel-token cancel-token))
        (effective-pool (or pool (concur--shell-pool-get-default))))
    (concur--validate-pool effective-pool 'concur:shell-submit-command)
    (concur:with-mutex! (concur-shell-pool-lock effective-pool)
      (let ((task (%%make-shell-task
                   :id (format "shell-task-%s" (gensym))
                   :command command :cwd cwd :env env :timeout timeout
                   :stdout stdout :stderr stderr :promise promise)))
        (if worker
            ;; Direct-to-worker submission (used by sessions).
            (let ((payload `((command . ,command) (cwd . ,cwd) (env . ,env))))
              (setf (concur-shell-worker-status worker) :busy)
              (setf (concur-shell-worker-current-task worker) task)
              (when-let (tm (or timeout concur-shell-command-timeout-default))
                (setf (concur-shell-worker-timeout-timer worker)
                      (run-at-time tm nil #'concur--shell-handle-command-timeout worker task)))
              (process-send-string (concur-shell-worker-process worker)
                                   (concat (json-encode-to-string payload) "\n")))
          ;; Standard queued submission.
          (progn
            (concur-queue-enqueue (concur-shell-pool-task-queue effective-pool) task)
            (concur--shell-dispatch-next-task effective-pool)))))
    (list stdout stderr promise)))

;;;###autoload
(defmacro concur:shell-command-stream (command &rest keys)
  "Run `COMMAND` in the shell pool, returning its I/O streams.
This is a high-level wrapper for `concur:shell-submit-command` intended
for streaming use cases.

Arguments:
- `COMMAND` (string): The shell command string to execute.
- `KEYS` (plist): A property list of options like `:cwd`, `:env`,
  `:timeout`, `:cancel-token`, and `:pool`.

Returns:
- (list): A three-element list: `(STDOUT-STREAM STDERR-STREAM PROMISE)`."
  (declare (indent 1) (debug t))
  `(concur:shell-submit-command ,command ,@keys))

;;;###autoload
(defmacro concur:shell-command (command &rest keys)
  "Run `COMMAND` in the shell pool and get its stdout as a string.
This high-level wrapper rejects if the command fails or produces any
stderr, and resolves with the complete, trimmed stdout content on success.
It buffers the entire output; for large outputs, use
`concur:shell-command-stream` instead.

Arguments:
- `COMMAND` (string): The shell command string to execute.
- `KEYS` (plist): Options passed to `concur:shell-submit-command`.

Returns:
- (concur-promise): A promise that resolves with the stdout string."
  (declare (indent 1) (debug t))
  `(concur:chain
       (concur:shell-submit-command ,command ,@keys)
     (:let ((stdout-stream (car <>))
            (stderr-stream (cadr <>))
            (completion-promise (caddr <>))))
     ;; Wait for the command to finish and for both streams to be drained.
     (:let (results (concur:all (list completion-promise
                                      (concur:stream-drain stdout-stream)
                                      (concur:stream-drain stderr-stream)))))
     (let ((stdout-str (s-trim (s-join "" (cadr results))))
           (stderr-str (s-trim (s-join "" (caddr results)))))
       (if (s-blank? stderr-str)
           stdout-str
         (concur:rejected!
          (concur:make-error :type 'concur-shell-command-error
                             :stderr stderr-str :stdout stdout-str
                             :message "Command produced output on stderr"))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Sessions

;;;###autoload
(defmacro concur:shell-session ((session-var &key pool) &rest body)
  "Reserve a single worker for a sequence of stateful commands.
This macro guarantees that all commands executed via `SESSION-VAR` run
sequentially on the same persistent shell, preserving state (like CWD
and environment variables) between them.

Arguments:
- `SESSION-VAR` (symbol): A variable bound to the session's runner function.
  The runner has the signature `(lambda (command &key cwd timeout ...))`.
- `:POOL` (concur-shell-pool, optional): The pool to use.
- `BODY` (forms): The code to execute within the session.

Returns:
- (concur-promise): A promise that resolves with the result of the last
  form in `BODY`."
  (let ((pool-sym (gensym "pool-")) (worker-sym (gensym "worker-")))
    `(let ((,pool-sym (or ,pool (concur--shell-pool-get-default))))
       (concur--validate-pool ,pool-sym 'concur:shell-session)
       (concur:chain
           ;; Phase 1: Acquire a worker from the pool.
           (concur:with-executor (resolve _reject)
             (concur:with-mutex! (concur-shell-pool-lock ,pool-sym)
               (if-let ((worker (cl-find-if (lambda (w) (eq (concur-shell-worker-status w) :idle))
                                            (concur-shell-pool-workers ,pool-sym))))
                   (progn (setf (concur-shell-worker-status worker) :reserved)
                          (funcall resolve worker))
                 (push (cons resolve _reject)
                       (concur-shell-pool-waiter-queue ,pool-sym)))))
         ;; Phase 2: Execute the body with the reserved worker.
         (lambda (,worker-sym)
           (let ((,session-var
                  (lambda (command &rest keys)
                    (apply #'concur:shell-submit-command
                           command :pool ,pool-sym :worker ,worker-sym keys))))
             (concur:unwind-protect!
                 (progn ,@body)
               ;; Phase 3: Always release the worker back to the pool.
               (lambda () (concur--pool-release-worker ,worker-sym)))))))))

(provide 'concur-shell)
;;; concur-shell.el ends here