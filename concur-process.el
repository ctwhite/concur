;;; concur-process.el --- Async Process Execution with Promises -*- lexical-binding: t; -*-

;;; Commentary:
;; This library provides a robust framework for running external commands
;; asynchronously and handling their results with promises.
;;
;; It offers two execution backends:
;;
;; 1. Standard (Default): Spawns a new process for every command. This is
;;    robust and ensures a clean environment for each task, with output
;;    streamed via `concur-stream`.
;;
;; 2. Persistent Shell (`:persistent t`): For high-frequency, low-latency
;;    tasks, this option sends commands to a long-lived background shell
;;    pool (`concur-shell.el`), avoiding process creation overhead and
;;    also streaming output.
;;
;; Building on this, the library provides high-level macros:
;; - `concur:command`: A user-friendly wrapper for common execution patterns.
;; - `concur:pipe!`: For chaining stateful commands, using `concur:shell-session`.
;; - `concur:define-command!`: For defining reusable async command functions.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 's)
(require 'seq)
(require 'subr-x)
(require 'ansi-color)

(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-log)
(require 'concur-shell)
(require 'concur-stream)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors and Data Structures

(define-error 'concur-process-error "Error during process execution." 'concur-error)
(define-error 'concur-process-creation-error "Error creating process."
  'concur-process-error)
(define-error 'concur-process-cancelled "Process was cancelled."
  'concur-process-error)
(define-error 'concur-process-timeout "Process execution timed out."
  'concur-process-error)
(define-error 'concur-pipe-error "Error during pipe execution." 'concur-process-error)
(define-error 'concur-process-exit-error "Process exited with non-zero status."
  'concur-process-error)
(define-error 'concur-process-signal-error "Process killed by signal."
  'concur-process-error)
(define-error 'concur-process-stdin-error "Error sending stdin to process."
  'concur-process-error)
(define-error 'concur-process-stderr-output-error
  "Command produced stderr output." 'concur-process-error)

(cl-defstruct (concur-process-result
               (:constructor make-concur-process-result))
  "Represents the successful result of a process execution.
This object is the resolution value of a promise from `concur:process`.

Fields:
- `cmd` (string): The command that was executed.
- `args` (list): The arguments passed to the command.
- `exit-code` (integer): The final exit code of the process.
- `stdout-stream` (concur-stream): Stream for standard output.
- `stderr-stream` (concur-stream): Stream for standard error."
  cmd args exit-code stdout-stream stderr-stream)

(cl-defstruct (concur-process-state
               (:constructor %%make-concur-process-state))
  "Internal state for managing a process during its execution.
This struct holds all ephemeral data for a running `concur:process` call.

Fields:
- `promise` (concur-promise): The top-level promise to resolve/reject.
- `process` (process): The Emacs process object for the command.
- `command` (string): The base command string being executed.
- `args` (list): Arguments of the command.
- `cwd` (string): Current working directory.
- `env` (alist): Environment variables for the process.
- `stdin-data` (string or nil): Data to be streamed to standard input.
- `stdin-file` (string or nil): Path to a file for streaming stdin.
- `stdin-file-handle` (file-stream or nil): Handle for the stdin file.
- `stdin-send-timer` (timer or nil): Timer for chunked stdin sending.
- `on-stdout-user-cb` (function or nil): User callback for stdout chunks.
- `on-stderr-user-cb` (function or nil): User callback for stderr chunks.
- `stdout-stream` (concur-stream): Stream that receives stdout.
- `stderr-stream` (concur-stream): Stream that receives stderr.
- `die-on-error` (boolean): If non-nil, reject on non-zero exit code.
- `timeout-timer` (timer): Emacs-side timer for command timeout.
- `cancel-token` (concur-cancel-token): Token for external cancellation.
- `stdin-temp-file-path` (string or nil): Path to temp file for stdin data."
  promise process command args cwd env stdin-data stdin-file
  stdin-file-handle stdin-send-timer on-stdout-user-cb
  on-stderr-user-cb stdout-stream stderr-stream die-on-error
  timeout-timer cancel-token stdin-temp-file-path)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: File and Process Cleanup

(defvar concur--deferred-cleanup-lock (concur:make-lock "deferred-cleanup-lock")
  "A lock to protect the list of files pending deletion.")
(defvar concur--deferred-cleanup-timer nil
  "An idle timer that periodically runs the file cleanup task.")
(defvar concur--files-to-delete-deferred '()
  "A list of temporary file paths to be deleted by the cleanup timer.")

(defun concur--delete-file-if-exists (file-path)
  "Delete FILE-PATH if it exists, logging any errors."
  (when (and file-path (file-exists-p file-path))
    (condition-case err
        (delete-file file-path)
      (error
       (concur--log :error nil "Failed to delete temp file %s: %S" file-path err)))))

(defun concur--schedule-file-for-deletion (file)
  "Add a single FILE to a list for deferred deletion. Thread-safe."
  (when file
    (concur:with-mutex! concur--deferred-cleanup-lock
      (push file concur--files-to-delete-deferred)
      (unless (timerp concur--deferred-cleanup-timer)
        (concur--log :debug :deferred "Starting deferred cleanup timer.")
        (setq concur--deferred-cleanup-timer
              (run-with-idle-timer
               5.0 t #'concur--process-deferred-deletions))))))

(defun concur--process-deferred-deletions ()
  "Process the list of files scheduled for deletion via idle timer."
  (concur:with-mutex! concur--deferred-cleanup-lock
    (let ((files-to-process concur--files-to-delete-deferred))
      (setq concur--files-to-delete-deferred '())
      (dolist (file files-to-process) (concur--delete-file-if-exists file)))
    (when (and (null concur--files-to-delete-deferred)
               (timerp concur--deferred-cleanup-timer))
      (concur--log :debug :deferred "Deferred cleanup timer stopped.")
      (cancel-timer concur--deferred-cleanup-timer)
      (setq concur--deferred-cleanup-timer nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Core Process Execution Logic

(defun concur--get-signal-from-event (event-string)
  "Parse a process sentinel EVENT-STRING to extract a signal name."
  (when (string-match "signal-killed-by-\\(SIG[A-Z]+\\)" event-string)
    (match-string 1 event-string)))

(cl-defun concur--reject-process-promise (process-state error-type message
                                          &key cause exit-code signal
                                          process-status)
  "Centralized function to reject a process promise with a rich error object."
  (let* ((promise (concur-process-state-promise process-state))
         (error-obj
          (concur:make-error
           :type error-type :message message :cause cause :promise promise
           :cmd (concur-process-state-command process-state)
           :args (concur-process-state-args process-state)
           :cwd (concur-process-state-cwd process-state)
           :exit-code exit-code :signal signal :process-status process-status
           :async-stack-trace (concur-current-async-stack-string))))
    (concur--log :error (concur-promise-id promise)
                 "Process rejected: %s" (concur:error-message error-obj))
    ;; Ensure streams are errored out as well.
    (let ((stdout (concur-process-state-stdout-stream process-state))
          (stderr (concur-process-state-stderr-stream process-state)))
      (when stdout (concur:stream-error stdout error-obj))
      (when stderr (concur:stream-error stderr error-obj)))
    (concur:reject promise error-obj)))

(cl-defun concur--handle-process-creation-error (promise err &key command args cwd)
  "Handle synchronous errors that occur during `make-process`."
  (let* ((cmd-str (s-join " " (cons command args)))
         (msg (format "Failed to create process for '%s': %s"
                      cmd-str (error-message-string err)))
         (error-obj
          (concur:make-error
           :type 'concur-process-creation-error :message msg :cause err
           :promise promise :cmd command :args args :cwd cwd
           :async-stack-trace (concur-current-async-stack-string))))
    (concur--log :error (concur-promise-id promise)
                 "Process creation failed: %s" msg)
    (concur:reject promise error-obj)))

(defun concur--setup-process-timeout (process-state timeout)
  "Set up a timeout timer that kills the process and rejects the promise."
  (when timeout
    (let* ((promise (concur-process-state-promise process-state))
           (proc (concur-process-state-process process-state))
           (cmd (concur-process-state-command process-state)))
      (setf (concur-process-state-timeout-timer process-state)
            (run-at-time
             timeout nil
             (lambda ()
               (when (process-live-p proc)
                 (kill-process proc)
                 (concur--reject-process-promise
                  process-state 'concur-process-timeout
                  (format "Command '%s' timed out after %Ss." cmd timeout)))))))))

(defun concur--setup-process-cancellation (process-state cancel-token)
  "Set up a cancellation handler that kills the process on token signal."
  (when cancel-token
    (let* ((promise (concur-process-state-promise process-state))
           (proc (concur-process-state-process process-state))
           (cmd (concur-process-state-command process-state)))
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (when (process-live-p proc)
           (kill-process proc)
           (concur--reject-process-promise
            process-state 'concur-process-cancelled
            (format "Command '%s' was cancelled." cmd))))))))

(defun concur--process-filter (process chunk process-state)
  "Process filter to dispatch stdout/stderr chunks to the correct stream."
  (let* ((is-stdout (eq (current-buffer) (process-buffer process)))
         (output-stream (if is-stdout
                           (concur-process-state-stdout-stream process-state)
                         (concur-process-state-stderr-stream process-state)))
         (user-cb (if is-stdout
                      (concur-process-state-on-stdout-user-cb process-state)
                    (concur-process-state-on-stderr-user-cb process-state))))
    ;; Optionally call a user-provided callback for direct chunk access.
    (when user-cb (funcall user-cb chunk))
    ;; Write to the stream, handling backpressure.
    (when output-stream
      (let ((write-promise (concur:stream-write output-stream chunk)))
        (when write-promise ; A promise indicates potential backpressure.
          (concur:then write-promise nil ; Handle potential stream write errors.
                       (lambda (err)
                         (concur--reject-process-promise
                          process-state 'concur-process-error
                          (format "Output stream write failed: %s"
                                  (concur:error-message err))
                          :cause err))))))))

(defun concur--setup-stdin-streaming (process-state)
  "Initializes stdin streaming from a file or from a string via a temp file."
  (let ((stdin-file (concur-process-state-stdin-file process-state))
        (stdin-data (concur-process-state-stdin-data process-state))
        (proc (concur-process-state-process process-state)))
    (cond
     ;; Case 1: Stream stdin from a user-provided file path.
     (stdin-file
      (unless (file-exists-p stdin-file)
        (concur--reject-process-promise
         process-state 'concur-process-stdin-error
         (format "Stdin file does not exist: %s" stdin-file))
        (cl-return-from concur--setup-stdin-streaming))
      (condition-case err
          (let ((handle (open-file stdin-file "r")))
            (setf (concur-process-state-stdin-file-handle process-state) handle)
            (setf (concur-process-state-stdin-send-timer process-state)
                  (run-with-idle-timer
                   0.01 t #'concur--read-from-stdin-file process-state)))
        (error
         (concur--reject-process-promise
          process-state 'concur-process-stdin-error
          (format "Failed to open stdin file %s: %s"
                  stdin-file (error-message-string err))
          :cause err))))

     ;; Case 2: Stream stdin from a string by writing to a temporary file.
     (stdin-data
      (condition-case err
          (let ((temp-file (make-temp-file "concur-stdin-")))
            (with-temp-file temp-file (insert stdin-data))
            (setf (concur-process-state-stdin-temp-file-path process-state)
                  temp-file)
            (setf (concur-process-state-stdin-file process-state) temp-file)
            ;; Recurse to handle it as a file.
            (concur--setup-stdin-streaming process-state))
        (error
         (concur--reject-process-promise
          process-state 'concur-process-stdin-error
          (format "Failed to write stdin data to temp file: %s"
                  (error-message-string err))
          :cause err))))

     ;; Case 3: No stdin specified. Send EOF immediately.
     (t (process-send-eof proc)))))

(defun concur--read-from-stdin-file (process-state)
  "Reads a chunk from the stdin file handle and sends it to the process.
This function is called repeatedly by an idle timer."
  (let* ((proc (concur-process-state-process process-state))
         (handle (concur-process-state-stdin-file-handle process-state))
         (chunk-size 4096)
         chunk)
    (condition-case err
        (progn
          (setq chunk (read-string chunk-size handle))
          (if (or (null chunk) (string-empty-p chunk))
              ;; End of file reached.
              (progn
                (process-send-eof proc)
                ;; Clean up the timer and file handle.
                (when-let (timer (concur-process-state-stdin-send-timer
                                  process-state))
                  (cancel-timer timer)
                  (setf (concur-process-state-stdin-send-timer process-state) nil))
                (when handle
                  (close-stream handle)
                  (setf (concur-process-state-stdin-file-handle process-state)
                        nil)))
            ;; Send the chunk to the process.
            (process-send-string proc chunk)))
      ;; Handle errors during read/send.
      (error
       (concur--reject-process-promise
        process-state 'concur-process-stdin-error
        (format "Failed to send stdin to process: %s" (error-message-string err))
        :cause err)
       (when-let (timer (concur-process-state-stdin-send-timer process-state))
         (cancel-timer timer))))))

(defun concur--cleanup-process-resources (process-state)
  "Clean up timers, file handles, and temp files for a finished process."
  (let ((promise-id (concur-promise-id (concur-process-state-promise process-state))))
    (when-let (timer (concur-process-state-timeout-timer process-state))
      (concur--log :debug promise-id "Cancelling process timeout timer.")
      (cancel-timer timer))
    (when-let (timer (concur-process-state-stdin-send-timer process-state))
      (concur--log :debug promise-id "Cancelling stdin send timer.")
      (cancel-timer timer))
    (when-let (handle (concur-process-state-stdin-file-handle process-state))
      (concur--log :debug promise-id "Closing stdin file handle.")
      (close-stream handle))
    (when-let (file (concur-process-state-stdin-temp-file-path process-state))
      (concur--log :debug promise-id "Scheduling temp file for deletion: %s" file)
      (concur--schedule-file-for-deletion file))))

(defun concur--cleanup-process-buffers (process process-state)
  "Kill the stdout and stderr buffers associated with a process."
  (let ((promise-id (concur-promise-id (concur-process-state-promise process-state))))
    (when-let (buf (process-buffer process))
      (when (buffer-live-p buf)
        (concur--log :debug promise-id "Killing stdout buffer %S." (buffer-name buf))
        (kill-buffer buf)))
    (when-let (buf (process-get process 'concur-stderr-buffer))
      (when (buffer-live-p buf)
        (concur--log :debug promise-id "Killing stderr buffer %S." (buffer-name buf))
        (kill-buffer buf)))))

(defun concur--finalize-process-promise (process-state event)
  "Resolve or reject the process promise based on its final status."
  (let* ((promise (concur-process-state-promise process-state))
         (proc (concur-process-state-process process-state))
         (status (process-status proc))
         (exit-code (process-exit-status proc))
         (cmd (concur-process-state-command process-state))
         (die-on-error (concur-process-state-die-on-error process-state))
         (result (make-concur-process-result
                  :cmd cmd :args (concur-process-state-args process-state)
                  :exit-code exit-code
                  :stdout-stream (concur-process-state-stdout-stream process-state)
                  :stderr-stream (concur-process-state-stderr-stream process-state))))
    (cond
     ;; Case 1: Success (exit code 0).
     ((and (eq status 'exit) (= exit-code 0))
      (concur--log :info (concur-promise-id promise)
                   "Process '%s' finished successfully." cmd)
      (concur:resolve promise result))

     ;; Case 2: Failure with `die-on-error` enabled.
     ((and (eq status 'exit) (/= exit-code 0) die-on-error)
      (concur--reject-process-promise
       process-state 'concur-process-exit-error
       (format "Command '%s' failed with exit code %d" cmd exit-code)
       :exit-code exit-code :process-status status))

     ;; Case 3: Failure without `die-on-error` (resolves with non-zero code).
     ((and (eq status 'exit) (/= exit-code 0))
      (concur--log :info (concur-promise-id promise)
                   "Process '%s' finished with non-zero exit code %d."
                   cmd exit-code)
      (concur:resolve promise result))

     ;; Case 4: Process was killed by a signal.
     ((eq status 'signal)
      (let ((signal (concur--get-signal-from-event event)))
        (concur--reject-process-promise
         process-state 'concur-process-signal-error
         (format "Command '%s' killed by signal %s" cmd signal)
         :signal signal :process-status status)))

     ;; Case 5: Any other unexpected termination.
     (t
      (concur--reject-process-promise
       process-state 'concur-process-error
       (format "Process '%s' terminated unexpectedly: %s" cmd event)
       :cause event :process-status status)))))

(defun concur--process-sentinel (process event)
  "Process sentinel. Manages cleanup and finalizes the promise upon termination."
  (when (memq (process-status process) '(exit signal finished))
    (let* ((process-state (process-get process 'concur-process-state))
           (promise (concur-process-state-promise process-state))
           (stdout-stream (concur-process-state-stdout-stream process-state))
           (stderr-stream (concur-process-state-stderr-stream process-state)))

      (concur--log :debug (concur-promise-id promise)
                   "Process sentinel fired for %S (event: '%s')"
                   (process-name process) event)

      ;; Perform all cleanup tasks for timers, files, and buffers.
      (concur--cleanup-process-resources process-state)
      (concur--cleanup-process-buffers process process-state)

      ;; Close output streams to signal the end of data. This resolves the
      ;; promises returned by `concur:stream-drain`.
      (when stdout-stream (concur:stream-close stdout-stream))
      (when stderr-stream (concur:stream-close stderr-stream))

      ;; Finalize the main promise if it's still pending.
      (when (concur:pending-p promise)
        (concur--finalize-process-promise process-state event)))))

(defun concur--spawn-standard-process (promise plist)
  "Create, configure, and run a standard Emacs process for `concur:process`.
This function encapsulates the setup logic for the non-persistent backend."
  (let* ((command (plist-get plist :command))
         (args (plist-get plist :args))
         (cwd (or (plist-get plist :cwd) default-directory))
         ;; Create the state object that tracks the process lifecycle.
         (process-state
          (%%make-concur-process-state
           :promise promise :command command :args args :cwd cwd
           :env (plist-get plist :env)
           :stdin-data (plist-get plist :stdin)
           :stdin-file (plist-get plist :stdin-file)
           :on-stdout-user-cb (plist-get plist :on-stdout)
           :on-stderr-user-cb (plist-get plist :on-stderr)
           :stdout-stream (concur:stream-create)
           :stderr-stream (concur:stream-create)
           :die-on-error (plist-get plist :die-on-error)
           :cancel-token (plist-get plist :cancel-token))))
    (condition-case err
        (let* ((proc-env (if-let (env (concur-process-state-env process-state))
                             (append (--map (format "%s=%s" (car it) (cdr it)) env)
                                     process-environment)
                           process-environment))
               (proc (make-process
                      :name (format "concur-%s" (file-name-nondirectory command))
                      :command (cons command (or args '()))
                      :buffer (generate-new-buffer "*concur-stdout*")
                      :stderr (generate-new-buffer "*concur-stderr*")
                      :sentinel #'concur--process-sentinel
                      :filter (lambda (p c)
                                (concur--process-filter p c process-state))
                      :noquery t :connection-type 'pipe :coding-system 'utf-8
                      :current-directory cwd
                      :environment proc-env)))
          ;; Link state and promise to the process object for access in callbacks.
          (process-put proc 'concur-process-state process-state)
          (setf (concur-process-state-process process-state) proc)
          (setf (concur-promise-proc promise) proc)
          ;; Setup I/O and lifecycle handlers.
          (concur--setup-stdin-streaming process-state)
          (concur--setup-process-timeout process-state (plist-get plist :timeout))
          (concur--setup-process-cancellation
           process-state (plist-get plist :cancel-token)))
      ;; If `make-process` fails synchronously, handle the error.
      (error
       (concur--handle-process-creation-error
        promise err :command command :args args :cwd cwd)))))

;;;###autoload
(cl-defun concur:process (&rest plist)
  "Run a command asynchronously, returning a promise for the result.
This is the core process execution function. It supports two backends:
standard (default) and persistent shell (`:persistent t`).

Arguments:
- `PLIST` (plist): A property list of options:
  - `:command` (string or list): The command and its initial arguments.
  - `:args` (list, optional): Additional arguments to append.
  - `:cwd` (string, optional): Working directory. Defaults to `default-directory`.
  - `:env` (alist, optional): Environment variables, e.g., `'((\"VAR\" . \"val\"))`.
  - `:stdin` (string, optional): Data to send to standard input.
  - `:stdin-file` (string, optional): Path to a file to stream to stdin.
  - `:on-stdout` (function, optional): Callback `(lambda (chunk))` for stdout.
  - `:on-stderr` (function, optional): Callback `(lambda (chunk))` for stderr.
  - `:persistent` (boolean, optional): If t, use persistent shell backend.
  - `:timeout` (number, optional): Timeout in seconds.
  - `:cancel-token` (concur-cancel-token, optional): For cancellation.
  - `:die-on-error` (boolean, optional): If t, reject if exit code is non-zero.
  - `:mode` (symbol, optional): Promise concurrency mode (default `:async`).

Returns:
  (concur-promise) A promise that resolves with a `concur-process-result`
  struct on completion or rejects with a `concur-error` on failure."
  (let* ((command (plist-get plist :command))
         (args (plist-get plist :args))
         (cmd-str (s-join " " (cons command args)))
         (use-persistent (plist-get plist :persistent))
         (promise (concur:make-promise
                   :cancel-token (plist-get plist :cancel-token)
                   :mode (or (plist-get plist :mode) :async))))

    (concur--log :info (concur-promise-id promise)
                 "concur:process for '%s' (persistent: %S)"
                 cmd-str use-persistent)

    (if use-persistent
        ;; === Persistent Shell Backend ===
        (let ((full-command
               (s-join " " (--map (shell-quote-argument it) (cons command args)))))
          (concur:chain
              (concur:shell-submit-command full-command
                                           :cwd (plist-get plist :cwd)
                                           :timeout (plist-get plist :timeout))
            (lambda (shell-result)
              (let* ((output-stream (car shell-result))
                     (error-promise (cdr shell-result)))
                ;; Chain the shell's error promise to our main promise.
                (concur:then
                 error-promise
                 (lambda (_)
                   (concur:resolve promise
                                   (make-concur-process-result
                                    :cmd command :args args :exit-code 0
                                    :stdout-stream output-stream
                                    :stderr-stream (concur:stream-create))))
                 (lambda (err) (concur:reject promise err)))))))

      ;; === Standard Process Backend ===
      (concur--spawn-standard-process promise plist))
    promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: High-level Command Macros

(defun concur--parse-command-and-keys (command-form keys)
  "Internal helper to parse command forms and merge keyword arguments.
Handles string vs. list commands and aliases like `:dir` for `:cwd`."
  (let (cmd cmd-args)
    (if (stringp command-form)
        (let ((parts (s-split " " command-form t)))
          (setq cmd (car parts) cmd-args (cdr parts)))
      (setq cmd (car command-form) cmd-args (cdr command-form)))
    (let ((user-args (plist-get keys :args))
          (final-cwd (or (plist-get keys :cwd) (plist-get keys :dir)))
          (other-keys (cl-loop for (k v) on keys by #'cddr
                               unless (memq k '(:args :cwd :dir))
                               nconc (list k v))))
      (list cmd (append cmd-args user-args)
            (if final-cwd (append `(:cwd ,final-cwd) other-keys)
              other-keys)))))

(defun concur--handle-command-result (process-promise)
  "Handle `concur:process` result for `concur:command`.
This function chains promises to check exit code, drain stdout/stderr,
and check for stderr output before resolving with the final stdout string.
It returns a new promise that encapsulates this entire workflow.

Arguments:
- `PROCESS-PROMISE` (concur-promise): The promise from `concur:process`.

Returns:
  (concur-promise) A new promise that resolves with the stdout string
  or rejects with a process error."
  (cl-block concur--handle-command-result
    (concur:chain process-promise
      ;; Step 1: Check exit code and start draining stdout/stderr concurrently.
      (lambda (result)
        (when (/= (concur-process-result-exit-code result) 0)
          (cl-return-from concur--handle-command-result
            (concur:rejected!
             (concur:make-error
              :type 'concur-process-exit-error
              :message (format "Command '%s' failed with exit code %d"
                               (concur-process-result-cmd result)
                               (concur-process-result-exit-code result))
              :exit-code (concur-process-result-exit-code result)))))
        ;; Concurrently drain both streams. `concur:all` returns a promise
        ;; that resolves with a list of the results (drained chunks).
        (concur:all (concur:stream-drain
                     (concur-process-result-stdout-stream result))
                    (concur:stream-drain
                     (concur-process-result-stderr-stream result))))

      ;; Step 2: Check for stderr output and resolve with stdout string.
      (lambda (drained-streams)
        (let* ((stdout-chunks (car drained-streams))
               (stderr-chunks (cadr drained-streams))
               (cmd (concur-process-result-cmd (concur:value process-promise)))
               (stderr-str (s-no-props (s-trim (s-join "" stderr-chunks)))))
          ;; If there was any non-blank stderr, reject the promise.
          (when (not (s-blank? stderr-str))
            (cl-return-from concur--handle-command-result
              (concur:rejected!
               (concur:make-error
                :type 'concur-process-stderr-output-error
                :message (format "Command '%s' produced stderr: %s"
                                 cmd stderr-str)
                :stderr stderr-str))))
          ;; Success: resolve with the final, combined stdout string.
          (s-no-props (s-join "" stdout-chunks)))))))

;;;###autoload
(defmacro concur:command (command &rest keys)
  "Run a command and return a promise for its stdout string.
This is a high-level wrapper around `concur:process`. It handles common
success/failure cases automatically:
- Rejects if the process exits with a non-zero code.
- Rejects if the process produces any output on stderr.
- Resolves with the complete stdout content as a single string on success.

Arguments:
- `COMMAND` (string or list): The command to run. If a string, it is
  split by spaces. If a list, `car` is command and `cdr` are arguments.
- `KEYS` (plist): Options, same as `concur:process`. Accepts `:dir` as an
  alias for `:cwd`.

Returns:
  (concur-promise) A promise that resolves with the stdout string on success,
  or rejects with a `concur-error` on any failure."
  (declare (indent 1) (debug t))
  `(let* ((parsed-parts (concur--parse-command-and-keys ,command (list ,@keys)))
          (cmd (car parsed-parts))
          (args (cadr parsed-parts))
          (final-keys (caddr parsed-parts))
          ;; Set `die-on-error` to nil because we do custom checks.
          (process-promise (apply #'concur:process :command cmd :args args
                                  :die-on-error nil final-keys)))
     ;; Delegate all result handling to the helper function.
     (concur--handle-command-result process-promise)))

;;;--- Refactored pipe! Helpers ---

(defun concur--chain-pipe-commands (session command-forms)
  "Recursively build a promise chain for `concur:pipe!` commands.
It executes one command, waits for it to succeed, and then recurses
on the rest of the commands, creating a sequential execution chain.

Arguments:
- `SESSION` (function): The active `concur:shell-session` function.
- `COMMAND-FORMS` (list): The remaining command forms to execute.

Returns:
 (concur-promise) A promise that resolves with `t` when the entire chain
 completes, or rejects if any command fails."
  (if (null command-forms)
      (concur:resolved! t) ; Base case: all commands succeeded.
    (let* ((cmd-form (car command-forms))
           (parsed (concur--parse-command-and-keys (car cmd-form) (cdr cmd-form)))
           (cmd-str (s-join " "
                            (cons (shell-quote-argument (car parsed))
                                  (--map (shell-quote-argument it) (cadr parsed)))))
           (cmd-keys (caddr parsed))
           (cwd (plist-get cmd-keys :cwd))
           (timeout (plist-get cmd-keys :timeout)))
      (concur:chain (funcall session cmd-str :cwd cwd :timeout timeout)
        (lambda (result)
          (let ((output-stream (car result))
                (error-promise (cdr result)))
            ;; Drain stream to prevent backpressure stalls, then recurse on success.
            (concur:stream-drain output-stream)
            (concur:then error-promise
                         (lambda (_)
                           (concur--chain-pipe-commands
                            session (cdr command-forms))))))))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands sequentially in the same persistent shell.
Uses `concur:shell-session` to ensure all commands run in the same
stateful environment (same working directory, shell variables, etc.).
If any command in the sequence fails, the entire pipe aborts.

Arguments:
- `COMMAND-FORMS` (list of lists): Each element is a form suitable for
  `concur:command`'s arguments, e.g., `'((\"cd /tmp\") (\"touch file\"))`.

Returns:
  (concur-promise) A promise that resolves with `t` on success of all
  commands, or rejects with a `concur-pipe-error` if any command fails."
  (declare (indent 1) (debug t))
  (unless command-forms (error "concur:pipe! requires at least one command"))
  (let ((session-var (gensym "session")))
    `(concur:shell-session (,session-var)
       (concur--chain-pipe-commands ,session-var (list ,@command-forms)))))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr &rest keys)
  "Define NAME as a function that runs an async command via `concur:command`.
This is a convenient way to create reusable, documented async commands.

Arguments:
- `NAME` (symbol): The name of the function to define.
- `ARGLIST` (list): The argument list for the new function.
- `DOCSTRING` (string): The documentation string for the new function.
- `COMMAND-EXPR` (form): A form that evaluates to the command list/string
  to be executed. It can use variables from the `ARGLIST`.
- `KEYS` (plist): Default options for `concur:command`. Can be overridden
  by passing keyword arguments to the defined function.
  - `:interactive` (form): An interactive spec for the function.

Returns:
  (symbol) The defined function name `NAME`."
  (declare (indent 1) (debug t))
  (let ((interactive-spec (plist-get keys :interactive))
        (default-keys (cl-loop for (k v) on keys by #'cddr
                               unless (eq k :interactive)
                               nconc (list k v)))
        (rest-args (make-symbol "rest-args")))
    `(progn
       (concur--log :debug :macro "Defining async command '%S'." ',name)
       (cl-defun ,name (,@arglist &rest ,rest-args)
         ,docstring
         ,@(when interactive-spec `((interactive ,interactive-spec)))
         (let ((command ,command-expr))
           (apply #'concur:command command (append ,rest-args ',default-keys)))))))

(provide 'concur-process)
;;; concur-process.el ends here