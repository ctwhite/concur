;;; concur-shell.el --- Persistent Shell Pool for Async Commands -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a persistent pool of reusable shell processes for
;; executing external commands asynchronously. It's a high-performance backend
;; for `concur-process.el`, minimizing overhead by reusing worker processes.
;;
;; It offers two main interfaces:
;; 1. `concur:shell-submit-command`: For running independent, stateless
;;    commands concurrently, with output streamed via `concur-stream`.
;; 2. `concur:shell-session`: A macro that reserves a dedicated worker for
;;    stateful command sequences, ensuring they run in the same shell
;;    environment.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'json)
(require 'async)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-stream)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization & Errors

(defcustom concur-shell-pool-size 4
  "The number of persistent shell processes to maintain in the default pool."
  :type 'integer :group 'concur)

(defcustom concur-shell-program-and-args '("/bin/bash" "-i")
  "Program and arguments to start the persistent shell.
Must be interactive (`-i`) to prevent exiting after one command."
  :type '(list :tag "Shell Program and Arguments"
               (string :tag "Program")
               (repeat string :tag "Arguments"))
  :group 'concur)

(defcustom concur-shell-max-worker-restart-attempts 3
  "Max consecutive restart attempts for a worker before it's marked failed."
  :type 'integer :group 'concur)

(define-error 'concur-shell-error "Error in the persistent shell." 'concur-error)
(define-error 'concur-shell-command-error "Error executing shell command." 'concur-shell-error)
(define-error 'concur-shell-command-timeout-error "Shell command timed out." 'concur-shell-error)
(define-error 'concur-shell-poison-pill-error "Command repeatedly crashed workers." 'concur-shell-error)
(define-error 'concur-shell-session-error "Error in shell session." 'concur-shell-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-shell-task (:constructor %%make-concur-shell-task))
  "Represents a command to be executed by a shell worker.

Fields:
- `id` (string): A unique identifier for the task.
- `command` (string): The shell command string to execute.
- `cwd` (string or nil): The working directory for the command.
- `output-stream` (concur-stream): Stream to write command output to.
- `error-promise` (concur-promise): Promise to settle on completion/error.
- `timeout` (number or nil): Command-specific timeout in seconds.
- `retries` (integer): Counter for automatic retries on worker crash."
  id command cwd output-stream error-promise timeout
  (retries 0 :type integer))

(cl-defstruct (concur-shell-worker (:constructor %%make-concur-shell-worker))
  "Represents a single persistent shell worker in the pool.

Fields:
- `process` (process): The worker's Emacs `async` process object.
- `id` (integer): A unique identifier for the worker.
- `status` (keyword): The current state (`:idle`, `:busy`, `:dead`, etc.).
- `current-task` (concur-shell-task): The task it is currently running.
- `timeout-timer` (timer): The Emacs-side timeout timer for the task.
- `restart-attempts` (integer): Counter for restart attempts after crashes.
- `reserved-p` (boolean): If `t`, this worker is reserved for a session."
  process id
  (status :idle :type (member :idle :busy :dead :restarting :failed :reserved))
  current-task timeout-timer
  (restart-attempts 0 :type integer)
  (reserved-p nil :type boolean))

(cl-defstruct (concur-shell-pool (:constructor %%make-concur-shell-pool))
  "Represents a pool of persistent shell processes.

Fields:
- `workers` (list): A list of `concur-shell-worker` structs.
- `lock` (concur-lock): A mutex protecting the pool's shared state.
- `task-queue` (concur-queue): Queue for stateless commands.
- `waiter-queue` (concur-queue): Queue for sessions awaiting a free worker.
- `shutdown-p` (boolean): `t` if the pool is shutting down."
  workers lock task-queue waiter-queue shutdown-p)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Default Shell Pool Management

(defvar concur--default-shell-pool nil
  "The global, default instance of the persistent shell pool.")
(defvar concur--default-shell-pool-lock
  (concur:make-lock "concur-default-shell-pool-lock")
  "A lock to protect the one-time initialization of the default pool.")

