;;; concur-process.el --- Async Process Execution with Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a robust, high-level framework for running external
;; commands asynchronously and handling their results using Concur promises.
;; It is designed to be the primary interface for all external process
;; interactions within an asynchronous Concur-based application.
;;
;; Architectural Overview:
;; -----------------------
;;
;; The core of this library is the `concur:process` function, which creates
;; and manages an external process, returning a `concur-promise` that represents
;; the entire lifecycle of that process.
;;
;; Key features include:
;;
;; 1.  **Promise-Based API**: Every process returns a promise, allowing for
;;     clean, composable asynchronous workflows using `concur:then`,
;;     `concur:await`, and higher-level macros.
;;
;; 2.  **Streaming I/O**: Process stdout and stderr are exposed as
;;     `concur-stream` objects. This is memory-efficient for large outputs,
;;     as data can be processed in chunks using `concur:stream-drain` or
;;     `concur:stream-for-each`.
;;
;; 3.  **Rich Error Handling**: On failure, promises reject with a detailed
;;     `concur-error` object containing command specifics, exit code, signal
;;     information, and captured output, simplifying debugging.
;;
;; 4.  **Resource Management**: All associated resources (timers, I/O streams,
;;     temporary files, process buffers) are meticulously cleaned up automatically
;;     when the process terminates, is cancelled, or times out.
;;
;; 5.  **High-Level Macros**: Provides convenience macros like `concur:command`
;;     (for simple command-and-response workflows) and `concur:pipe!` (for
;;     executing stateful command sequences in the same shell environment).
;;
;; 6.  **Cancellation & Timeout**: Integrated support for cancelling processes
;;     via `concur-cancel-token`s and enforcing execution timeouts.

;;; Code:

