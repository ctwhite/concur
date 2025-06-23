;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
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
;;    streaming both stdout and stderr.
;;
;; Building on this, the library provides high-level macros:
;; - `concur:command`: A user-friendly wrapper for common execution patterns,
;;   resolving with the command's stdout or rejecting with a rich error.
;; - `concur:pipe!`: For chaining stateful commands, using `concur:shell-session`
;;   to ensure sequential execution in the same shell environment.
;; - `concur:define-command!`: For defining reusable async command functions,
;;   wrapping `concur:command` with customizable defaults and arguments.

;;; Code:

(require 'cl-lib)     ; For cl-loop, cl-find-if, etc.
(require 'dash)       ; For --map, --find-if, etc.
(require 's)          ; For string utilities, e.g., s-join, s-trim
(require 'seq)        ; For seq-elt, seq-take
(require 'subr-x)     ; For when-let, string-empty-p, etc.
(require 'ansi-color) ; For stripping ANSI codes from output

(require 'concur-core)   ; Core Concur promises and future management
(require 'concur-chain)  ; For promise chaining
(require 'concur-lock)   ; For mutexes
(require 'concur-log)    ; For logging internal events
(require 'concur-shell)  ; For persistent shell backend
(require 'concur-stream) ; For streaming process output

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Errors and Data Structures

(define-error 'concur-process-error
  "A generic error during external process execution."
  'concur-error)
(define-error 'concur-process-creation-error
  "Failed to create the external process."
  'concur-process-error)
(define-error 'concur-process-cancelled
  "External process was cancelled externally."
  'concur-process-error)
(define-error 'concur-process-timeout
  "External process execution timed out."
  'concur-process-error)
(define-error 'concur-process-exit-error
  "External process exited with a non-zero status code."
  'concur-process-error)
(define-error 'concur-process-signal-error
  "External process was terminated by a signal."
  'concur-process-error)
(define-error 'concur-process-stdin-error
  "An error occurred while sending data to process stdin."
  'concur-process-error)
(define-error 'concur-process-stderr-output-error
  "A command produced output on stderr when it was not expected."
  'concur-process-error)
(define-error 'concur-pipe-error
  "An error occurred during sequential pipe execution."
  'concur-process-error)

(cl-defstruct (concur-process-result
               (:constructor make-concur-process-result))
  "Represents the successful result of an external process execution.
This object is the resolution value of a promise from `concur:process`.

Arguments:
- `cmd` (string): The full command string (executable name) that was run.
- `args` (list): The list of arguments passed to the command.
- `exit-code` (integer): The final exit code of the process.
- `stdout-stream` (concur-stream): The `concur-stream` for standard output.
  This stream is closed when the process finishes.
- `stderr-stream` (concur-stream): The `concur-stream` for standard error.
  This stream is closed when the process finishes."
  (cmd nil :type string)
  (args nil :type list)
  (exit-code nil :type integer)
  (stdout-stream nil :type (or null (satisfies concur-stream-p)))
  (stderr-stream nil :type (or null (satisfies concur-stream-p))))

(cl-defstruct (concur-process-state
               (:constructor %%make-concur-process-state))
  "Internal state for managing an asynchronously executing process.
This struct holds all ephemeral data for a running `concur:process`
call's lifecycle.

Arguments:
- `promise` (concur-promise): The top-level `concur-promise` that will
  be resolved or rejected upon process completion.
- `process` (process): The actual Emacs `process` object for the
  external command. Defaults to `nil` (set after creation).
- `command` (string): The base command string being executed (e.g., \"ls\").
- `args` (list): Arguments for the command (e.g., `(\"-l\" \"/tmp\")`).
- `cwd` (string): The current working directory from which the process
  is launched.
- `env` (alist or nil): Additional environment variables (as an alist)
  to set for the process. Defaults to `nil`.
- `stdin-data` (string or nil): A string containing data to be sent
  to the process's standard input (`stdin`). Defaults to `nil`.
- `stdin-file` (string or nil): A path to a file whose contents will
  be streamed to the process's `stdin`. Defaults to `nil`.
- `stdin-file-handle` (file-stream or nil): An internal file stream handle
  if `stdin-file` is used. Defaults to `nil`.
- `stdin-send-timer` (timer or nil): An internal timer used for chunked
  `stdin` sending when reading from a file. Defaults to `nil`.
- `on-stdout-user-cb` (function or nil): An optional user-provided callback
  `(lambda (chunk))` that is invoked for each chunk of `stdout` received.
- `on-stderr-user-cb` (function or nil): An optional user-provided callback
  `(lambda (chunk))` that is invoked for each chunk of `stderr` received.
- `stdout-stream` (concur-stream): An internal `concur-stream` instance
  that receives `stdout` chunks from the process.
- `stderr-stream` (concur-stream): An internal `concur-stream` instance
  that receives `stderr` chunks from the process.
- `die-on-error` (boolean): If `t`, the `promise` will be rejected if the
  process exits with a non-zero status code. If `nil`, it will resolve
  with the non-zero code. Defaults to `t`.
- `timeout-timer` (timer or nil): The Emacs-side timer object used to
  enforce command-specific timeouts. Defaults to `nil`.
- `cancel-token` (concur-cancel-token or nil): A `concur-cancel-token`
  instance that can be used to externally cancel the running process.
  Defaults to `nil`.
- `stdin-temp-file-path` (string or nil): Internal path to a temporary file
  created when `stdin-data` is used. This file is scheduled for deletion.
  Defaults to `nil`."
  (promise nil :type (satisfies concur-promise-p))
  (process nil :type (or process null))
  (command nil :type string)
  (args nil :type list)
  (cwd nil :type string)
  (env nil :type (or alist null))
  (stdin-data nil :type (or string null))
  (stdin-file nil :type (or string null))
  (stdin-file-handle nil :type (or file-stream null))
  (stdin-send-timer nil :type (or timer null))
  (on-stdout-user-cb nil :type (or function null))
  (on-stderr-user-cb nil :type (or function null))
  (stdout-stream nil :type (or null (satisfies concur-stream-p)))
  (stderr-stream nil :type (or null (satisfies concur-stream-p)))
  (die-on-error t :type boolean)
  (timeout-timer nil :type (or timer null))
  (cancel-token nil :type (or null (satisfies concur-cancel-token-p)))
  (stdin-temp-file-path nil :type (or string null)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: File and Process Cleanup

(defvar concur--deferred-cleanup-lock
  (concur:make-lock "deferred-cleanup-lock")
  "A lock to protect the list of files pending deferred deletion.")
(defvar concur--deferred-cleanup-timer nil
  "An idle timer that periodically runs the file cleanup task.")
(defvar concur--files-to-delete-deferred '()
  "A list of temporary file paths to be deleted by the cleanup timer.")

(defun concur--delete-file-if-exists (file-path)
  "Delete FILE-PATH if it exists, logging any errors.

  Arguments:
  - `file-path` (string): The path to the file to delete.

  Returns:
  - `nil` (side-effect: deletes file or logs error)."
  (when (and file-path (file-exists-p file-path))
    (condition-case err
        (delete-file file-path)
      (error
       (concur--log :error nil "Failed to delete temp file %s: %S" file-path
                    err)))))

(defun concur--schedule-file-for-deletion (file)
  "Add a single FILE to a list for deferred deletion. Thread-safe.
Deletion happens periodically during idle time to avoid blocking.

  Arguments:
  - `file` (string): The path to the file to schedule for deletion.

  Returns:
  - `nil` (side-effect: adds file to queue, starts timer)."
  (when file
    (concur:with-mutex! concur--deferred-cleanup-lock
      (push file concur--files-to-delete-deferred)
      (unless (timerp concur--deferred-cleanup-timer)
        (concur--log :debug :deferred "Starting deferred cleanup timer.")
        (setq concur--deferred-cleanup-timer
              (run-with-idle-timer
               5.0 t #'concur--process-deferred-deletions))))))

(defun concur--process-deferred-deletions ()
  "Process the list of files scheduled for deletion via idle timer.
This function is called by `concur--deferred-cleanup-timer`.

  Returns:
  - `nil` (side-effect: deletes files, stops timer)."
  (concur:with-mutex! concur--deferred-cleanup-lock
    (let ((files-to-process concur--files-to-delete-deferred))
      (setq concur--files-to-delete-deferred '()) ; Clear list for next cycle
      (dolist (file files-to-process) (concur--delete-file-if-exists file)))
    ;; Stop timer if no more files are pending deletion.
    (when (and (null concur--files-to-delete-deferred)
               (timerp concur--deferred-cleanup-timer))
      (concur--log :debug :deferred "Deferred cleanup timer stopped.")
      (cancel-timer concur--deferred-cleanup-timer)
      (setq concur--deferred-cleanup-timer nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Core Process Execution Logic

(defun concur--get-signal-from-event (event-string)
  "Parse a process sentinel EVENT-STRING to extract a signal name.

  Arguments:
  - `event-string` (string): The event string from `process-sentinel`.

  Returns:
  - (string or nil): The signal name (e.g., \"SIGTERM\"), or `nil`."
  (when (string-match "signal-killed-by-\\(SIG[A-Z]+\\)" event-string)
    (match-string 1 event-string)))

(cl-defun concur--reject-process-promise (process-state error-type message
                                          &key cause exit-code signal
                                          process-status)
  "Centralized function to reject a process promise with a rich error object.

  Arguments:
  - `process-state` (concur-process-state): The state object of the process.
  - `error-type` (symbol): The type of error (e.g., `concur-process-exit-error`).
  - `message` (string): A human-readable error message.
  - `:cause` (any, optional): The original error object or reason.
  - `:exit-code` (integer, optional): The process exit code.
  - `:signal` (string, optional): The signal name that killed the process.
  - `:process-status` (symbol, optional): The `process-status` symbol.

  Returns:
  - `nil` (side-effect: rejects promise and errors streams)."
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
  "Handle synchronous errors that occur during `make-process`.

  Arguments:
  - `promise` (concur-promise): The promise to reject.
  - `err` (error): The original Emacs Lisp error.
  - `:command` (string): The command attempted.
  - `:args` (list): The arguments attempted.
  - `:cwd` (string): The working directory.

  Returns:
  - `nil` (side-effect: rejects promise)."
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

(defun concur--finalize-process-promise (process-state event)
  "Finalize the promise for a standard process based on its termination event.
This function is called by the sentinel for the standard (non-persistent)
process backend.

  Arguments:
  - `process-state` (concur-process-state): The state object of the process.
  - `event` (string): The event string from the process sentinel.

  Returns:
  - `nil` (side-effect: resolves or rejects the process promise)."
  (let* ((promise (concur-process-state-promise process-state))
         (proc (concur-process-state-process process-state))
         (die-on-error (concur-process-state-die-on-error process-state))
         (exit-code (process-exit-status proc))
         (signal (concur--get-signal-from-event event)))

    (cond
     ;; Case 1: Process terminated by a signal. Always an error.
     (signal
      (concur--reject-process-promise
       process-state 'concur-process-signal-error
       (format "Command '%s' killed by signal %s"
               (concur-process-state-command process-state) signal)
       :signal signal :process-status (process-status proc)))

     ;; Case 2: Process exited with a non-zero status code.
     ((/= exit-code 0)
      (if die-on-error
          ;; If `die-on-error` is true, reject the promise.
          (concur--reject-process-promise
           process-state 'concur-process-exit-error
           (format "Command '%s' exited with non-zero code %d"
                   (concur-process-state-command process-state) exit-code)
           :exit-code exit-code :process-status (process-status proc))
        ;; Otherwise, resolve successfully with the result struct.
        (concur:resolve promise
                      (make-concur-process-result
                       :cmd (concur-process-state-command process-state)
                       :args (concur-process-state-args process-state)
                       :exit-code exit-code
                       :stdout-stream (concur-process-state-stdout-stream process-state)
                       :stderr-stream (concur-process-state-stderr-stream process-state)))))

     ;; Case 3: Process exited normally with code 0. Always a success.
     (t
      (concur:resolve promise
                    (make-concur-process-result
                     :cmd (concur-process-state-command process-state)
                     :args (concur-process-state-args process-state)
                     :exit-code 0
                     :stdout-stream (concur-process-state-stdout-stream process-state)
                     :stderr-stream (concur-process-state-stderr-stream process-state)))))))

(defun concur--setup-process-timeout (process-state timeout)
  "Set up a timeout timer that kills the process and rejects the promise.

  Arguments:
  - `process-state` (concur-process-state): The state object of the process.
  - `timeout` (number): The timeout duration in seconds.

  Returns:
  - `nil` (side-effect: sets timer)."
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
  "Set up a cancellation handler that kills the process on token signal.

  Arguments:
  - `process-state` (concur-process-state): The state object of the process.
  - `cancel-token` (concur-cancel-token): The cancellation token.

  Returns:
  - `nil` (side-effect: adds cancellation callback)."
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

(defun concur--process-filter (process chunk)
  "Process filter to dispatch stdout/stderr chunks to the correct stream.
This function is called by Emacs when process output is available. It retrieves
the process state from the process's property list.

  Arguments:
  - `process` (process): The Emacs process object.
  - `chunk` (string): The raw output chunk.

  Returns:
  - `nil` (side-effect: writes to streams, calls user callbacks)."
  (when-let ((process-state (process-get process 'concur-process-state)))
    (let* ((is-stdout (eq (current-buffer) (process-buffer process)))
           (output-stream (if is-stdout
                             (concur-process-state-stdout-stream process-state)
                           (concur-process-state-stderr-stream process-state)))
           (user-cb (if is-stdout
                        (concur-process-state-on-stdout-user-cb process-state)
                      (concur-process-state-on-stderr-user-cb process-state))))
      (when user-cb (funcall user-cb chunk))
      (when output-stream
        (let ((write-promise (concur:stream-write output-stream chunk)))
          ;; FIX: Only chain if the write operation returned a promise.
          ;; The value `t` indicates immediate success and requires no
          ;; further action.
          (when (concur-promise-p write-promise)
            (concur:then write-promise nil
                         (lambda (err)
                           (concur--reject-process-promise
                            process-state 'concur-process-error
                            (format "Output stream write failed: %s"
                                    (concur:error-message err))
                            :cause err)))))))))

(defun concur--setup-stdin-streaming (process-state)
  "Initializes stdin streaming from a file or from a string via a temp file.

  Arguments:
  - `process-state` (concur-process-state): The state object for the process.

  Returns:
  - `nil` (side-effect: configures stdin or rejects promise)."
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
This function is called repeatedly by an idle timer.

  Arguments:
  - `process-state` (concur-process-state): The state object of the process.

  Returns:
  - `nil` (side-effect: sends data, manages timer)."
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
                  (setf (concur-process-state-stdin-send-timer process-state)
                        nil)))
            ;; Send the chunk to the process.
            (process-send-string proc chunk)))
      ;; Handle errors during read/send.
      (error
       (concur--reject-process-promise
        process-state 'concur-process-stdin-error
        (format "Failed to send stdin to process: %s"
                (error-message-string err))
        :cause err)
       (when-let (timer (concur-process-state-stdin-send-timer process-state))
         (cancel-timer timer))))))

(defun concur--cleanup-process-resources (process-state)
  "Clean up timers, file handles, and temp files for a finished process.

  Arguments:
  - `process-state` (concur-process-state): The state object of the process.

  Returns:
  - `nil` (side-effect: cleans up resources)."
  (let ((promise-id (concur-promise-id (concur-process-state-promise
                                        process-state))))
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
      (concur--log :debug promise-id "Scheduling temp file for deletion: %s"
                   file)
      (concur--schedule-file-for-deletion file))))

(defun concur--cleanup-process-buffers (process process-state)
  "Kill the stdout and stderr buffers associated with a process.

  Arguments:
  - `process` (process): The Emacs process object.
  - `process-state` (concur-process-state): The state object of the process.

  Returns:
  - `nil` (side-effect: kills buffers)."
  (let ((promise-id (concur-promise-id (concur-process-state-promise
                                        process-state))))
    (when-let (buf (process-buffer process))
      (when (buffer-live-p buf)
        (concur--log :debug promise-id "Killing stdout buffer %S."
                     (buffer-name buf))
        (kill-buffer buf)))
    (when-let (buf (process-get process 'concur-stderr-buffer))
      (when (buffer-live-p buf)
        (concur--log :debug promise-id "Killing stderr buffer %S."
                     (buffer-name buf))
        (kill-buffer buf)))))

(defun concur--process-sentinel (process event)
  "Process sentinel. Manages cleanup and finalizes the promise upon termination.
This function is called by Emacs when the process changes status (e.g., exits).

  Arguments:
  - `process` (process): The Emacs process object.
  - `event` (string): The event string (e.g., \"exited normally with code 0\").

  Returns:
  - `nil` (side-effect: manages lifecycle of process, promises, and streams)."
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

      ;; Close output streams to signal the end of data.
      (when stdout-stream (concur:stream-close stdout-stream))
      (when stderr-stream (concur:stream-close stderr-stream))

      ;; Finalize the main promise if it's still pending.
      (when (concur:pending-p promise)
        (concur--finalize-process-promise process-state event)))))

(defun concur--spawn-standard-process (promise plist)
  "Create, configure, and run a standard Emacs process for `concur:process`.
This function encapsulates the setup logic for the non-persistent backend.

  Arguments:
  - `promise` (concur-promise): The top-level promise for this process.
  - `plist` (plist): The options property list passed to `concur:process`.

  Returns:
  - `nil` (side-effect: spawns process or rejects promise on creation error)."
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
                      :name (format "concur-%s"
                                    (file-name-nondirectory command))
                      :command (cons command (or args '()))
                      :buffer (generate-new-buffer "*concur-stdout*")
                      :stderr (generate-new-buffer "*concur-stderr*")
                      :sentinel #'concur--process-sentinel
                      :filter #'concur--process-filter
                      :noquery t :connection-type 'pipe :coding-system 'utf-8
                      :current-directory cwd
                      :environment proc-env)))
          ;; Link state and promise to the process object for access in callbacks.
          (process-put proc 'concur-process-state process-state)
          (setf (concur-process-state-process process-state) proc)
          (setf (concur-promise-proc promise) proc) ; For cancellation
          ;; Setup I/O and lifecycle handlers.
          (concur--setup-stdin-streaming process-state)
          (concur--setup-process-timeout process-state
                                         (plist-get plist :timeout))
          (concur--setup-process-cancellation
           process-state (plist-get plist :cancel-token)))
      ;; If `make-process` fails synchronously, handle the error.
      (error
       (concur--handle-process-creation-error
        promise err :command command :args args :cwd cwd)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Core Process Execution

;;;###autoload
(defun concur:process (&rest plist)
  "Run a command asynchronously, returning a promise for the result.
This is the core process execution function. It supports two backends:
standard (default) and persistent shell (`:persistent t`).

  Arguments:
  - `PLIST` (plist): A property list of options:
    - `:command` (string or list): The command and its initial arguments.
      If a string, it's split by spaces. If a list, `car` is command and
      `cdr` are arguments.
    - `:args` (list, optional): Additional arguments to append.
    - `:cwd` (string, optional): Working directory. Defaults to
      `default-directory`.
    - `:env` (alist, optional): Environment variables, e.g.,
      `'((\"VAR\" . \"val\"))`.
    - `:stdin` (string, optional): Data to send to standard input.
    - `:stdin-file` (string, optional): Path to a file to stream to stdin.
    - `:on-stdout` (function, optional): Callback `(lambda (chunk))` for
      stdout chunks.
    - `:on-stderr` (function, optional): Callback `(lambda (chunk))` for
      stderr chunks.
    - `:persistent` (boolean, optional): If `t`, use persistent shell backend.
    - `:timeout` (number, optional): Timeout in seconds.
    - `:cancel-token` (concur-cancel-token, optional): For cancellation.
    - `:die-on-error` (boolean, optional): If `t`, reject if exit code is
      non-zero. Defaults to `t`.
    - `:mode` (symbol, optional): Promise concurrency mode (default `:async`).

  Returns:
  - (concur-promise): A promise that resolves with a `concur-process-result`
    struct on completion or rejects with a `concur-error` on failure."
  (let* ((command-val (plist-get plist :command))
         (initial-args (plist-get plist :args))
         (command (if (listp command-val) (car command-val) command-val))
         (args (if (listp command-val) (cdr command-val) initial-args))
         (cmd-str (s-join " " (cons command args)))
         (use-persistent (plist-get plist :persistent))
         (promise (concur:make-promise
                   :cancel-token (plist-get plist :cancel-token)
                   :mode (or (plist-get plist :mode) :async))))

    (concur--log :info (concur-promise-id promise)
                 "concur:process for '%s' (persistent: %S)"
                 cmd-str use-persistent)

    (if use-persistent
        ;; === Persistent Shell Backend (Updated) ===
        (let ((full-command (s-join " " (cons command args))))
          (concur:chain
              (concur:shell-submit-command
               full-command
               :cwd (plist-get plist :cwd)
               :timeout (plist-get plist :timeout))
            (:then (lambda (shell-result)
                     (let* ((stdout-stream (car shell-result))
                            (stderr-stream (cadr shell-result))
                            (error-promise (caddr shell-result)))
                       ;; Chain the shell's error promise to our main promise.
                       (concur:then
                        error-promise
                        ;; On success, resolve with a result containing both streams.
                        (lambda (_)
                          (concur:resolve promise
                                          (make-concur-process-result
                                           :cmd command :args args
                                           :exit-code 0
                                           :stdout-stream stdout-stream
                                           :stderr-stream stderr-stream)))
                        ;; On failure, reject our promise with the shell's error.
                        (lambda (err) (concur:reject promise err))))))))
      ;; === Standard Process Backend ===
      (concur--spawn-standard-process promise plist))
    promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: High-level Command Macros

(defun concur--parse-command-and-keys (command-form keys)
  "Internal helper to parse command forms and merge keyword arguments.
Handles string vs. list commands and aliases like `:dir` for `:cwd`.

  Arguments:
  - `command-form` (string or list): The command as provided to `concur:command`.
  - `keys` (list): The original keyword arguments list.

  Returns:
  - (list): A list `(cmd cmd-args final-keys-plist)`."
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
This function chains promises to check for final exit status and
stderr output, ultimately resolving with the stdout string or
rejecting with an appropriate process error.

  Arguments:
  - `PROCESS-PROMISE` (concur-promise): The promise from `concur:process`.

  Returns:
  - (concur-promise): A new promise that resolves with the stdout string
    or rejects with a process error."
  (cl-block concur--handle-command-result
    (concur:chain process-promise
      ;; Step 1: Drain stdout/stderr streams and get process result info.
      (lambda (proc-result)
        (concur:all (concur:stream-drain
                     (concur-process-result-stdout-stream proc-result))
                    (concur:stream-drain
                     (concur-process-result-stderr-stream proc-result))
                    (concur:resolved-future proc-result))) ; Pass result through

      ;; Step 2: Process drained outputs and finalize.
      (lambda (drained-info)
        (let* ((stdout-chunks (seq-elt drained-info 0))
               (stderr-chunks (seq-elt drained-info 1))
               (proc-result (seq-elt drained-info 2))
               (cmd (concur-process-result-cmd proc-result))
               (exit-code (concur-process-result-exit-code proc-result))
               (stdout-str (ansi-color-strip (s-trim (s-join "" stdout-chunks)))) ; Strip ANSI
               (stderr-str (ansi-color-strip (s-trim (s-join "" stderr-chunks))))) ; Strip ANSI

          ;; Check exit code
          (when (/= exit-code 0)
            (cl-return-from concur--handle-command-result
              (concur:rejected!
               (concur:make-error
                :type 'concur-process-exit-error
                :message (format "Command '%s' failed with exit code %d. \
                                 Stderr: %s"
                                 cmd exit-code stderr-str)
                :exit-code exit-code
                :stdout stdout-str
                :stderr stderr-str))))

          ;; Check for unexpected stderr output
          (when (not (string-empty-p stderr-str))
            (cl-return-from concur--handle-command-result
              (concur:rejected!
               (concur:make-error
                :type 'concur-process-stderr-output-error
                :message (format "Command '%s' produced stderr: %s"
                                 cmd stderr-str)
                :stdout stdout-str
                :stderr stderr-str))))

          ;; Success: resolve with the final stdout string.
          stdout-str)))))

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
  - (concur-promise): A promise that resolves with the stdout string on success,
    or rejects with a `concur-error` on any failure."
  (declare (indent 1) (debug t))
  `(let* ((parsed-parts (concur--parse-command-and-keys ,command (list ,@keys)))
          (cmd (car parsed-parts))
          (args (cadr parsed-parts))
          (final-keys (caddr parsed-parts))
          ;; Set `die-on-error` to nil because `concur:command` handles
          ;; error checking and result draining explicitly for convenience.
          (process-promise (apply #'concur:process :command cmd :args args
                                  :die-on-error nil final-keys)))
     ;; Delegate all result handling to the helper function.
     (concur--handle-command-result process-promise)))

(defun concur--chain-pipe-commands (session command-forms)
  "Recursively build a promise chain for `concur:pipe!` commands.
It executes one command, waits for it to succeed, and then recurses
on the rest of the commands, creating a sequential execution chain.

  Arguments:
  - `SESSION` (function): The active `concur:shell-session` function.
  - `COMMAND-FORMS` (list): The remaining command forms to execute.

  Returns:
  - (concur-promise): A promise that resolves with `t` when the entire chain
    completes, or rejects if any command fails."
  (if (null command-forms)
      (concur:resolved! t) ; Base case: all commands succeeded.
    (let* ((cmd-form (car command-forms))
           (parsed (concur--parse-command-and-keys (car cmd-form) (cdr cmd-form)))
           (cmd-str (s-join " " (cons (car parsed) (cadr parsed))))
           (cmd-keys (caddr parsed))
           (cwd (plist-get cmd-keys :cwd))
           (timeout (plist-get cmd-keys :timeout)))
      (concur:chain (funcall session cmd-str :cwd cwd :timeout timeout)
        (:then (lambda (shell-session-result)
                 (let ((stdout-stream (car shell-session-result))
                       (stderr-stream (cadr shell-session-result))
                       (error-promise (caddr shell-session-result)))
                   ;; Drain both streams to prevent backpressure stalls, then
                   ;; pass the main error-promise through the chain. The error
                   ;; promise handles exit codes and stderr from the shell.
                   (concur:chain (concur:all (concur:stream-drain stdout-stream)
                                             (concur:stream-drain stderr-stream))
                     (:then (lambda (_) error-promise))
                     (:catch (lambda (err) (concur:rejected! err)))))))
        (:then (lambda (command-result-promise)
                 ;; This promise from the session will reject on non-zero exit code.
                 (concur:then command-result-promise
                              (lambda (_) ; Command succeeded
                                (concur--chain-pipe-commands
                                 session (cdr command-forms)))
                              (lambda (err) ; Command failed
                                (concur:rejected! err)))))))))

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
  - (concur-promise): A promise that resolves with `t` on success of all
    commands, or rejects with a `concur-pipe-error` if any command fails."
  (declare (indent 1) (debug t))
  (unless command-forms
    (user-error "concur:pipe! requires at least one command"))
  (let ((session-var (gensym "session")))
    `(concur:shell-session (,session-var)
       (concur:chain
           (concur--chain-pipe-commands ,session-var (list ,@command-forms))
         (:catch (lambda (err)
                   ;; Wrap any error from the chain in a pipe error.
                   (concur:rejected! (concur:make-error :type 'concur-pipe-error
                                                         :message (format "Pipe \
                                                                           execution \
                                                                           failed: %S"
                                                                           err)
                                                         :cause err))))))))

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
  - (symbol): The defined function name `NAME`."
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