(defun concur-shell-pool-get-default ()
  "Return the default shell pool, creating it if necessary. Thread-safe."
  (or concur--default-shell-pool
      (progn
        (concur:with-mutex! concur--default-shell-pool-lock
          (unless concur--default-shell-pool
            (setq concur--default-shell-pool (concur-shell-pool-create))))
        concur--default-shell-pool)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker and Task Logic

(defun concur--shell-process-finished-command (worker task exit-code raw-output)
  "Process the result of a finished command, settling its promise."
  (let ((output-stream (concur-shell-task-output-stream task))
        (error-promise (concur-shell-task-error-promise task)))
    (if (= exit-code 0)
        (progn
          (when (and output-stream (not (s-blank? raw-output)))
            (concur:stream-write output-stream raw-output))
          (when output-stream (concur:stream-close output-stream))
          (concur:resolve error-promise t))
      (let* ((msg (format "Command failed with exit code %d: %s" exit-code
                          (s-truncate 80 (concur-shell-task-command task))))
             (err (concur:make-error :type 'concur-shell-command-error
                                     :message msg
                                     :cause (format "Exit Code: %d" exit-code))))
        (when output-stream (concur:stream-error output-stream err))
        (concur:reject error-promise err)))))

(defun concur--shell-worker-script-form ()
  "Generate the Elisp code that a background `async` worker will execute."
  `(lambda ()
     (require 'json)
     (let ((load-path ,load-path) (default-directory ,default-directory))
       (let ((shell-proc (apply #'start-process "concur-internal-shell"
                                (current-buffer)
                                concur-shell-program-and-args)))
         (set-process-coding-system shell-proc 'utf-8 'utf-8)
         (set-process-query-on-exit-flag shell-proc nil)
         (while t
           (let* ((json-string (read-line))
                  (task-data (json-read-from-string json-string))
                  (command (cdr (assoc 'command task-data)))
                  (cwd (cdr (assoc 'cwd task-data)))
                  (full-command (if cwd
                                    (format "cd %s && %s"
                                            (shell-quote-argument cwd) command)
                                  command))
                  ;; Redirect stderr to stdout within the shell command.
                  (final-command (format "(%s) 2>&1; echo -n '%s'$?;\n"
                                         full-command ,concur--shell-eof-marker))
                  (output-buffer (generate-new-buffer "*shell-output*")))
             (unwind-protect
                 (progn
                   (set-process-filter
                    shell-proc
                    (lambda (_p c) (with-current-buffer output-buffer (insert c))))
                   (process-send-string shell-proc final-command)
                   ;; NOTE: This is a cooperative busy-wait. A more advanced
                   ;; implementation could use a filter on the inner shell
                   ;; process to be fully event-driven.
                   (while (not (string-match-p
                                (regexp-quote ,concur--shell-eof-marker)
                                (buffer-string)))
                     (accept-process-output shell-proc 0.1))
                   ;; BUG FIX: Use a robust regex to parse output, not s-split.
                   (let (exit-code output)
                     (with-current-buffer output-buffer
                       (let ((marker-re
                              (concat (regexp-quote ,concur--shell-eof-marker)
                                      "\\([0-9]+\\)$")))
                         (string-match marker-re (buffer-string))
                         (setq output (substring (buffer-string) 0
                                                 (match-beginning 0)))
                         (setq exit-code
                               (string-to-number (match-string 1 (buffer-string))))))
                     (princ (json-serialize `(:exit ,exit-code :output ,output)))
                     (princ "\n")
                     (finish-output (standard-output)))))
               (when (buffer-live-p output-buffer)
                 (kill-buffer output-buffer)))))))))

(defun concur--shell-filter (worker chunk)
  "The filter for a worker process. Parses JSON responses from a worker."
  (let* ((pool (concur-shell-pool-get-default))
         (task (concur-shell-worker-current-task worker)))
    (condition-case err
        (let* ((response (json-read-from-string chunk))
               (exit-code (plist-get response :exit))
               (output (plist-get response :output)))
          (when task
            (when-let (timer (concur-shell-worker-timeout-timer worker))
              (cancel-timer timer)
              (setf (concur-shell-worker-timeout-timer worker) nil))
            (concur--shell-process-finished-command worker task exit-code output)
            (concur:with-mutex! (concur-shell-pool-lock pool)
              (setf (concur-shell-worker-current-task worker) nil)
              (setf (concur-shell-worker-restart-attempts worker) 0)
              (if (concur-shell-worker-reserved-p worker)
                  (setf (concur-shell-worker-status worker) :idle)
                (concur--pool-release-worker pool worker))))))
      (error
       (warn "Concur-shell: Worker %d sent malformed data: %s"
             (concur-shell-worker-id worker) chunk)
       (kill-process (concur-shell-worker-process worker))))))

(defun concur--shell-handle-command-timeout (worker task)
  "Handles a command timeout by killing the worker and rejecting the promise."
  (kill-process (concur-shell-worker-process worker))
  (when (concur:pending-p (concur-shell-task-error-promise task))
    (let ((err (concur:make-error :type 'concur-shell-command-timeout-error
                                  :message "Command timed out")))
      (concur:reject (concur-shell-task-error-promise task) err)
      (when-let (stream (concur-shell-task-output-stream task))
        (concur:stream-error stream err)))))

