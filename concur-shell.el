;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-shell.el --- Persistent Shell Pool for Async Commands -*- lexical-binding: t; -*-

;;; Commentary:

;; This library provides a persistent pool of reusable shell processes for
;; executing external commands asynchronously. It serves as a high-performance
;; backend for shell-based operations, minimizing overhead by reusing worker
;; processes and providing robust management of their lifecycle.
;;
;; It offers two main interfaces:
;; 1. `concur:shell-submit-command`: For running independent, stateless
;;    commands concurrently, with output streamed via `concur-stream`.
;; 2. `concur:shell-session`: A macro that reserves a dedicated worker for
;;    stateful command sequences, ensuring they run in the same shell
;;    environment. This is ideal for scenarios where shell state (like
;;    `cd` commands, environment variable changes) needs to persist across
;;    multiple commands.
;;
;; Key features include:
;; - **Process Re-use**: Minimizes the overhead of spawning new shell
;;   processes for every command.
;; - **Asynchronous Execution**: All commands run in the background,
;;   keeping Emacs responsive.
;; - **Separate Output Streaming**: Command `stdout` and `stderr` are
;;   provided as two distinct `concur-stream` instances for granular control.
;; - **Robust Error Handling**: Automatically retries commands on worker
;;   crashes, handles command timeouts, and reports errors via promises.
;; - **Session Management**: Guarantees sequential execution within a
;;   dedicated shell session.
;; - **Configurable Pool**: Allows customization of pool size and shell
;;   program.
;;
;; While `concur-shell` is not built directly upon `concur-pool` due to
;; specialized worker management requirements (external shell processes
;; vs. internal Emacs Lisp evaluation), its design draws heavily from
;; `concur-pool`'s robustness patterns, including:
;; - Task queuing and priority dispatch.
;; - Worker lifecycle management (starting, restarting, marking failed).
;; - Timeout enforcement.
;; - Poison-pill task detection.
;; - Graceful pool shutdown.
;; This ensures a consistent and reliable experience across Concur's
;; various asynchronous execution backends.

;;; Code:

(require 'cl-lib)        ; For cl-loop, cl-find-if, etc.
(require 's)             ; For string utilities, e.g., s-blank?
(require 'subr-x)        ; For when-let, string-empty-p
(require 'json)          ; For inter-process communication
(require 'async)         ; For `async-start` and managing background processes
(require 'concur-core)   ; Core Concur promises and future management
(require 'concur-chain)  ; For promise chaining
(require 'concur-lock)   ; For mutexes to protect shared pool state
(require 'concur-queue)  ; For task and waiter queues
(require 'concur-stream) ; For streaming command output
(require 'concur-log)    ; For centralized logging

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customization & Errors

(defcustom concur-shell-pool-size 4
  "The number of persistent shell processes to maintain in the default pool.
This determines the maximum number of concurrent stateless commands."
  :type 'integer
  :group 'concur)

(defcustom concur-shell-program-and-args '("/bin/bash" "-i")
  "Program and arguments to start the persistent shell worker processes.
This should ideally be an interactive shell (`-i`) to prevent it from
exiting after a single command and to support shell-specific features.
It MUST be a shell that supports process substitution (e.g., bash, zsh)."
  :type '(list :tag "Shell Program and Arguments"
               (string :tag "Program")
               (repeat string :tag "Arguments"))
  :group 'concur)

(defcustom concur-shell-max-worker-restart-attempts 3
  "Maximum consecutive restart attempts for a worker process.
If a worker crashes more than this many times in a row, it's marked
as failed and removed from the pool to prevent infinite restart loops."
  :type 'integer
  :group 'concur)

(defcustom concur-shell-command-timeout-default 30.0
  "Default timeout (in seconds) for shell commands.
Commands that exceed this duration will be forcibly terminated and their
promises/streams will be rejected/errored. Set to `nil` for no default
timeout."
  :type '(choice (number :min 0.0 :tag "Seconds")
                 (const :tag "No Timeout" nil))
  :group 'concur)

;; Define custom error types for concur-shell, inheriting from `concur-error`.
(define-error 'concur-shell-error
  "A generic error occurred in the persistent shell pool."
  'concur-error)
(define-error 'concur-shell-command-error
  "A shell command executed in the pool failed with a non-zero exit code."
  'concur-shell-error)
(define-error 'concur-shell-command-timeout-error
  "A shell command in the pool timed out."
  'concur-shell-command-error) ; Sub-type of command error
(define-error 'concur-shell-poison-pill-error
  "A command repeatedly crashed shell workers, indicating a problematic
  command or shell setup."
  'concur-shell-error)
(define-error 'concur-shell-session-error
  "An error occurred within a dedicated shell session."
  'concur-shell-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures

(cl-defstruct (concur-shell-task (:constructor %%make-concur-shell-task))
  "Represents a command to be executed by a shell worker.

  Arguments:
  - `id` (string): A unique identifier for the task.
  - `command` (string): The shell command string to execute.
  - `cwd` (string or nil): The current working directory for the command.
  - `stdout-stream` (concur-stream): A stream for the command's stdout.
  - `stderr-stream` (concur-stream): A stream for the command's stderr.
  - `error-promise` (concur-promise): A promise that resolves on success
    or rejects on failure.
  - `timeout` (number or nil): Command-specific timeout in seconds.
  - `retries` (integer): Internal counter for task retries.
  - `stderr-buffer` (string): Buffer to accumulate stderr for error messages."
  (id nil :type string)
  (command nil :type string)
  (cwd nil :type (or string null))
  (stdout-stream nil :type (or null (satisfies concur-stream-p)))
  (stderr-stream nil :type (or null (satisfies concur-stream-p)))
  (error-promise nil :type (or null (satisfies concur-promise-p)))
  (timeout nil :type (or number null))
  (retries 0 :type integer)
  (stderr-buffer "" :type string)) ; Used to build rich error messages

(cl-defstruct (concur-shell-worker (:constructor %%make-concur-shell-worker))
  "Represents a single persistent shell worker process in the pool.

  Arguments:
  - `process` (process): The worker's Emacs `async` process object.
  - `id` (integer): A unique identifier for the worker (e.g., 1, 2, 3...).
  - `status` (keyword): The current state of the worker.
  - `current-task` (concur-shell-task or nil): The task being processed.
  - `timeout-timer` (timer or nil): The timeout timer for the current task.
  - `restart-attempts` (integer): Counter for consecutive restarts.
  - `reserved-p` (boolean): `t` if reserved for a session.
  - `filter-buffer` (string): A buffer for partial lines from the worker."
  (process nil :type (or process null))
  (id nil :type integer)
  (status :idle :type (member :idle :busy :dead :restarting :failed :reserved))
  (current-task nil :type (or null (satisfies concur-shell-task-p)))
  (timeout-timer nil :type (or timer null))
  (restart-attempts 0 :type integer)
  (reserved-p nil :type boolean)
  (filter-buffer "" :type string)) ; For de-multiplexing stdout/stderr

(cl-defstruct (concur-shell-pool (:constructor %%make-concur-shell-pool))
  "Represents a pool of persistent shell processes.

  Arguments:
  - `name` (string): A unique or descriptive name for the pool instance.
  - `workers` (list): A list of `concur-shell-worker` structs.
  - `lock` (concur-lock): A mutex protecting the pool's shared state.
  - `task-queue` (concur-queue): Queue for stateless commands.
  - `waiter-queue` (concur-queue): Queue for sessions awaiting a worker.
  - `shutdown-p` (boolean): `t` if the pool is shutting down."
  (name nil :type (or string null))
  (workers nil :type (or null (list (satisfies concur-shell-worker-p))))
  (lock nil :type (or null (satisfies concur-lock-p)))
  (task-queue nil :type (or null (satisfies concur-queue-p)))
  (waiter-queue nil :type (or null (satisfies concur-queue-p)))
  (shutdown-p nil :type boolean))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Global Default Shell Pool Management

(defvar concur--default-shell-pool nil
  "The global, default instance of the persistent shell pool.")

(defvar concur--default-shell-pool-init-lock
  (concur:make-lock "concur-default-shell-pool-init-lock")
  "A lock to protect the one-time initialization of the default pool.")

(defun concur--shell-pool-create-if-needed ()
  "Internal helper to create the default pool under a lock.
This function contains the macro call `concur:with-mutex!` and is
called by `concur-shell-pool-get-default` to avoid eager
macro-expansion issues during byte-compilation."
  (concur:with-mutex! concur--default-shell-pool-init-lock
    (unless concur--default-shell-pool
      (setq concur--default-shell-pool (concur-shell-pool-create))
      (add-hook 'kill-emacs-hook #'concur-shell-pool-shutdown-default-pool))))

(defun concur-shell-pool-get-default ()
  "Return the default shell pool, creating and initializing it if necessary.
This function is thread-safe and ensures the pool is a singleton."
  (unless concur--default-shell-pool
    (concur--shell-pool-create-if-needed))
  concur--default-shell-pool)

(defun concur-shell-pool-shutdown-default-pool ()
  "Shut down the default shell pool gracefully when Emacs exits."
  (interactive)
  (when concur--default-shell-pool
    (concur-shell-pool-shutdown! concur--default-shell-pool)
    (setq concur--default-shell-pool nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Worker and Task Execution Logic

(defun concur--shell-process-finished-command (worker task exit-code)
  "Process the result of a finished command, settling its promise and streams."
  (let ((stdout-stream (concur-shell-task-stdout-stream task))
        (stderr-stream (concur-shell-task-stderr-stream task))
        (error-promise (concur-shell-task-error-promise task)))

    ;; Close both streams regardless of outcome.
    (when stdout-stream (concur:stream-close stdout-stream))
    (when stderr-stream (concur:stream-close stderr-stream))

    (if (= exit-code 0)
        ;; Command Succeeded: Resolve the promise.
        (concur:resolve error-promise t)
      ;; Command Failed: Reject the promise with a detailed error.
      (let* ((cmd-snippet (s-truncate 80 (concur-shell-task-command task)))
             (stderr-output (s-trim (concur-shell-task-stderr-buffer task)))
             (msg (format "Command '%s' failed with exit code %d."
                          cmd-snippet exit-code))
             (err (concur:make-error
                   :type 'concur-shell-command-error
                   :message msg
                   :exit-code exit-code
                   :stderr stderr-output
                   :cmd (concur-shell-task-command task))))
        (concur:reject error-promise err)))))

(defun concur--shell-worker-script-form ()
  "Generate the Emacs Lisp code that a background `async` worker will execute.
This script manages an internal shell process, sending commands, and
multiplexing stdout/stderr back to the parent."
  `(lambda ()
     (require 'json)
     (let ((load-path ,load-path)
           (default-directory ,default-directory))
       (let ((shell-proc (apply #'start-process "concur-internal-shell"
                                (current-buffer)
                                concur-shell-program-and-args)))
         (set-process-coding-system shell-proc 'utf-8 'utf-8)
         (set-process-query-on-exit-flag shell-proc nil)
         ;; Main loop: read commands, execute, send multiplexed results.
         (while t
           (let* ((json-string (read-line))
                  (task-data (json-read-from-string json-string))
                  (command (cdr (assoc 'command task-data)))
                  (cwd (cdr (assoc 'cwd task-data)))
                  (full-command (if cwd
                                    (format "cd %s && (%s)"
                                            (shell-quote-argument cwd)
                                            command)
                                  (format "(%s)" command)))
                  ;; Multiplex stdout with "O:" prefix and stderr with "E:".
                  ;; This relies on a shell with process substitution (bash, zsh),
                  ;; which runs two sub-processes to pipe stdout/stderr.
                  (multiplex-command
                   (format "{ %s; } 1> >(while IFS= read -r line; do echo \"O:$line\"; done) 2> >(while IFS= read -r line; do echo \"E:$line\"; done)"
                           full-command))
                  ;; Send exit code with "X:" prefix. This is printed after
                  ;; both stdout and stderr pipes have closed.
                  (final-command (format "%s; echo \"X:$?\";\n"
                                         multiplex-command)))
             (process-send-string shell-proc final-command)
             ;; The parent's filter will process the multiplexed output.
             ;; We only need to wait for any output to be generated.
             (accept-process-output shell-proc)))))))

(defun concur--shell-filter (worker chunk)
  "Filter for a worker process. De-multiplexes stdout/stderr and exit code."
  (let* ((pool (concur-shell-pool-get-default))
         (task (concur-shell-worker-current-task worker))
         (stdout-s (when task (concur-shell-task-stdout-stream task)))
         (stderr-s (when task (concur-shell-task-stderr-stream task))))

    ;; Append new chunk to the worker's buffer and process whole lines.
    (setf (concur-shell-worker-filter-buffer worker)
          (concat (concur-shell-worker-filter-buffer worker) chunk))

    ;; Process all complete lines in the buffer.
    (while (string-match "\n" (concur-shell-worker-filter-buffer worker))
      (let* ((line (substring (concur-shell-worker-filter-buffer worker) 0 (match-beginning 0)))
             (remaining-buffer (substring (concur-shell-worker-filter-buffer worker) (match-end 0)))
             (prefix (when (> (length line) 1) (substring line 0 2)))
             (content (when (> (length line) 2) (substring line 2))))

        ;; Consume the processed line from the buffer.
        (setf (concur-shell-worker-filter-buffer worker) remaining-buffer)

        (cond
         ;; Handle stdout line: Write to the stdout stream.
         ((equal prefix "O:")
          (when stdout-s (concur:stream-write stdout-s (concat content "\n"))))

         ;; Handle stderr line: Write to stderr stream and buffer for error reporting.
         ((equal prefix "E:")
          (when stderr-s (concur:stream-write stderr-s (concat content "\n")))
          (when task (setf (concur-shell-task-stderr-buffer task)
                           (concat (concur-shell-task-stderr-buffer task) content "\n"))))

         ;; Handle exit code line: This signifies command completion.
         ((equal prefix "X:")
          (when task
            (let ((exit-code (string-to-number content)))
              (when-let (timer (concur-shell-worker-timeout-timer worker))
                (cancel-timer timer)
                (setf (concur-shell-worker-timeout-timer worker) nil))
              (concur--shell-process-finished-command worker task exit-code)
              ;; Release the worker back to the pool.
              (concur:with-mutex! (concur-shell-pool-lock pool)
                (setf (concur-shell-worker-current-task worker) nil)
                (setf (concur-shell-worker-restart-attempts worker) 0) ; Reset on success
                (if (concur-shell-worker-reserved-p worker)
                    (setf (concur-shell-worker-status worker) :reserved)
                  (concur--pool-release-worker pool worker))))))

         ;; Handle other lines (e.g., shell prompts from -i) by ignoring them.
         (t (concur--log :debug nil "Worker %d sent un-prefixed line, ignoring: %s"
                         (concur-shell-worker-id worker) line)))))))

(defun concur--shell-handle-command-timeout (worker task)
  "Handles a command timeout by killing the worker and rejecting the promise."
  (concur--log :warn nil "Command '%s' (Worker %d) timed out."
               (s-truncate 40 (concur-shell-task-command task))
               (concur-shell-worker-id worker))
  (when (process-live-p (concur-shell-worker-process worker))
    (kill-process (concur-shell-worker-process worker)))
  (when (concur:pending-p (concur-shell-task-error-promise task))
    (let ((err (concur:make-error :type 'concur-shell-command-timeout-error
                                  :message "Shell command timed out.")))
      (concur:reject (concur-shell-task-error-promise task) err)
      (when-let (stream (concur-shell-task-stdout-stream task))
        (concur:stream-error stream err))
      (when-let (stream (concur-shell-task-stderr-stream task))
        (concur:stream-error stream err)))))

(defun concur--shell-handle-crashed-task (worker task)
  "Handle the task that was running on a worker when it crashed."
  (cl-incf (concur-shell-task-retries task))
  (let* ((pool (concur-shell-pool-get-default))
         (retries (concur-shell-task-retries task))
         (max-retries concur-shell-max-worker-restart-attempts))
    (concur--log :warn nil "Worker %d crashed. Retrying task '%s' (Attempt %d/%d)."
                 (concur-shell-worker-id worker)
                 (s-truncate 40 (concur-shell-task-command task))
                 retries max-retries)
    (if (> retries max-retries)
        (let* ((cmd-snippet (s-truncate 40 (concur-shell-task-command task)))
               (msg (format "Command '%s' repeatedly crashed workers (%d attempts)."
                            cmd-snippet max-retries))
               (err (concur:make-error :type 'concur-shell-poison-pill-error
                                       :message msg)))
          (concur--log :error nil "Task '%s' marked as poison-pill." cmd-snippet)
          (when-let (p (concur-shell-task-error-promise task)) (concur:reject p err))
          (when-let (s (concur-shell-task-stdout-stream task)) (concur:stream-error s err))
          (when-let (s (concur-shell-task-stderr-stream task)) (concur:stream-error s err)))
      ;; Re-enqueue the task for another worker to pick up.
      (unless (concur-shell-worker-reserved-p worker)
        (concur:with-mutex! (concur-shell-pool-lock pool)
          (concur-queue-enqueue (concur-shell-pool-task-queue pool) task))))))

(defun concur--shell-sentinel (worker event)
  "The sentinel for a worker process. Handles unexpected termination."
  (concur--log :warn nil "Shell worker %d sentinel triggered: %s"
               (concur-shell-worker-id worker) event)
  (let ((pool (concur-shell-pool-get-default)))
    (when-let (task (concur-shell-worker-current-task worker))
      (concur--shell-handle-crashed-task worker task))
    (concur:with-mutex! (concur-shell-pool-lock pool)
      (setf (concur-shell-worker-status worker) :dead)
      (setf (concur-shell-worker-current-task worker) nil)
      (when-let (timer (concur-shell-worker-timeout-timer worker))
        (cancel-timer timer)
        (setf (concur-shell-worker-timeout-timer worker) nil))

      (unless (concur-shell-pool-shutdown-p pool)
        (cl-incf (concur-shell-worker-restart-attempts worker))
        (if (> (concur-shell-worker-restart-attempts worker)
               concur-shell-max-worker-restart-attempts)
            (progn
              (setf (concur-shell-worker-status worker) :failed)
              (concur--log :error nil "Shell worker %d permanently failed."
                           (concur-shell-worker-id worker)))
          (setf (concur-shell-worker-status worker) :restarting)
          (concur--log :info nil "Restarting shell worker %d (Attempt %d)."
                       (concur-shell-worker-id worker)
                       (concur-shell-worker-restart-attempts worker))
          (setf (concur-shell-worker-process worker)
                (concur--shell-start-worker worker pool))))
      (concur--shell-dispatch-next-task pool))))

(defun concur--shell-start-worker (worker pool-instance)
  "Create and start a single `async` worker process."
  (concur--log :info nil "Starting shell worker %d..."
               (concur-shell-worker-id worker))
  (condition-case err
      (let ((proc (async-start (concur--shell-worker-script-form) nil)))
        (set-process-filter proc (lambda (_p c) (concur--shell-filter worker c)))
        (set-process-sentinel proc (lambda (_p e) (concur--shell-sentinel worker e)))
        (set-process-coding-system proc 'utf-8 'utf-8)
        (set-process-query-on-exit-flag proc nil)
        (setf (concur-shell-worker-status worker) :idle)
        proc)
    (error
     (concur--log :error nil "Failed to start shell worker %d: %S"
                  (concur-shell-worker-id worker) err)
     (setf (concur-shell-worker-status worker) :failed)
     nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Pool and Dispatch Management

(defun concur-shell-pool-create ()
  "Create and start a new persistent shell pool."
  (concur--log :info nil "Creating new shell pool with %d workers."
               concur-shell-pool-size)
  (let ((new-pool (%%make-concur-shell-pool
                   :name (format "shell-pool-%S" (gensym "shell-pool"))
                   :lock (concur:make-lock "shell-pool-lock")
                   :task-queue (concur-queue-create)
                   :waiter-queue (concur-queue-create)
                   :shutdown-p nil)))
    (setf (concur-shell-pool-workers new-pool)
          (cl-loop for i from 1 to concur-shell-pool-size
                   collect
                   (let ((worker (%%make-concur-shell-worker :id i :status :idle)))
                     (setf (concur-shell-worker-process worker)
                           (concur--shell-start-worker worker new-pool))
                     worker)))
    new-pool))

(defun concur--pool-get-idle-worker (pool-instance)
  "Find an idle, non-reserved worker from the pool.
Caller must hold the pool's lock."
  (cl-find-if (lambda (w) (and (eq (concur-shell-worker-status w) :idle)
                               (not (concur-shell-worker-reserved-p w))))
              (concur-shell-pool-workers pool-instance)))

(defun concur--pool-release-worker (pool-instance worker)
  "Release a worker back to the pool, making it available.
Caller must hold the pool's lock."
  (setf (concur-shell-worker-status worker) :idle)
  (setf (concur-shell-worker-reserved-p worker) nil)
  (setf (concur-shell-worker-current-task worker) nil)
  (concur--shell-dispatch-next-task pool-instance))

(defun concur--shell-dispatch-next-task (pool-instance)
  "Find an idle worker and dispatch the next task or waiting session.
This function MUST be called from within the pool's lock."
  (cl-block concur--shell-dispatch-next-task
    (when (concur-shell-pool-shutdown-p pool-instance)
      (cl-return-from concur--shell-dispatch-next-task nil))

    ;; Higher priority for waiting sessions
    (if-let ((waiter (concur-queue-dequeue
                      (concur-shell-pool-waiter-queue pool-instance))))
        (if-let ((worker (concur--pool-get-idle-worker pool-instance)))
            (funcall (car waiter) worker) ; Resolve waiter's promise
          (concur-queue-enqueue (concur-shell-pool-waiter-queue pool-instance)
                                waiter)) ; No worker, re-queue
      ;; Dispatch a regular task if no sessions are waiting
      (unless (concur-queue-empty-p (concur-shell-pool-task-queue pool-instance))
        (when-let ((worker (concur--pool-get-idle-worker pool-instance)))
          (let* ((task (concur-queue-dequeue
                        (concur-shell-pool-task-queue pool-instance)))
                (json (json-serialize `((command . ,(concur-shell-task-command task))
                                        (cwd . ,(concur-shell-task-cwd task))))))
            (setf (concur-shell-worker-status worker) :busy)
            (setf (concur-shell-worker-current-task worker) task)
            (when-let (cmd-timeout (or (concur-shell-task-timeout task)
                                      concur-shell-command-timeout-default))
              (setf (concur-shell-worker-timeout-timer worker)
                    (run-at-time cmd-timeout nil
                                #'concur--shell-handle-command-timeout
                                worker task)))
            (process-send-string (concur-shell-worker-process worker)
                                (concat json "\n"))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(cl-defun concur:shell-submit-command (command &key cwd timeout)
  "Submit a single COMMAND to the persistent shell pool asynchronously.

  The command runs on the next available idle worker.

  Arguments:
  - `COMMAND` (string): The shell command string to execute.
  - `CWD` (string, optional): The current working directory for the command.
  - `TIMEOUT` (number, optional): A command-specific timeout in seconds.

  Returns:
  - (list): A three-element list: `(STDOUT-STREAM STDERR-STREAM ERROR-PROMISE)`
    - `STDOUT-STREAM`: A `concur-stream` for the command's standard output.
    - `STDERR-STREAM`: A `concur-stream` for the command's standard error.
    - `ERROR-PROMISE`: A `concur-promise` that resolves with `t` on success or
      rejects with a `concur-shell-error` on failure."
  (let ((stdout-stream (concur:stream-create))
        (stderr-stream (concur:stream-create))
        (error-promise (concur:make-promise)))
    (concur:with-executor (lambda (resolve _reject)
      (let ((pool (concur-shell-pool-get-default)))
        (concur:with-mutex! (concur-shell-pool-lock pool)
          (let ((task (%%make-concur-shell-task
                       :id (format "shell-task-%s" (gensym "task"))
                       :command command :cwd cwd :timeout timeout
                       :stdout-stream stdout-stream
                       :stderr-stream stderr-stream
                       :error-promise error-promise)))
            (concur-queue-enqueue (concur-shell-pool-task-queue pool) task)
            (concur--shell-dispatch-next-task pool)
            (funcall resolve (list stdout-stream stderr-stream error-promise)))))))))

(cl-defun concur--shell-make-session-runner (worker pool-instance)
  "Create the command-running lambda for a `concur:shell-session`."
  (lambda (command &key cwd timeout)
    (when (or (not (concur-shell-worker-process worker))
              (not (process-live-p (concur-shell-worker-process worker)))
              (not (eq (concur-shell-worker-status worker) :reserved)))
      (user-error "Concur-shell: Session worker is not active or reserved."))

    (let ((stdout-stream (concur:stream-create))
          (stderr-stream (concur:stream-create))
          (command-promise (concur:make-promise)))
      (concur:with-mutex! (concur-shell-pool-lock pool-instance)
        (let* ((task (%%make-concur-shell-task
                      :id (format "session-cmd-%s" (gensym "session-cmd"))
                      :command command :cwd cwd :timeout timeout
                      :stdout-stream stdout-stream
                      :stderr-stream stderr-stream
                      :error-promise command-promise))
               (json (json-serialize `((command . ,command) (cwd . ,cwd)))))
          (setf (concur-shell-worker-status worker) :busy)
          (setf (concur-shell-worker-current-task worker) task)
          (when-let (cmd-timeout (or timeout concur-shell-command-timeout-default))
            (setf (concur-shell-worker-timeout-timer worker)
                  (run-at-time cmd-timeout nil #'concur--shell-handle-command-timeout
                               worker task)))
          (process-send-string (concur-shell-worker-process worker)
                               (concat json "\n"))))
      (list stdout-stream stderr-stream command-promise))))

;;;###autoload
(defmacro concur:shell-session ((session-var) &rest body)
  "Reserve a single shell worker for a sequence of stateful commands.

  `SESSION-VAR` is bound to a runner function `(lambda (cmd &key cwd timeout))`
  that returns `(list stdout-stream stderr-stream promise)`. Commands run via
  this runner are guaranteed to execute sequentially on the same shell process.

  Arguments:
  - `SESSION-VAR` (symbol): A variable bound to the session's runner function.
  - `BODY` (forms): The code to execute within the shell session.

  Returns:
  - (concur-promise): A promise that resolves with the result of `BODY` or
    rejects on failure."
  (declare (indent 1) (debug t))
  `(let ((pool (concur-shell-pool-get-default))
         (reserved-worker nil))
     (concur:chain
         ;; Step 1: Acquire a worker.
         (concur:with-executor (lambda (resolve reject)
           (concur:with-mutex! (concur-shell-pool-lock pool)
             (if-let ((worker (concur--pool-get-idle-worker pool)))
                 (progn
                   (setf (concur-shell-worker-status worker) :reserved)
                   (setf (concur-shell-worker-reserved-p worker) t)
                   (funcall resolve worker))
               ;; No worker available, queue a waiter to be resolved later.
               (concur-queue-enqueue (concur-shell-pool-waiter-queue pool)
                                     (cons resolve reject))))))
       ;; Step 2: Run session body with the acquired worker.
       (lambda (worker-acquired)
         (setq reserved-worker worker-acquired)
         (let ((,session-var (concur--shell-make-session-runner
                              reserved-worker pool)))
           ;; The unwind-protect is critical to ensure the worker is ALWAYS
           ;; released, even if the body of the session errors out.
           (unwind-protect (progn ,@body)
             (concur:with-mutex! (concur-shell-pool-lock pool)
               (concur--pool-release-worker pool reserved-worker))))))))

;;;###autoload
(cl-defun concur:shell-pool-shutdown! (&optional pool)
  "Gracefully shut down a worker POOL."
  (interactive)
  (let ((p (or pool (and (boundp 'concur--default-shell-pool)
                         concur--default-shell-pool))))
    (unless p
      (user-error "Concur-shell: No pool to shut down."))
    (concur--log :info nil "Shutting down pool %S..." (concur-shell-pool-name p))
    (concur:with-mutex! (concur-shell-pool-lock p)
      (unless (concur-shell-pool-shutdown-p p)
        (setf (concur-shell-pool-shutdown-p p) t)
        (dolist (worker (concur-shell-pool-workers p))
          (when-let (proc (concur-shell-worker-process worker))
            (when (process-live-p proc)
              (when-let (task (concur-shell-worker-current-task worker))
                (concur:reject (concur-shell-task-error-promise task)
                               (concur:make-error :type 'concur-shell-error
                                                  :message "Pool is shutting down.")))
              (delete-process proc))))
        (while-let ((task (concur-queue-dequeue (concur-shell-pool-task-queue p))))
          (concur:reject (concur-shell-task-error-promise task)
                         (concur:make-error :type 'concur-shell-error
                                            :message "Pool is shutting down.")))
        (setf (concur-shell-pool-workers p) nil)
        (concur--log :info nil "Pool %S shut down." (concur-shell-pool-name p))))))

;;;###autoload
(defun concur:shell-pool-status (&optional pool)
  "Return a snapshot of the POOL's current status.

  Arguments:
  - `POOL` (concur-shell-pool, optional): The pool to inspect.
    Defaults to the global default shell pool.

  Returns:
  - (plist): A property list with pool metrics.
    - `:name`: Name of the pool.
    - `:size`: Total number of workers.
    - `:idle-workers`: Number of idle workers.
    - `:busy-workers`: Number of busy workers.
    - `:reserved-workers`: Number of workers reserved for sessions.
    - `:queued-tasks`: Number of tasks awaiting execution.
    - `:waiting-sessions`: Number of sessions awaiting a worker.
    - `:is-shutdown`: Whether the pool is shutting down.
    - `:failed-workers`: List of IDs of workers marked as failed."
  (interactive)
  (let* ((p (or pool (and (boundp 'concur--default-shell-pool)
                          concur--default-shell-pool))))
    (unless p
      (user-error "Concur-shell: No pool is active to inspect."))
    (concur:with-mutex! (concur-shell-pool-lock p)
      `(:name ,(concur-shell-pool-name p)
        :size ,(length (concur-shell-pool-workers p))
        :idle-workers ,(cl-loop for w in (concur-shell-pool-workers p)
                                when (eq (concur-shell-worker-status w) :idle)
                                count t)
        :busy-workers ,(cl-loop for w in (concur-shell-pool-workers p)
                                when (eq (concur-shell-worker-status w) :busy)
                                count t)
        :reserved-workers ,(cl-loop for w in (concur-shell-pool-workers p)
                                    when (eq (concur-shell-worker-status w) :reserved)
                                    count t)
        :queued-tasks ,(concur-queue-length (concur-shell-pool-task-queue p))
        :waiting-sessions ,(concur-queue-length (concur-shell-pool-waiter-queue p))
        :is-shutdown ,(concur-shell-pool-shutdown-p p)
        :failed-workers ,(cl-loop for w in (concur-shell-pool-workers p)
                                  when (eq (concur-shell-worker-status w) :failed)
                                  collect (concur-shell-worker-id w))))))

(provide 'concur-shell)
;;; concur-shell.el ends here