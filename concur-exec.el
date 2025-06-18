;;; concur-exec.el --- Asynchronous Process Execution with Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a robust framework for running external commands
;; asynchronously, handling their results with promises. It streamlines common
;; patterns for process execution and chaining, offering a high-level API over
;; raw Emacs processes.
;;
;; At its core, this module offers a single, powerful process primitive:
;;
;; 1. `concur:process`: A versatile, non-coroutine-based process execution
;;    function that intelligently manages output. It can accumulate output
;;    in memory (as a list of string chunks), stream it to user-provided
;;    callbacks, or spill it to a temporary file. Spilling to a file happens
;;    automatically if a size threshold is exceeded (via `:max-memory-output`)
;;    or if explicitly requested (via `:output-to-file`).
;;
;; Building on this primitive, the library provides high-level macros:
;;
;; - `concur:command`: A user-friendly wrapper around `concur:process` that
;;   simplifies common execution patterns and argument handling.
;;
;; - `concur:pipe!`: A macro for elegantly chaining multiple commands, piping
;;   the stdout of one to the stdin of the next. Intermediate files are
;;   managed and cleaned up automatically.
;;
;; - `concur:define-command!`: A convenience macro for defining reusable
;;   asynchronous command functions with default arguments.
;;
;; The module extensively uses `cl-defstruct` for clear, type-safe data
;; structures and emphasizes robust error handling and resource management.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-promise)
(require 'concur-primitives)
(require 'ansi-color)
(require 'concur-hooks)
(require 'async)
(require 'seq)
(require 'subr-x)
(require 's)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Configuration Constants

(defconst concur-output-file-buffer-size 16384
  "Size in bytes for the internal buffer used when writing to temporary
files in process filters. Larger buffers reduce file I/O calls.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Structs & Error Conditions

(define-error 'concur-exec-error "Error during process execution.")
(define-error 'concur-exec-creation-error "Error creating process."
  'concur-exec-error)
(define-error 'concur-exec-cancelled "Process was cancelled."
  'concur-exec-error)
(define-error 'concur-exec-timeout "Process execution timed out."
  'concur-exec-error)
(define-error 'concur-pipe-error "Error during pipe execution."
  'concur-exec-error)

(cl-defstruct (concur-exec-error-info
               (:constructor make-concur-exec-error-info
                             (&key message exit-code stdout stderr cmd args
                                   cwd env original-error timeout
                                   process-status signal reason)))
  "Detailed information about a `concur-exec` error.

Fields:
- `message` (string): Human-readable error message.
- `exit-code` (integer or nil): The process exit code.
- `stdout` (string or nil): Captured stdout.
- `stderr` (string or nil): Captured stderr.
- `cmd` (string or nil): The command executed.
- `args` (list or nil): Arguments passed to the command.
- `cwd` (string or nil): Working directory during execution.
- `env` (alist or nil): Environment variables used.
- `original-error` (any): The underlying Lisp error object, if any.
- `timeout` (number or nil): Timeout duration if applicable.
- `process-status` (symbol or string or nil): Final process status.
- `signal` (string or nil): Signal name if terminated by signal.
- `reason` (symbol or nil): High-level reason for the error (e.g., `:timeout`)."
  (message "" :type string)
  (exit-code nil :type (or integer null))
  (stdout nil :type (or string null))
  (stderr nil :type (or string null))
  (cmd nil :type (or string null))
  (args nil :type (or list null))
  (cwd nil :type (or string null))
  (env nil :type (or list null))
  original-error
  (timeout nil :type (or number null))
  (process-status nil :type (or symbol string null))
  (signal nil :type (or string null))
  (reason nil :type (or symbol null)))

(cl-defstruct (concur-process-result
               (:constructor make-concur-process-result
                             (&key cmd args exit stdout stderr
                                   stdout-file-path stderr-file-path)))
  "Represents the result of a process execution.

Fields:
- `cmd` (string): The command that was executed.
- `args` (list): The arguments passed to the command.
- `exit` (integer): The final exit code of the process.
- `stdout` (string): Captured standard output content. If output was spilled
  to a file, this will contain the file path instead of the content.
- `stderr` (string): Captured standard error content. If output was spilled
  to a file, this will contain the file path instead of the content.
- `stdout-file-path` (string or nil): The path to the temporary file if
  stdout was spilled, otherwise nil.
- `stderr-file-path` (string or nil): The path to the temporary file if
  stderr was spilled, otherwise nil."
  (cmd "" :type string)
  (args nil :type list)
  (exit 0 :type integer)
  (stdout "" :type string)
  (stderr "" :type string)
  (stdout-file-path nil :type (or string null))
  (stderr-file-path nil :type (or string null)))

(cl-defstruct (concur-process-output-state
               (:constructor make-concur-process-output-state))
  "Internal state for managing process output accumulation.
An instance of this struct is attached to each running process to track
how its output is being handled.

Fields:
- `cmd-exe` (string): The executable name.
- `promise` (`concur-promise`): The promise associated with the process.
- `on-stdout-user-cb` (function or nil): The user's callback for stdout chunks.
- `on-stderr-user-cb` (function or nil): The user's callback for stderr chunks.
- `output-to-file-explicit` (boolean or string): The user's `:output-to-file` setting.
- `max-memory-output-bytes` (integer or nil): The memory limit before spilling.
- `output-spilled-p` (boolean): `t` if output has spilled to files.
- `stdout-chunks` (list): List of stdout chunks if in memory mode.
- `stdout-size` (integer): Current accumulated size of stdout chunks.
- `stdout-file-path` (string or nil): Path to stdout temp file if spilled.
- `stdout-file-fd` (file-descriptor or nil): FD for stdout temp file.
- `stdout-file-buffer` (string): Internal buffer for batching stdout file writes.
- `stderr-chunks` (list): List of stderr chunks if in memory mode.
- `stderr-size` (integer): Current accumulated size of stderr chunks.
- `stderr-file-path` (string or nil): Path to stderr temp file if spilled.
- `stderr-file-fd` (file-descriptor or nil): FD for stderr temp file.
- `stderr-file-buffer` (string): Internal buffer for batching stderr file writes."
  cmd-exe promise on-stdout-user-cb on-stderr-user-cb
  output-to-file-explicit max-memory-output-bytes
  (output-spilled-p nil :type boolean)
  (stdout-chunks nil :type list)
  (stdout-size 0 :type integer)
  (stdout-file-path nil :type (or string null))
  stdout-file-fd
  (stdout-file-buffer "" :type string)
  (stderr-chunks nil :type list)
  (stderr-size 0 :type integer)
  (stderr-file-path nil :type (or string null))
  stderr-file-fd
  (stderr-file-buffer "" :type string))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Utilities

(defun concur--filter-plist (plist keys-to-remove)
  "Return a copy of PLIST with KEYS-TO-REMOVE and their values removed."
  (let (new-plist)
    (while plist
      (let ((k (pop plist)) (v (pop plist)))
        (unless (member k keys-to-remove)
          (setq new-plist (nconc new-plist (list k v))))))
    new-plist))

(defun concur--delete-file-if-exists (file-path)
  "Delete FILE-PATH if it exists, logging any errors."
  (when (and file-path (file-exists-p file-path))
    (condition-case err
        (delete-file file-path)
      (error (concur--log :error "Failed to delete temporary file %s: %S"
                          file-path err)))))

(defvar concur--deferred-cleanup-timer nil
  "Timer for deferred file cleanup.")

(defvar concur--files-to-delete-deferred nil
  "A list of file paths to be deleted by `concur--deferred-cleanup-timer`.")

(defun concur--delete-files-deferred (files)
  "Add FILES to a list for deferred deletion.
This is used for cleaning up temporary files from process results,
such as those created by `concur:pipe!` or when output spills to disk."
  (when files
    (setq concur--files-to-delete-deferred
          (nconc concur--files-to-delete-deferred (remq nil files)))
    (unless (and concur--deferred-cleanup-timer
                 (timerp concur--deferred-cleanup-timer))
      (setq concur--deferred-cleanup-timer
            (run-with-idle-timer 5.0 t #'concur--process-deferred-deletions)))))

(defun concur--process-deferred-deletions ()
  "Process the list of files for deferred deletion."
  (let ((files-to-process concur--files-to-delete-deferred))
    (setq concur--files-to-delete-deferred nil)
    (dolist (file files-to-process)
      (concur--delete-file-if-exists file)))
  (when (null concur--files-to-delete-deferred)
    (when (timerp concur--deferred-cleanup-timer)
      (cancel-timer concur--deferred-cleanup-timer))
    (setq concur--deferred-cleanup-timer nil)))

(defun concur--kill-process-buffers (stdout-buf stderr-buf)
  "Safely kill the stdout and stderr buffers if they are live."
  (when (and stdout-buf (buffer-live-p stdout-buf))
    (kill-buffer stdout-buf))
  (when (and stderr-buf (buffer-live-p stderr-buf))
    (kill-buffer stderr-buf)))

(cl-defun concur--create-temp-file-for-output (cmd-name stream-name)
  "Creates a temporary file for stdout or stderr and returns a plist.

Arguments:
- CMD-NAME (string): The name of the command executable.
- STREAM-NAME (string): The name of the stream (e.g., \"stdout\").

Returns:
- (plist): A plist of the form `(:path PATH :fd FD)`."
  (let* ((path (make-temp-file (format "concur-%s-%s-" cmd-name stream-name)))
         (fd (cl-open path :direction 'output
                      :if-exists 'supersede :if-does-not-exist 'create)))
    (concur--log :debug "Created temp file %S for %S %S." path cmd-name stream-name)
    `(:path ,path :fd ,fd)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Common Process Execution Helpers

(cl-defun concur--format-process-result (cmd args stdout stderr exit-code
                                          &key discard-ansi die-on-error
                                          cwd env process-status signal)
  "Formats raw process output into a result struct or an error condition."
  (let ((clean-stdout (if discard-ansi (ansi-color-filter-apply stdout) stdout)))
    (if (and die-on-error (/= exit-code 0))
        `(concur-exec-error .
          ,(make-concur-exec-error-info
            :message (format "Command '%s' failed with exit code %d"
                             (s-join " " (cons cmd args)) exit-code)
            :exit-code exit-code :stdout clean-stdout :stderr stderr
            :cmd cmd :args args :cwd cwd :env env
            :process-status process-status :signal signal))
      (make-concur-process-result
       :cmd cmd :args args :exit exit-code
       :stdout clean-stdout :stderr stderr))))

(cl-defun concur--start-process (name-prefix command args
                                 &key cwd env sentinel filter
                                 stdout-buf stderr-buf merge-stderr)
  "Initializes and returns a new Emacs process."
  (let ((default-directory (or cwd default-directory))
        (process-environment
         (if env (append (seq-map (lambda (it) (format "%s=%s" (car it) (cdr it)))
                                  env)
                         process-environment)
           process-environment)))
    (make-process
     :name (format "%s-%s" name-prefix (file-name-nondirectory command))
     :buffer stdout-buf
     :command (cons command (or args '()))
     :stderr (if merge-stderr t stderr-buf)
     :noquery t
     :sentinel sentinel
     :filter filter
     :connection-type 'pipe)))

(cl-defun concur--setup-process-context (promise proc
                                         &key command args discard-ansi
                                         die-on-error cancel-token
                                         timeout cwd env cleanup-stdin-file)
  "Attaches common context properties to a process object and sets up handlers."
  (setf (concur-promise-proc promise) proc)
  (process-put proc 'concur-promise promise)
  (process-put proc 'concur-command command)
  (process-put proc 'concur-args args)
  (process-put proc 'concur-discard-ansi discard-ansi)
  (process-put proc 'concur-die-on-error die-on-error)
  (process-put proc 'concur-cwd cwd)
  (process-put proc 'concur-env env)
  (process-put proc 'concur-cleanup-stdin-file cleanup-stdin-file)

  (when timeout
    (let ((timer (run-at-time
                  timeout nil
                  (lambda ()
                    (when (process-live-p proc)
                      (kill-process proc)
                      (concur:reject
                       promise `(concur-exec-timeout .
                                 ,(make-concur-exec-error-info
                                   :reason :timeout :timeout timeout
                                   :message (format "Cmd '%s' timed out" command)
                                   :cmd command :args args))))))))
      (process-put proc 'concur-timeout-timer timer)))

  (when cancel-token
    (concur:cancel-token-on-cancel
     cancel-token
     (lambda ()
       (when (process-live-p proc)
         (kill-process proc)
         (concur:reject promise
                        `(concur-exec-cancelled .
                          ,(make-concur-exec-error-info
                            :reason :cancelled
                            :message (format "Process '%s' cancelled" command)
                            :cmd command :args args))))))))

(cl-defun concur--handle-creation-error (promise err &key command args cwd)
  "Handles process creation errors, ensuring promise rejection."
  (let ((error-info `(concur-exec-creation-error .
                      ,(make-concur-exec-error-info
                        :message (error-message-string err)
                        :original-error err
                        :cmd command :args args :cwd cwd
                        :reason :creation-error))))
    (concur--log :error "Process creation for '%s' failed: %s"
                 command (error-message-string err))
    (concur:reject promise error-info)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Process Execution (`concur:process`)

(defun concur--process-handle-output-chunk-for-stream
    (chunk output-state stream-type)
  "Helper to handle an output `chunk` for a specific stream.
This function implements the core output management logic:
1. Fire user-provided streaming callbacks.
2. If already spilling to a file, write the chunk.
3. If accumulating in memory, check if this chunk exceeds the
   `max-memory-output` threshold. If so, initiate a spill, writing
   all previously buffered chunks and the current one to new temp files.
4. Otherwise, append the chunk to the in-memory list.

Arguments:
- CHUNK (string): The piece of output from the process filter.
- OUTPUT-STATE (`concur-process-output-state`): The state object for this process.
- STREAM-TYPE (symbol): Either `'stdout` or `'stderr`.

Returns:
- nil."
  (let* ((on-user-cb (if (eq stream-type 'stdout)
                         (concur-process-output-state-on-stdout-user-cb output-state)
                       (concur-process-output-state-on-stderr-user-cb output-state)))
         (is-stdout (eq stream-type 'stdout)))

    ;; 1. Fire user callback if it exists.
    (when on-user-cb (funcall on-user-cb chunk))

    (let* ((spilled-p (concur-process-output-state-output-spilled-p output-state))
           (max-mem (concur-process-output-state-max-memory-output-bytes output-state))
           (current-size (if is-stdout
                             (concur-process-output-state-stdout-size output-state)
                           (concur-process-output-state-stderr-size output-state)))
           (file-path-sym (if is-stdout 'stdout-file-path 'stderr-file-path))
           (file-fd-sym (if is-stdout 'stdout-file-fd 'stderr-file-fd))
           (chunks-sym (if is-stdout 'stdout-chunks 'stderr-chunks))
           (size-sym (if is-stdout 'stdout-size 'stderr-size))
           (buffer-sym (if is-stdout 'stdout-file-buffer 'stderr-file-buffer)))
      (cond
       ;; Case 2: Output is already spilling to file. Append to buffer and flush if full.
       (spilled-p
        (let* ((fd (slot-value output-state file-fd-sym))
               (buffer (slot-value output-state buffer-sym)))
          (when fd
            (setf (slot-value output-state buffer-sym) (concat buffer chunk))
            (when (>= (length (slot-value output-state buffer-sym))
                      concur-output-file-buffer-size)
              (file-write-string (slot-value output-state buffer-sym) fd)
              (setf (slot-value output-state buffer-sym) "")))))

       ;; Case 3: In memory, check if this chunk triggers a spill.
       ((and (not spilled-p) max-mem (> max-mem 0)
             (> (+ current-size (length chunk)) max-mem))
        ;; Initiate spilling to file for both stdout and stderr.
        (setf (concur-process-output-state-output-spilled-p output-state) t)
        (let* ((exe (concur-process-output-state-cmd-exe output-state))
               (stdout-info (concur--create-temp-file-for-output exe "stdout"))
               (stderr-info (concur--create-temp-file-for-output exe "stderr")))
          ;; Set up file paths and FDs.
          (setf (concur-process-output-state-stdout-file-path output-state) (plist-get stdout-info :path))
          (setf (concur-process-output-state-stdout-file-fd output-state) (plist-get stdout-info :fd))
          (setf (concur-process-output-state-stderr-file-path output-state) (plist-get stderr-info :path))
          (setf (concur-process-output-state-stderr-file-fd output-state) (plist-get stderr-info :fd))
          ;; Write all existing in-memory chunks to their respective files.
          (dolist (c (nreverse (concur-process-output-state-stdout-chunks output-state)))
            (file-write-string c (plist-get stdout-info :fd)))
          (dolist (c (nreverse (concur-process-output-state-stderr-chunks output-state)))
            (file-write-string c (plist-get stderr-info :fd)))
          ;; Clear in-memory chunks.
          (setf (concur-process-output-state-stdout-chunks output-state) nil)
          (setf (concur-process-output-state-stderr-chunks output-state) nil)
          ;; Write the current chunk that triggered the spill.
          (file-write-string chunk (slot-value output-state file-fd-sym))))

       ;; Case 4: Accumulate in memory.
       (t (push chunk (slot-value output-state chunks-sym))
          (cl-incf (slot-value output-state size-sym) (length chunk)))))))

(defun concur--process-filter-handler-internal (process chunk output-state)
  "Internal filter. Dispatches chunks to the correct stream handler."
  (if (eq (current-buffer) (process-buffer process))
      (concur--process-handle-output-chunk-for-stream chunk output-state 'stdout)
    (concur--process-handle-output-chunk-for-stream chunk output-state 'stderr)))

(defun concur--process-flush-output-buffers-to-files (output-state)
  "Flushes any remaining buffered output in `output-state` to its files."
  (when (concur-process-output-state-output-spilled-p output-state)
    (when-let ((fd (concur-process-output-state-stdout-file-fd output-state)))
      (file-write-string (concur-process-output-state-stdout-file-buffer output-state) fd))
    (when-let ((fd (concur-process-output-state-stderr-file-fd output-state)))
      (file-write-string (concur-process-output-state-stderr-file-buffer output-state) fd))))

(defun concur--process-close-temp-file-fds (output-state)
  "Closes temporary file descriptors stored in `output-state`."
  (when-let ((fd (concur-process-output-state-stdout-file-fd output-state)))
    (ignore-errors (close fd))
    (setf (concur-process-output-state-stdout-file-fd output-state) nil))
  (when-let ((fd (concur-process-output-state-stderr-file-fd output-state)))
    (ignore-errors (close fd))
    (setf (concur-process-output-state-stderr-file-fd output-state) nil)))

(defun concur--process-finalize-result-and-settle (process _event output-state)
  "Finalizes the process result and settles the associated promise.
This is the core logic of the process sentinel. It performs all cleanup
and resolves or rejects the promise."
  (let* ((promise (concur-process-output-state-promise output-state))
         (timer (process-get process 'concur-timeout-timer))
         (cmd (process-get process 'concur-command))
         (args (process-get process 'concur-args))
         (discard-ansi (process-get process 'concur-discard-ansi))
         (die-on-error (process-get process 'concur-die-on-error))
         (cwd (process-get process 'concur-cwd))
         (env (process-get process 'concur-env))
         (exit-code (process-exit-status process))
         (status (process-status process))
         (signal (if (eq status 'signal) (process-signal-process process) nil))
         (stdin-file-to-clean (process-get process 'concur-cleanup-stdin-file)))

    ;; 1. Stop timeout timer.
    (when (timerp timer) (cancel-timer timer))

    ;; 2. Flush and close any open temp file resources.
    (concur--process-flush-output-buffers-to-files output-state)
    (concur--process-close-temp-file-fds output-state)

    ;; 3. Kill dummy buffers used by the process.
    (concur--kill-process-buffers (process-buffer process)
                                  (process-stderr-buffer process))

    ;; 4. Clean up temporary stdin file if one was created.
    (when stdin-file-to-clean (concur--delete-files-deferred (list stdin-file-to-clean)))

    ;; 5. Settle the promise if it's still pending.
    (when (concur:pending-p promise)
      (let* ((spilled (concur-process-output-state-output-spilled-p output-state))
             (stdout-path (concur-process-output-state-stdout-file-path output-state))
             (stderr-path (concur-process-output-state-stderr-file-path output-state))
             (stdout (if spilled stdout-path
                       (s-join "" (nreverse
                                   (concur-process-output-state-stdout-chunks
                                    output-state)))))
             (stderr (if spilled stderr-path
                       (s-join "" (nreverse
                                   (concur-process-output-state-stderr-chunks
                                    output-state))))))
        ;; Format the final result object or error.
        (let ((result-or-error
               (concur--format-process-result cmd args stdout stderr exit-code
                ;; ANSI codes are only discarded if output was in memory.
                :discard-ansi (and discard-ansi (not spilled))
                :die-on-error die-on-error
                :cwd cwd :env env :process-status status :signal signal)))

          ;; Schedule temp files for cleanup.
          (when spilled (concur--delete-files-deferred (list stdout-path stderr-path)))

          ;; Settle the promise.
          (if (consp result-or-error)
              (concur:reject promise (cdr result-or-error))
            (setf (concur-process-result-stdout-file-path result-or-error) stdout-path)
            (setf (concur-process-result-stderr-file-path result-or-error) stderr-path)
            (concur:resolve promise result-or-error)))))))

(defun concur--process-sentinel-handler (process event)
  "Sentinel for `concur:process`."
  (when (memq (process-status process) '(exit signal finished))
    (concur--process-finalize-result-and-settle
     process event (process-get process 'concur-output-state))))

;;;###autoload
(cl-defun concur:process (&key command args cwd env discard-ansi die-on-error
                               stdin stdin-file merge-stderr cancel-token
                               timeout on-stdout on-stderr output-to-file
                               max-memory-output cleanup-stdin-file)
  "Run COMMAND asynchronously, capturing output to memory or files.
This is the core process execution primitive. It returns a promise that
resolves with a `concur-process-result` struct upon completion.

Output is accumulated in memory by default. If `:output-to-file` is set,
or if the accumulated output exceeds `:max-memory-output`, the output will
be spilled to temporary files. In this case, the `stdout`/`stderr` fields
in the result struct will contain the paths to these files.

Arguments:
- `command` (string): The executable command to run.
- `args` (list of string): Arguments for the command.
- `cwd` (string, optional): The working directory for the process.
- `env` (alist, optional): Environment variables to set, e.g., `'((\"VAR\" . \"val\"))`.
- `discard-ansi` (boolean, optional): If t, remove ANSI escape codes from
  stdout. This only applies when output is captured in memory.
- `die-on-error` (boolean, optional): If t, reject the promise on a non-zero
  exit code. If nil, the promise resolves with the failure result.
- `stdin` (string, optional): A string to send to the process's standard input.
- `stdin-file` (string, optional): Path to a file to use for stdin. Overrides `stdin`.
- `merge-stderr` (boolean, optional): If t, merge stderr into the stdout stream.
- `cancel-token` (`concur-cancel-token`, optional): A token to cancel the process.
- `timeout` (number, optional): Timeout in seconds.
- `on-stdout` (function, optional): A callback `(lambda (string))` for stdout
  chunks. This is fired in addition to internal capture.
- `on-stderr` (function, optional): A callback `(lambda (string))` for stderr
  chunks.
- `output-to-file` (boolean or string): If t, stream output directly to temp
  files. If a string, use it as a base name for the files.
- `max-memory-output` (integer): Max bytes to store in memory before spilling
  to a temp file. Defaults to 1MB. Ignored if `:output-to-file` is set.
- `cleanup-stdin-file` (boolean, optional): If t, delete the `stdin-file`
  after the process finishes. Used by `concur:pipe!`.

Returns:
- (`concur-promise`): A promise that resolves to a `concur-process-result`
  struct or rejects with a `concur-exec-error-info` struct."
  (let* ((promise (concur:make-promise :cancel-token cancel-token))
         (output-state
          (make-concur-process-output-state
           :cmd-exe command :promise promise :on-stdout-user-cb on-stdout
           :on-stderr-user-cb on-stderr :output-to-file-explicit output-to-file
           :max-memory-output-bytes (unless output-to-file
                                      (or max-memory-output (* 1024 1024))))))
    (unwind-protect
        (condition-case err
            (let (proc stdout-buf stderr-buf)
              ;; Create dummy buffers for the process filter to distinguish streams.
              (setq stdout-buf (generate-new-buffer "*concur-stdout-dummy*"))
              (unless merge-stderr
                (setq stderr-buf (generate-new-buffer "*concur-stderr-dummy*")))

              ;; Start the process with our custom filter and sentinel.
              (setq proc
                    (concur--start-process
                     "concur" command args :cwd cwd :env env
                     :sentinel #'concur--process-sentinel-handler
                     :filter (lambda (p c)
                               (concur--process-filter-handler-internal
                                p c output-state))
                     :stdout-buf stdout-buf :stderr-buf stderr-buf
                     :merge-stderr merge-stderr))

              ;; Attach all necessary context to the process object.
              (process-put proc 'concur-output-state output-state)
              (concur--setup-process-context
               promise proc :command command :args args :discard-ansi discard-ansi
               :die-on-error die-on-error :cancel-token cancel-token
               :timeout timeout :cwd cwd :env env
               :cleanup-stdin-file cleanup-stdin-file)

              ;; Handle stdin.
              (cond (stdin-file
                     (process-send-region proc (point-min) (point-max) stdin-file))
                    (stdin (process-send-string proc stdin)))
              (when (or stdin stdin-file) (process-send-eof proc)))
          ;; Handle synchronous errors during process creation.
          (error (concur--handle-creation-error promise err
                                                :command command :args args
                                                :cwd cwd))))
    promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; High-level `concur:command` and `concur:pipe!`

;;;###autoload
(defmacro concur:command (command &rest keys)
  "Run COMMAND and return a promise that resolves to its result.
This is a high-level, user-friendly wrapper around `concur:process`. It
simplifies calling commands by allowing the command and its arguments to be
specified as a single string.

Arguments:
- `COMMAND` (string or list): The command to run. If a string (e.g.,
  `\"ls -la\"`), it is split into an executable and arguments. If a list
  (e.g., `'(\"ls\" \"-la\")`), it is used directly.
- `KEYS` (plist): Options passed directly to `concur:process`. For example,
  `:die-on-error`, `:cwd`, `:on-stdout`.

Returns:
- (`concur-promise`): A promise for the result of the command."
  (declare (indent 1) (debug t))
  (let ((cmd (gensym "cmd-"))
        (cmd-args (gensym "cmd-args-")))
    `(let (,cmd ,cmd-args)
       (if (stringp ,command)
           (let ((parts (s-split " " ,command t)))
             (setq ,cmd (car parts))
             (setq ,cmd-args (cdr parts)))
         (setq ,cmd (car ,command))
         (setq ,cmd-args (cdr ,command)))
       (apply #'concur:process :command ,cmd
              (append (list :args ,cmd-args) (list ,@keys))))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands, piping stdout of one to stdin of the next.
Each command in `COMMAND-FORMS` is a `concur:command` invocation,
e.g., `(\"ls -l\")` or `(\"grep .el\" :die-on-error nil)`.

Intermediate command output is automatically streamed to temporary files,
which are then used as stdin for the next command and cleaned up afterward.

Arguments:
- `COMMAND-FORMS` (forms): A sequence of command forms to be piped together.

Returns:
- (`concur-promise`): A promise for the result of the final command in the
  pipeline."
  (declare (indent 1) (debug t))
  (unless command-forms (error "concur:pipe! requires at least one command"))
  (if (= 1 (length command-forms))
      `(concur:command ,@(car command-forms))
    (let ((chain (gensym "pipe-chain-")))
      `(let ((,chain
              ;; The first command must output to a file for the pipe.
              (concur:command ,@(car command-forms) :output-to-file t)))
         ,@(cl-loop for form in (cdr command-forms)
                    for i from 1
                    collect
                    (let* ((is-last (= i (1- (length command-forms))))
                           (prev-res (gensym "prev-res-")))
                      ;; Build a chain of `.then` calls.
                      `(setq ,chain
                             (concur:then
                              ,chain
                              (lambda (,prev-res)
                                (concur:command
                                 ,@form
                                 ;; Use the output file from the previous command as stdin.
                                 :stdin-file (concur-process-result-stdout
                                              ,prev-res)
                                 ;; Tell the new process to clean up this temp file.
                                 :cleanup-stdin-file (concur-process-result-stdout
                                                      ,prev-res)
                                 ;; Ensure intermediate commands also output to a file.
                                 ,@(unless is-last
                                     '(:output-to-file t))))))))
         ,chain))))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr &rest keys)
  "Define NAME as a function that runs an async command via `concur:command`.
This creates a convenient, reusable wrapper around a common command pattern.
The defined function accepts keyword arguments that override the defaults
provided in `KEYS`.

Arguments:
- `NAME` (symbol): The symbol name for the new function.
- `ARGLIST` (list): Argument list for the new function.
- `DOCSTRING` (string): Docstring for the new function.
- `COMMAND-EXPR` (form): A form that evaluates to the command string/list.
- `KEYS` (plist): Default keys for `concur:command` (e.g., `:die-on-error t`).

Returns:
- (symbol): The function name, `NAME`."
  (declare (indent 1) (debug t))
  (let* ((interactive-spec (plist-get keys :interactive))
         (default-keys (concur--filter-plist keys '(:interactive)))
         (args-sym (make-symbol "args")))
    `(defun ,name (,@arglist &rest ,args-sym)
       ,docstring
       ,@(when interactive-spec `((interactive ,interactive-spec)))
       (let ((command ,command-expr))
         (apply #'concur:command command
                (append ,args-sym (list ,@default-keys)))))))

(provide 'concur-exec)
;;; concur-exec.el ends here