;; Standard Emacs Lisp libraries
(require 'cl-lib)     ; Common Lisp extensions
(require 'dash)       ; Utility functions (e.g., list manipulation)
(require 's)          ; String manipulation library
(require 'subr-x)     ; Extended Emacs Lisp built-in functions
(require 'ansi-color) ; For handling ANSI escape codes in process output
(require 'f)          ; File system utilities
(require 'cl-extra)   ; Explicitly require cl-extra for cl-serialize-error/deserialize-error

;; Concur-specific libraries
(require 'concur-core)        ; Core promise implementation
(require 'concur-chain)       ; Promise chaining primitives and high-level flow control
(require 'concur-combinators) ; Promise combinators (e.g., all, race)
(require 'concur-lock)        ; Concurrency locks/mutexes
(require 'concur-log)         ; Concur-specific logging utility
(require 'concur-shell)       ; Persistent shell execution for concurrent commands
(require 'concur-stream)      ; Stream abstraction for async I/O

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 1: Error Definitions and Data Structures
;; Defines custom error types and data structures used throughout the library
;; to represent process results and internal state.

;; Custom error types for process-related failures
(define-error 'concur-process-error "A generic error during external process execution." 'concur-error)
(define-error 'concur-process-creation-error "Failed to create the external process." 'concur-process-error)
(define-error 'concur-process-cancelled "External process was cancelled." 'concur-process-error)
(define-error 'concur-process-timeout "External process execution timed out." 'concur-process-error)
(define-error 'concur-process-exit-error "External process exited with a non-zero status code." 'concur-process-error)
(define-error 'concur-process-signal-error "External process was terminated by a signal." 'concur-process-error)
(define-error 'concur-process-stdin-error "An error occurred while writing to process stdin." 'concur-process-error)
(define-error 'concur-process-stderr-output-error "A command produced output on stderr when none was expected." 'concur-process-error)
(define-error 'concur-pipe-error "An error occurred during sequential pipe execution." 'concur-process-error)

;; `concur-process-result` struct: Represents the successful outcome of a process
(cl-defstruct (concur-process-result
               (:constructor make-concur-process-result)
               (:copier nil))
  "Represents the successful result of an external process execution.
This object is the resolution value of a promise returned by `concur:process`.

Fields:
- `cmd` (string): The command executable that was run.
- `args` (list): The list of arguments passed to the command.
- `exit-code` (integer): The final exit code of the process (usually 0 for success).
- `stdout-stream` (concur-stream): The stream for standard output. Use
  `concur:stream-drain` or `concur:stream-for-each` to consume its content.
- `stderr-stream` (concur-stream): The stream for standard error.
  Similar to stdout, its content can be consumed via stream functions."
  (cmd nil :type string)
  (args nil :type list)
  (exit-code nil :type integer)
  (stdout-stream nil :type (or null concur-stream))
  (stderr-stream nil :type (or null concur-stream)))

;; `concur-process-io` struct: Internal encapsulation of I/O configuration
(cl-defstruct (concur-process-io
               (:constructor %%make-concur-process-io)
               (:copier nil))
  "Internal struct to cleanly encapsulate all I/O configuration for a process.

Fields:
- `on-stdout-user-cb` (function): User-provided callback for stdout chunks.
  Invoked immediately as data arrives.
- `on-stderr-user-cb` (function): User-provided callback for stderr chunks.
  Invoked immediately as data arrives.
- `stdout-stream` (concur-stream): The internal stream where stdout data is buffered.
- `stderr-stream` (concur-stream): The internal stream where stderr data is buffered."
  (on-stdout-user-cb nil :type (or null function))
  (on-stderr-user-cb nil :type (or null function))
  (stdout-stream nil :type (or null concur-stream))
  (stderr-stream nil :type (or null concur-stream)))

;; `concur-process-state` struct: Internal state management for an executing process
(cl-defstruct (concur-process-state
               (:constructor %%make-concur-process-state)
               (:copier nil))
  "Internal state for managing an asynchronously executing process.
This struct holds all necessary runtime information about a spawned process.

Fields:
- `promise` (concur-promise): The top-level promise associated with this process,
  which will be settled upon process termination.
- `process` (process): The actual Emacs `process` object created by `make-process`.
- `command` (string): The base command executable string.
- `args` (list): Arguments passed to the command.
- `cwd` (string): The current working directory for the process.
- `env` (alist): Additional environment variables supplied to the process.
- `io` (concur-process-io): The struct holding I/O configuration and streams.
- `stdin-data` (string): Data string to be sent to the process's stdin.
- `stdin-file` (string): A file path from which to stream data to stdin.
- `stdin-buffer` (buffer): A temporary buffer used when streaming stdin from data/file.
- `stdin-read-pos` (marker): A marker tracking the current read position in `stdin-buffer`.
- `stdin-send-timer` (timer): Timer for chunked stdin sending, ensuring non-blocking I/O.
- `die-on-error` (boolean): If `t`, the promise is rejected on non-zero exit code.
- `timeout-timer` (timer): Timer to enforce specified execution timeouts.
- `cancel-token` (concur-cancel-token): Token for external cancellation signals.
- `stdin-temp-file-path` (string): Path to a temporary file created for `stdin-data`."
  (promise nil :type (or null concur-promise))
  (process nil :type (or null process))
  (command nil :type string)
  (args nil :type list)
  (cwd nil :type string)
  (env nil :type (or null list))
  (io nil :type (or null concur-process-io))
  (stdin-data nil :type (or null string))
  (stdin-file nil :type (or null string))
  (stdin-buffer nil :type (or null buffer-or-string))
  (stdin-read-pos nil :type (or null marker))
  (stdin-send-timer nil :type (or null timer))
  (die-on-error t :type boolean)
  (timeout-timer nil :type (or null timer))
  (cancel-token nil :type (or null concur-cancel-token))
  (stdin-temp-file-path nil :type (or null string)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 2: Deferred File Cleanup (Internal)
;; Handles the asynchronous and safe deletion of temporary files created by
;; the process execution, preventing file locking issues and ensuring resource
;; cleanliness.

(defvar concur--proc-cleanup-lock (concur:make-lock "proc-cleanup-lock")
  "A lock to protect the list of files pending deferred deletion.")
(defvar concur--proc-cleanup-timer nil
  "An idle timer that periodically runs the file cleanup task.")
(defvar concur--proc-files-to-delete '()
  "A list of temporary file paths to be deleted by the cleanup timer.")

(defun concur--proc-delete-file-if-exists (file-path)
  "Delete FILE-PATH if it exists, logging any errors during the operation."
  (when (and file-path (file-exists-p file-path))
    (condition-case err
        (delete-file file-path)
      (error
       (concur--log :error nil "Failed to delete temp file %s: %S"
                    file-path err)))))

(defun concur--proc-schedule-file-for-deletion (file)
  "Add a FILE to a global list for deferred, thread-safe deletion.
A cleanup timer will be started if not already running."
  (when file
    (concur--log :debug nil "Scheduling temp file for deletion: %s" file)
    (concur:with-mutex! concur--proc-cleanup-lock
      (push file concur--proc-files-to-delete)
      ;; Start the cleanup timer if it's not already active
      (unless (timerp concur--proc-cleanup-timer)
        (setq concur--proc-cleanup-timer
              (run-with-idle-timer 5.0 t
                                   #'concur--proc-process-deletions))))))

(defun concur--proc-process-deletions ()
  "Process the list of files scheduled for deletion.
This function is typically run by `concur--proc-cleanup-timer`."
  (concur--log :debug nil "Running deferred file deletion task.")
  (concur:with-mutex! concur--proc-cleanup-lock
    (let ((files-to-process concur--proc-files-to-delete))
      (setq concur--proc-files-to-delete '()) ; Clear the list under lock
      (dolist (file files-to-process)
        (concur--proc-delete-file-if-exists file)))
    ;; Cancel the timer if there are no more files to delete
    (when (and (null concur--proc-files-to-delete)
               (timerp concur--proc-cleanup-timer))
      (cancel-timer concur--proc-cleanup-timer)
      (setq concur--proc-cleanup-timer nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 3: Core Process State Management (Internal Helpers)
;; Functions for handling promise rejection, process events, and resource
;; cleanup during the process lifecycle.

(cl-defun concur--proc-reject-promise (process-state
                                       error-type
                                       message
                                       &key cause
                                            exit-code
                                            signal
                                            process-status)
  "Centralized function to reject a process promise with a rich error object.
Ensures streams are errored and the top-level promise is rejected consistently."
  (let* ((promise (concur-process-state-promise process-state))
         (io (concur-process-state-io process-state)))
    (concur--log :error (concur-promise-id promise)
                 "Rejecting process promise: %s" message)
    (let ((error-obj
           (concur:make-error
            :type error-type :message message :cause cause :promise promise
            :cmd (concur-process-state-command process-state)
            :args (concur-process-state-args process-state)
            :cwd (concur-process-state-cwd process-state)
            :exit-code exit-code :signal signal
            :process-status process-status)))
      ;; Error out associated streams to notify any waiting consumers
      (when-let (stdout (concur-process-io-stdout-stream io))
        (concur:stream-error stdout error-obj))
      (when-let (stderr (concur-process-io-stderr-stream io))
        (concur:stream-error stderr error-obj))
      ;; Reject the main promise
      (concur:reject promise error-obj))))

(cl-defun concur--proc-handle-creation-error (promise err
                                                 &key command args cwd)
  "Handle synchronous errors that occur during `make-process`.
Rejects the promise with a `concur-process-creation-error`."
  (let* ((cmd-str (s-join " " (cons command args)))
         (msg (format "Failed to create process for '%s': %s"
                      cmd-str (error-message-string err))))
    (concur--proc-reject-promise
     (%%make-concur-process-state :promise promise
                                  :command command :args args :cwd cwd)
     'concur-process-creation-error msg :cause err)))

(defun concur--proc-get-signal-from-event (event-string)
  "Parse a process sentinel EVENT-STRING to extract a signal name (e.g., 'SIGKILL')."
  (when (string-match "signal-killed-by-\\(SIG[A-Z]+\\)" event-string)
    (match-string 1 event-string)))

(defun concur--proc-finalize-promise (process-state event)
  "Finalize the promise based on the process termination event.
Checks for signals, exit codes, and resolves or rejects the promise accordingly."
  (let* ((promise (concur-process-state-promise process-state))
         (proc (concur-process-state-process process-state))
         (cmd (concur-process-state-command process-state))
         (io (concur-process-state-io process-state))
         (die-on-error (concur-process-state-die-on-error process-state))
         (exit-code (process-exit-status proc))
         (signal (concur--proc-get-signal-from-event event)))
    (cond
     ;; Process terminated by a signal
     (signal
      (concur--proc-reject-promise
       process-state 'concur-process-signal-error
       (format "Command '%s' killed by signal %s" cmd signal)
       :signal signal :process-status (process-status proc)))
     ;; Process exited with a non-zero code and `die-on-error` is true
     ((and (/= exit-code 0) die-on-error)
      (concur--proc-reject-promise
       process-state 'concur-process-exit-error
       (format "Command '%s' exited with non-zero code %d" cmd exit-code)
       :exit-code exit-code :process-status (process-status proc)))
     ;; Otherwise, success (exit code 0 or `die-on-error` is nil)
     (t
      (concur--log :info (concur-promise-id promise)
                   "Resolving process promise with exit code %d" exit-code)
      (concur:resolve
       promise
       (make-concur-process-result
        :cmd cmd :args (concur-process-state-args process-state)
        :exit-code exit-code
        :stdout-stream (concur-process-io-stdout-stream io)
        :stderr-stream (concur-process-io-stderr-stream io)))))))

(defun concur--proc-cleanup-resources (process-state)
  "Clean up internal timers, temporary buffers, and scheduled temp files
associated with a finished process. This is crucial for preventing resource leaks."
  (concur--log :debug (concur-promise-id
                       (concur-process-state-promise process-state))
               "Cleaning up process resources.")
  ;; Cancel any active timers
  (when-let (timer (concur-process-state-timeout-timer process-state))
    (cancel-timer timer)
    (setf (concur-process-state-timeout-timer process-state) nil))
  (when-let (timer (concur-process-state-stdin-send-timer process-state))
    (cancel-timer timer)
    (setf (concur-process-state-stdin-send-timer process-state) nil))
  ;; Kill any temporary buffers used for stdin
  (when-let (buf (concur-process-state-stdin-buffer process-state))
    (when (buffer-live-p buf)
      (kill-buffer buf))
    (setf (concur-process-state-stdin-buffer process-state) nil))
  ;; Schedule temporary stdin files for deferred deletion
  (when-let (file (concur-process-state-stdin-temp-file-path process-state))
    (concur--proc-schedule-file-for-deletion file)
    (setf (concur-process-state-stdin-temp-file-path process-state) nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 4: Process Lifecycle and I/O (Sentinels and Filters)
;; Defines the Emacs process sentinel and filter functions that manage
;; communication with external processes and trigger promise settlement.

(defun concur--proc-cleanup-buffers (process)
  "Kill the stdout and stderr buffers created by Emacs for a process.
These are different from the `concur-stream` buffers."
  (when-let (buf (process-buffer process))
    (when (buffer-live-p buf) (kill-buffer buf)))
  (when-let (buf (process-get process 'concur-stderr-buffer))
    (when (buffer-live-p buf) (kill-buffer buf))))

(defun concur--proc-sentinel (process event)
  "The main process sentinel. This is the central coordinator for process teardown.
It's called by Emacs when the process state changes (e.g., exits, signals)."
  (when (memq (process-status process) '(exit signal finished))
    (when-let ((process-state (process-get process 'concur-process-state)))
      (let* ((promise (concur-process-state-promise process-state))
             (io (concur-process-state-io process-state)))
        (concur--log :debug (concur-promise-id promise)
                     "Sentinel fired for %S (event: '%s')"
                     (process-name process) event)

        ;; Always perform cleanup
        (concur--proc-cleanup-resources process-state)
        (concur--proc-cleanup-buffers process)

        ;; Close streams to signal end-of-stream to consumers
        (when-let (s (concur-process-io-stdout-stream io))
          (concur:stream-close s))
        (when-let (s (concur-process-io-stderr-stream io))
          (concur:stream-close s))

        ;; Finalize the promise if it's still pending
        (when (concur:pending-p promise)
          (concur--proc-finalize-promise process-state event))))))

(defun concur--proc-dispatch-to-stream (process chunk stream-type)
  "Dispatch a CHUNK of data from PROCESS to the correct user callback and `concur-stream`.
This function is called by process filters (stdout/stderr)."
  (when-let ((process-state (process-get process 'concur-process-state)))
    (let* ((io (concur-process-state-io process-state))
           (stream (if (eq stream-type :stdout)
                       (concur-process-io-stdout-stream io)
                     (concur-process-io-stderr-stream io)))
           (user-cb (if (eq stream-type :stdout)
                        (concur-process-io-on-stdout-user-cb io)
                      (concur-process-io-on-stderr-user-cb io))))
      ;; Call user-provided callback immediately if it exists
      (when user-cb (funcall user-cb chunk))

      ;; Write chunk to the internal concur-stream
      (when stream
        (concur--log :trace (concur-promise-id
                             (concur-process-state-promise process-state))
                     "Dispatching %s chunk of %d bytes"
                     stream-type (length chunk))
        (let ((write-result (concur:stream-write stream chunk)))
          ;; If stream-write returns a promise (e.g., if stream buffer is full),
          ;; handle its potential rejection.
          (when (eq (type-of write-result) 'concur-promise)
            (concur:then write-result nil
                         (lambda (err)
                           (concur--proc-reject-promise
                            process-state 'concur-process-error
                            "Output stream write failed" :cause err)))))))))

(defun concur--proc-stdout-filter (process chunk)
  "Process filter for standard output. Dispatches chunks to `concur-stream`."
  (concur--proc-dispatch-to-stream process chunk :stdout))

(defun concur--proc-stderr-filter (process chunk)
  "Process filter for standard error. Dispatches chunks to `concur-stream`."
  (concur--proc-dispatch-to-stream process chunk :stderr))

(defun concur--proc-read-from-stdin-buffer (process-state)
  "Read a chunk from the internal stdin buffer and send it to the process.
This function is driven by an idle timer for non-blocking stdin streaming."
  (let* ((proc (concur-process-state-process process-state))
         (buf (concur-process-state-stdin-buffer process-state))
         (pos-marker (concur-process-state-stdin-read-pos process-state))
         (chunk-size 4096)) ; Define a reasonable chunk size for stdin
    (condition-case err
        (with-current-buffer buf
          (if (>= (marker-position pos-marker) (point-max))
              ;; All data sent, send EOF to the process
              (progn
                (concur--log :debug nil "Finished streaming stdin; sending EOF to %S." proc)
                (process-send-eof proc)
                ;; Cancel the timer once all stdin is sent
                (when-let (timer (concur-process-state-stdin-send-timer
                                  process-state))
                  (cancel-timer timer)
                  (setf (concur-process-state-stdin-send-timer
                         process-state) nil)))
            ;; Send the next chunk
            (let* ((end (min (point-max)
                             (+ (marker-position pos-marker) chunk-size)))
                   (chunk (buffer-substring-no-properties pos-marker end)))
              (process-send-string proc chunk)
              (move-marker pos-marker end))))
      (error
       ;; Handle errors during stdin sending
       (concur--proc-reject-promise
        process-state 'concur-process-stdin-error
        "Failed to send stdin to process" :cause err)
       (when-let (timer (concur-process-state-stdin-send-timer process-state))
         (cancel-timer timer))))))

(defun concur--proc-setup-stdin-streaming (process-state)
  "Initializes stdin streaming from a file or string data.
Sets up a temporary buffer and an idle timer to send data in chunks."
  (cl-block setup-stdin
    (let ((stdin-file (concur-process-state-stdin-file process-state))
          (stdin-data (concur-process-state-stdin-data process-state))
          (proc (concur-process-state-process process-state)))
      (cond
       ;; Stream from a file
       (stdin-file
        (concur--log :debug nil "Setting up stdin streaming from file: %s"
                     stdin-file)
        (unless (file-exists-p stdin-file)
          (concur--proc-reject-promise
           process-state 'concur-process-stdin-error
           (format "Stdin file does not exist: %s" stdin-file))
          (cl-return-from setup-stdin)) ; Exit block if file not found
        (condition-case err
            (let ((buf (generate-new-buffer
                        (format "*concur-stdin<%s>*"
                                (file-name-nondirectory stdin-file)))))
              (setf (concur-process-state-stdin-buffer process-state) buf)
              (with-current-buffer buf
                (insert-file-contents-literally stdin-file)
                (setf (concur-process-state-stdin-read-pos process-state)
                      (point-min-marker)))
              ;; Start the idle timer for chunked sending
              (setf (concur-process-state-stdin-send-timer process-state)
                    (run-with-idle-timer
                     0.01 t #'concur--proc-read-from-stdin-buffer
                     process-state)))
          (error
           (concur--proc-reject-promise
            process-state 'concur-process-stdin-error
            (format "Failed to read stdin file %s: %s"
                    stdin-file (error-message-string err))
            :cause err))))
       ;; Stream from a data string (by writing to a temp file first)
       (stdin-data
        (concur--log :debug nil "Setting up stdin from data string.")
        (condition-case err
            (let ((temp-file (make-temp-file "concur-stdin-")))
              (with-temp-file temp-file (insert stdin-data))
              (setf (concur-process-state-stdin-temp-file-path process-state)
                    temp-file)
              ;; Recursively call this function to handle the temp file
              (setf (concur-process-state-stdin-file process-state) temp-file)
              (concur--proc-setup-stdin-streaming process-state))
          (error
           (concur--proc-reject-promise
            process-state 'concur-process-stdin-error
            "Failed to write stdin data to temp file" :cause err))))
       ;; No stdin data, just send EOF immediately
       (t (process-send-eof proc))))))

(defun concur--proc-setup-timeout (process-state timeout)
  "Set up a timer that kills the process and rejects its promise on timeout."
  (when timeout
    (let* ((promise (concur-process-state-promise process-state))
           (proc (concur-process-state-process process-state))
           (cmd (concur-process-state-command process-state)))
      (concur--log :debug (concur-promise-id promise)
                   "Setting process timeout: %Ss" timeout)
      (setf (concur-process-state-timeout-timer process-state)
            (run-at-time
             timeout nil
             (lambda ()
               (concur--log :warn (concur-promise-id promise)
                            "Process timed out after %Ss" timeout)
               (when (process-live-p proc)
                 (ignore-errors (kill-process proc)) ; Attempt to kill the process
                 (concur--proc-reject-promise
                  process-state 'concur-process-timeout
                  (format "Command '%s' timed out after %Ss." cmd timeout)
                  :cause "timeout"))))))))

(defun concur--proc-setup-cancellation (process-state cancel-token)
  "Set up a handler that kills the process and rejects its promise
when the provided `cancel-token` is signaled."
  (when cancel-token
    (let* ((promise (concur-process-state-promise process-state))
           (proc (concur-process-state-process process-state))
           (cmd (concur-process-state-command process-state)))
      (concur--log :debug (concur-promise-id promise)
                   "Setting up cancellation handler.")
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (concur--log :info (concur-promise-id promise)
                      "Cancellation requested for process %S." proc)
         (when (process-live-p proc)
           (ignore-errors (kill-process proc)) ; Attempt to kill the process
           (concur--proc-reject-promise
            process-state 'concur-process-cancelled
            (format "Command '%s' was cancelled." cmd)
            :cause "cancellation")))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 5: Main Spawning Logic (Internal Orchestration)
;; Orchestrates the creation of Emacs processes based on provided options
;; and sets up all necessary sentinels, filters, and timers.

(defun concur--spawn-standard-process (promise plist)
  "Orchestrates the creation and configuration of a standard Emacs process.
This function is called by `concur:process` when a persistent shell is not used."
  (let* ((command (plist-get plist :command))
         (args (plist-get plist :args))
         (cwd (or (plist-get plist :cwd) default-directory)))
    (concur--log :info (concur-promise-id promise) "Spawning command: %s %s"
                 command (s-join " " args))

    (let* ((io (%%make-concur-process-io
                :on-stdout-user-cb (plist-get plist :on-stdout)
                :on-stderr-user-cb (plist-get plist :on-stderr)
                :stdout-stream (concur:stream-create) ; Create internal streams
                :stderr-stream (concur:stream-create)))
           (process-state
            (%%make-concur-process-state
             :promise promise :command command :args args :cwd cwd :io io
             :env (plist-get plist :env)
             :stdin-data (plist-get plist :stdin)
             :stdin-file (plist-get plist :stdin-file)
             :die-on-error (not (eq (plist-get plist :die-on-error) nil))
             :cancel-token (plist-get plist :cancel-token))))
      (condition-case err
          ;; Attempt to create the Emacs process
          (let* ((proc-env (if-let ((env (concur-process-state-env
                                          process-state)))
                               ;; Merge custom environment with existing process-environment
                               (append (--map (format "%s=%s" (car it) (cdr it)) env)
                                       process-environment)
                             process-environment))
                 (stderr-buf (generate-new-buffer
                              (format "*concur-stderr: %s*" command)))
                 (proc
                  (make-process
                   :name (format "concur-%s" (file-name-nondirectory command))
                   :command (cons command (or args '())) ; Combine command and args
                   :buffer (generate-new-buffer         ; Buffer for stdout
                            (format "*concur-stdout: %s*" command))
                   :stderr stderr-buf                   ; Buffer for stderr
                   :sentinel #'concur--proc-sentinel    ; Main process sentinel
                   :filter #'concur--proc-stdout-filter ; Filter for stdout data
                   :stderr-filter #'concur--proc-stderr-filter ; Filter for stderr data
                   :noquery t :connection-type 'pipe :coding 'utf-8
                   :current-directory cwd :environment proc-env)))
            ;; Store process-state on the Emacs process object for retrieval in filters/sentinel
            (process-put proc 'concur-process-state process-state)
            (process-put proc 'concur-stderr-buffer stderr-buf) ; Store stderr buffer reference
            ;; Update process-state with the created Emacs process
            (setf (concur-process-state-process process-state) proc)
            ;; Associate the Emacs process with the Concur promise
            (setf (concur-promise-proc promise) proc)

            ;; Set up stdin streaming, timeout, and cancellation handlers
            (concur--proc-setup-stdin-streaming process-state)
            (concur--proc-setup-timeout
             process-state (plist-get plist :timeout))
            (concur--proc-setup-cancellation
             process-state (plist-get plist :cancel-token)))
        (error
         ;; Handle synchronous process creation errors (e.g., command not found)
         (concur--proc-handle-creation-error
          promise err :command command :args args :cwd cwd))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 6: Public API: Core Functions
;; The primary user-facing functions for interacting with processes.

;;;###autoload
(defun concur:process (&rest plist)
  "Run an external command asynchronously, returning a promise for the result.
This is the core process execution function. It returns a promise that
resolves with a `concur-process-result` object on successful
completion. This result object contains the final exit code and the
`concur-stream`s for stdout and stderr, which you can then consume.

Arguments:
  PLIST (plist): A property list of options:
  - `:command` (string or list): The command and its initial arguments
    (e.g., `\"git status\"` or `(\"git\" \"status\")`).
  - `:args` (list, optional): Additional arguments to append to the command.
  - `:cwd` (string, optional): Working directory. Defaults to `default-directory`.
  - `:env` (alist, optional): Environment variables, e.g., `'((\"VAR\" . \"val\"))`.
  - `:stdin` (string, optional): Data to send to standard input.
  - `:stdin-file` (string, optional): Path to a file to stream to stdin.
  - `:on-stdout` (function, optional): A callback `(lambda (chunk))` invoked for each
    chunk of stdout data as it arrives. Useful for real-time output processing.
  - `:on-stderr` (function, optional): A callback `(lambda (chunk))` for stderr.
  - `:persistent` (boolean, optional): If non-nil, use a persistent shell from
    `concur-shell.el`. This is faster for frequent, small commands but
    offers less isolation.
  - `:timeout` (number, optional): Timeout in seconds. If the process runs longer,
    it will be killed and the promise rejected with a `concur-process-timeout` error.
  - `:cancel-token` (concur-cancel-token, optional): A token to cancel the process.
    If the token is signaled, the promise is rejected with a `concur-process-cancelled` error.
  - `:die-on-error` (boolean, optional): If non-nil (the default), the promise is
    rejected if the process exits with a non-zero status code. Set to `nil` to
    resolve successfully even with non-zero exit codes.
  - `:mode` (symbol, optional): Promise concurrency mode (default `:async`).

Returns:
  (concur-promise): A promise for the `concur-process-result`."
  (let* ((command-val (plist-get plist :command))
         (initial-args (plist-get plist :args))
         ;; Parse command and arguments consistently
         (command (if (listp command-val)
                      (car command-val)
                    (car (s-split " " command-val t))))
         (args (append (if (listp command-val)
                           (cdr command-val)
                         (cdr (s-split " " command-val t)))
                       initial-args))
         ;; NOTE: Removed `use-persistent` check here and direct submission
         ;;       to concur:shell-submit-command, as per the "one-shot" design.
         (final-plist (append (list :command command :args args) plist))
         (promise (concur:make-promise
                   :cancel-token (plist-get plist :cancel-token)
                   :mode (or (plist-get plist :mode) :async))))

    ;; Always execute as a standard, non-persistent Emacs process for `concur:process`.
    ;; Users wanting persistent shells should explicitly call concur:shell-submit-command.
    (concur--spawn-standard-process promise final-plist)
    promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SECTION 7: Public API: High-level Command Macros
;; Convenience macros built on top of `concur:process` for common patterns.

(defun concur--proc-helper-parse-command-and-keys (command-form keys)
  "Internal helper to parse COMMAND-FORM and merge KEYWORD arguments.
Extracts the base command, its arguments, and a processed plist of other keys."
  (let (cmd cmd-args)
    ;; Determine base command and its initial arguments
    (if (stringp command-form)
        (let ((parts (s-split " " command-form t)))
          (setq cmd (car parts) cmd-args (cdr parts)))
      (setq cmd (car command-form) cmd-args (cdr command-form)))

    (let* ((user-args (plist-get keys :args))
           (final-cwd (or (plist-get keys :cwd) (plist-get keys :dir))) ; Support :dir alias
           (other-keys (cl-loop for (k v) on keys by #'cddr
                                unless (memq k '(:args :cwd :dir)) ; Filter out processed keys
                                nconc (list k v))))
      ;; Return a list: (command-executable final-arguments other-keys)
      (list cmd (append cmd-args user-args)
            (if final-cwd (append `(:cwd ,final-cwd) other-keys)
              other-keys)))))

(defun concur--proc-helper-chain-pipe-commands (session command-forms)
  "Recursively builds a promise chain for `concur:pipe!` commands.
Each command is submitted to the same shell SESSION."
  (if (null command-forms)
      (concur:resolved! t) ; Base case: all commands succeeded
    (let* ((cmd-form (car command-forms))
           (parsed (concur--proc-helper-parse-command-and-keys
                    (car cmd-form) (cdr cmd-form)))
           (cmd-str (s-join " " (cl-cons (car parsed) (cl-cadr parsed)))) ;; Use cl-cons and cl-cadr for clarity
           (cmd-keys (cl-caddr parsed))) ;; Use cl-caddr for clarity
      (concur:chain (funcall session cmd-str ; Submit command to the shell session
                             :cwd (plist-get cmd-keys :cwd)
                             :timeout (plist-get cmd-keys :timeout))
        ;; Extract the error promise from the shell session result (stdout, stderr, error-promise)
        (:then (lambda (shell-session-result)
                 (nth 2 shell-session-result)))
        ;; Continue chaining recursively with the rest of the commands
        (:then (lambda (_) ; Ignore the result of the error-promise (it resolved successfully)
                 (concur--proc-helper-chain-pipe-commands
                  session (cdr command-forms))))))))

(defun concur--maybe-reject-process-result (exit-code stderr stdout cmd)
  "Helper to determine if a process result warrants a rejection error.
Returns a `concur-error` object if failure conditions are met, otherwise `nil`."
  (pcase (list exit-code stderr)
    ;; Non-zero exit code → failure
    (`(,(and code (pred (lambda (c) (/= c 0)))) ,stderr)
     (concur:make-error
      :type 'concur-process-exit-error
      :message (format "Command '%s' failed (code %d): %s"
                       cmd code stderr)
      :exit-code code
      :stdout stdout
      :stderr stderr))

    ;; Zero exit but non-empty stderr → warning/error (if stderr is considered an error)
    (`(0 ,(and stderr (pred (lambda (s) (not (string-empty-p s))))))
     (concur:make-error
      :type 'concur-process-stderr-output-error
      :message (format "Command '%s' produced stderr: %s"
                       cmd stderr)
      :stdout stdout
      :stderr stderr))

    ;; Otherwise: success
    (_ nil)))

;; Reverting to the explicit chaining for stream draining (as in original working version)
(defun concur--finalize-command-promise (process-promise)
  "Chains from an raw `concur:process` promise to drain streams and
resolve with the final stdout string. Handles errors based on exit code and stderr."
  (concur:chain process-promise
    ;; Step 1: When the process finishes, get the `concur-process-result` struct.
    (:then
     (lambda (proc-result)
       ;; Step 2: Drain stdout stream and pass both the collected chunks
       ;; and the original `proc-result` to the next step.
       (concur:then
        (concur:stream-drain
         (concur-process-result-stdout-stream proc-result))
        (lambda (stdout-chunks)
          (list stdout-chunks proc-result))))) ; Return list (stdout-chunks proc-result)

    ;; Step 3: Now we have stdout chunks and the `proc-result`. Drain stderr.
    (:then
     (lambda (info-list)
       (let ((stdout-chunks (nth 0 info-list))
             (proc-result   (nth 1 info-list)))
         (concur:then
          (concur:stream-drain
           (concur-process-result-stderr-stream proc-result))
          (lambda (stderr-chunks)
            (list stdout-chunks stderr-chunks proc-result)))))) ; Return list (stdout-chunks stderr-chunks proc-result)

    ;; Step 4: Now we have all drained streams and the process result.
    ;; Use the helper to process the combined results and settle the promise.
    (:then
     (lambda (final-info-list)
       (let* ((stdout-chunks (nth 0 final-info-list))
              (stderr-chunks (nth 1 final-info-list))
              (proc-result   (nth 2 final-info-list))
              (cmd (concur-process-result-cmd proc-result))
              (exit-code (concur-process-result-exit-code proc-result))
              ;; Join chunks into strings and apply ANSI color filtering
              (stdout-str (ansi-color-filter-apply
                           (s-join "" stdout-chunks)))
              (stderr-str (ansi-color-filter-apply
                           (s-join "" stderr-chunks)))
              ;; Use the helper function to check for errors based on exit code/stderr
              (rejection-error
               (concur--maybe-reject-process-result
                exit-code stderr-str stdout-str cmd)))

         ;; If the helper returned an error, reject the promise with that error.
         ;; Otherwise, resolve the promise with the collected stdout string.
         (if rejection-error
             (concur:rejected! rejection-error)
           stdout-str))))))

;;;###autoload
(defmacro concur:command (command &rest keys)
  "Run a command and return a promise for its complete stdout string.
This high-level wrapper around `concur:process` handles common cases:
- Rejects if the process exits with a non-zero code (unless `:die-on-error nil`).
- Rejects if the process produces any output on stderr.
- Resolves with the complete, trimmed stdout content on success.

Arguments:
  COMMAND (string or list): The command to run (e.g., `\"ls -l\"`).
  KEYS (plist): Options, same as `concur:process`. Accepts `:dir` as an
    alias for `:cwd`.

Returns:
  A `concur-promise` that resolves with the trimmed stdout string."
  (declare (indent 1) (debug t))
  `(let* ((parsed-parts (concur--proc-helper-parse-command-and-keys
                         ,command (list ,@keys)))
          (cmd (nth 0 parsed-parts))
          (args (nth 1 parsed-parts))
          (final-keys (nth 2 parsed-parts))
          (process-promise (apply #'concur:process
                                  :command cmd :args args
                                  :die-on-error nil ; Override default to allow custom error handling
                                  final-keys)))
     (concur:then (concur--finalize-command-promise process-promise)
                  ;; The `concur:then` macro (in concur-chain.el) now internally handles forwarding
                  ;; only the value, maintaining the clean API here.
                  (lambda (output-string) (s-trim output-string)))))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr &rest keys)
  "Define `NAME` as a function that runs an async command via `concur:command`.
This is a convenient way to create reusable, documented async commands.

Arguments:
  `NAME` (symbol): The name of the function to define.
  `ARGLIST` (list): The argument list for the new function.
  `DOCSTRING` (string): The documentation string for the new function.
  `COMMAND-EXPR` (form): A form evaluating to the command list/string,
    which can use the variables bound in `ARGLIST`.
  `KEYS` (plist): Default options for `concur:command`.
    - `:interactive` (form, optional): An interactive spec for the function.

Returns:
  The defined function name `NAME`."
  (declare (indent 1) (debug t))
  (let ((interactive-spec (plist-get keys :interactive))
        (default-keys (cl-loop for (k v) on keys by #'cddr
                               unless (eq k :interactive)
                               nconc (list k v)))
        (rest-args (make-symbol "rest-args")))
    `(progn
       (cl-defun ,name (,@arglist &rest ,rest-args)
         ,docstring
         ,@(when interactive-spec `((interactive ,interactive-spec)))
         (let ((command ,command-expr))
           (concur:command command ,@(append ,rest-args ',default-keys)))))))

(provide 'concur-process)
;;; concur-process.el ends here