(defun concur--shell-handle-crashed-task (worker task)
  "Handle the task that was running on a worker when it crashed."
  (cl-incf (concur-shell-task-retries task))
  (let* ((pool (concur-shell-pool-get-default))
         (retries (concur-shell-task-retries task))
         (max-retries concur-shell-max-worker-restart-attempts))
    (if (> retries max-retries)
        (let ((err (concur:make-error :type 'concur-shell-poison-pill-error)))
          (when-let (p (concur-shell-task-error-promise task)) (concur:reject p err))
          (when-let (s (concur-shell-task-output-stream task)) (concur:stream-error s err)))
      (unless (concur-shell-worker-reserved-p worker)
        (concur:with-mutex! (concur-shell-pool-lock pool)
          (concur-queue-enqueue (concur-shell-pool-task-queue pool) task))))))

(defun concur--shell-sentinel (worker event)
  "The sentinel for a worker. Handles unexpected termination and restarts."
  (let ((pool (concur-shell-pool-get-default)))
    (when-let (task (concur-shell-worker-current-task worker))
      (concur--shell-handle-crashed-task worker task))
    (concur:with-mutex! (concur-shell-pool-lock pool)
      (setf (concur-shell-worker-status worker) :dead)
      (setf (concur-shell-worker-current-task worker) nil)
      (unless (concur-shell-pool-shutdown-p pool)
        (cl-incf (concur-shell-worker-restart-attempts worker))
        (if (> (concur-shell-worker-restart-attempts worker)
               concur-shell-max-worker-restart-attempts)
            (setf (concur-shell-worker-status worker) :failed)
          (setf (concur-shell-worker-status worker) :restarting)
          (setf (concur-shell-worker-process worker)
                (concur--shell-start-worker worker pool))))
      (concur--shell-dispatch-next-task pool))))

(defun concur--shell-start-worker (worker pool)
  "Create and start a single `async` worker process."
  (condition-case err
      (let ((proc (async-start (concur--shell-worker-script-form) nil)))
        (set-process-filter proc (lambda (_p c) (concur--shell-filter worker c)))
        (set-process-sentinel proc (lambda (_p e) (concur--shell-sentinel worker e)))
        (set-process-coding-system proc 'utf-8 'utf-8)
        proc)
    (error (setf (concur-shell-worker-status worker) :failed) nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Pool and Dispatch Management

(defun concur-shell-pool-create ()
  "Create and start a new persistent shell pool."
  (let ((pool (%%make-concur-shell-pool
               :lock (concur:make-lock "shell-pool-lock")
               :task-queue (concur-queue-create)
               :waiter-queue (concur-queue-create))))
    (setf (concur-shell-pool-workers pool)
          (cl-loop for i from 1 to concur-shell-pool-size
                   collect
                   (let ((worker (%%make-concur-shell-worker :id i :status :idle)))
                     (setf (concur-shell-worker-process worker)
                           (concur--shell-start-worker worker pool))
                     worker)))
    pool))

(defun concur--pool-get-idle-worker (pool)
  "Find an idle, non-reserved worker. Caller must hold lock."
  (-find-if (lambda (w) (and (eq (concur-shell-worker-status w) :idle)
                               (not (concur-shell-worker-reserved-p w))))
            (concur-shell-pool-workers pool)))

(defun concur--pool-release-worker (pool worker)
  "Return a worker to the pool. Caller must hold lock."
  (setf (concur-shell-worker-status worker) :idle)
  (setf (concur-shell-worker-reserved-p worker) nil)
  (setf (concur-shell-worker-current-task worker) nil)
  (concur--shell-dispatch-next-task pool))

(defun concur--shell-dispatch-next-task (pool)
  "Find an idle worker and dispatch the next task or waiting session.
Must be called from within the pool's lock."
  (if-let ((waiter (concur-queue-dequeue (concur-shell-pool-waiter-queue pool))))
      (if-let ((worker (concur--pool-get-idle-worker pool)))
          (funcall (car waiter) worker) ; Resolve waiter's promise with worker
        (concur-queue-enqueue (concur-shell-pool-waiter-queue pool) waiter))
    (unless (concur-queue-empty-p (concur-shell-pool-task-queue pool))
      (when-let ((worker (concur--pool-get-idle-worker pool)))
        (let* ((task (concur-queue-dequeue (concur-shell-pool-task-queue pool)))
               (json (json-serialize `((id . ,(concur-shell-task-id task))
                                       (command . ,(concur-shell-task-command task))
                                       (cwd . ,(concur-shell-task-cwd task))))))
          (setf (concur-shell-worker-status worker) :busy)
          (setf (concur-shell-worker-current-task worker) task)
          (when-let (timeout (concur-shell-task-timeout task))
            (setf (concur-shell-worker-timeout-timer worker)
                  (run-at-time timeout nil #'concur--shell-handle-command-timeout
                               worker task)))
          (process-send-string (concur-shell-worker-process worker)
                               (concat json "\n")))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:shell-submit-command (command &key cwd timeout)
  "Submit a single COMMAND to the persistent shell pool asynchronously.

Arguments:
- `COMMAND` (string): The shell command to execute.
- `CWD` (string, optional): The working directory for the command.
- `TIMEOUT` (number, optional): A specific timeout in seconds for this command.

Returns:
  (cons (concur-stream . concur-promise)) A cons cell containing:
  - `car`: A `concur-stream` that will receive the command's stdout/stderr.
  - `cdr`: A `concur-promise` that resolves on success or rejects on failure."
  (let ((output-stream (concur:stream-create))
        (error-promise (concur:make-promise)))
    (concur:with-executor (lambda (resolve reject)
      (let ((pool (concur-shell-pool-get-default)))
        (concur:with-mutex! (concur-shell-pool-lock pool)
          (let ((task (%%make-concur-shell-task
                       :id (format "shell-task-%s" (random))
                       :command command :cwd cwd :timeout timeout
                       :output-stream output-stream
                       :error-promise error-promise)))
            (concur-queue-enqueue (concur-shell-pool-task-queue pool) task)
            (concur--shell-dispatch-next-task pool)
            (funcall resolve (cons output-stream error-promise))))))))

(defun concur--shell-make-session-runner (worker pool)
  "Create the command-running lambda for a `concur:shell-session`."
  (lambda (command &key cwd timeout)
    (let ((output-stream (concur:stream-create))
          (command-promise (concur:make-promise)))
      (concur:with-mutex! (concur-shell-pool-lock pool)
        (let ((task (%%make-concur-shell-task
                     :id (format "session-cmd-%s" (random))
                     :command command :cwd cwd :timeout timeout
                     :output-stream output-stream
                     :error-promise command-promise)))
          (setf (concur-shell-worker-status worker) :busy)
          (setf (concur-shell-worker-current-task worker) task)
          (when-let (cmd-timeout (or timeout concur-shell-command-timeout-default))
            (setf (concur-shell-worker-timeout-timer worker)
                  (run-at-time cmd-timeout nil #'concur--shell-handle-command-timeout
                               worker task)))
          (let ((json (json-serialize `((id . ,(concur-shell-task-id task))
                                         (command . ,command) (cwd . ,cwd)))))
            (process-send-string (concur-shell-worker-process worker)
                                 (concat json "\n")))))
      (cons output-stream command-promise))))

;;;###autoload
(defmacro concur:shell-session ((session-var) &rest body)
  "Reserve a single shell worker for a sequence of stateful commands.

Arguments:
- `SESSION-VAR` (symbol): A variable bound to a runner function `(lambda (cmd))`
  that returns `(cons stream . promise)`.
- `BODY` (forms): The code to execute with the session.

Returns:
  (concur-promise) A promise that resolves with the result of the BODY."
  (declare (indent 1) (debug t))
  `(let ((pool (concur-shell-pool-get-default)))
     (concur:chain
         ;; Step 1: Get a worker, waiting if necessary.
         (concur:with-executor (lambda (resolve reject)
           (concur:with-mutex! (concur-shell-pool-lock pool)
             (if-let ((worker (concur--pool-get-idle-worker pool)))
                 (progn
                   (setf (concur-shell-worker-reserved-p worker) t)
                   (funcall resolve worker))
               ;; No worker available, queue ourselves to wait.
               (concur-queue-enqueue (concur-shell-pool-waiter-queue pool)
                                     (cons resolve reject))))))
       ;; Step 2: Once we have a worker, run the session body.
       (lambda (worker)
         (let ((,session-var (concur--shell-make-session-runner worker pool)))
           (unwind-protect (progn ,@body)
             ;; Always release the worker when the session is done.
             (concur:with-mutex! (concur-shell-pool-lock pool)
               (concur--pool-release-worker pool worker))))))))

(provide 'concur-shell)
;;; concur-shell.el ends here