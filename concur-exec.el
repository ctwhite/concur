;;; concur-exec.el --- Asynchronous Process Execution with Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a robust framework for running external commands
;; asynchronously, handling their results with promises. It streamlines common
;; patterns for process execution and chaining, offering a high-level API over
;; raw Emacs processes. This version is compatible with Emacs 26.1+.
;;
;; At its core, this module offers a single, powerful process primitive:
;;
;; 1. `concur:process`: A versatile, non-coroutine-based process execution
;;    function that intelligently manages output. It can accumulate output
;;    in memory, stream it to user-provided callbacks, or spill it to a
;;    temporary file if a size threshold is exceeded.
;;
;; Building on this primitive, the library provides high-level macros:
;;
;; - `concur:command`: A robust and user-friendly wrapper around
;;   `concur:process` that simplifies common execution patterns and correctly
;;   parses and merges arguments. It also accepts `:dir` as an alias for
;;   the standard `:cwd`.
;;
;; - `concur:pipe!`: A macro for elegantly chaining multiple commands, piping
;;   the stdout of one to the stdin of the next.
;;
;; - `concur:define-command!`: A convenience macro for defining reusable
;;   asynchronous command functions with default arguments.

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

(defconst concur--output-file-buffer-size 16384
  "Size in bytes for the internal buffer used when writing to temp files.")

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
- `reason` (symbol or nil): High-level reason (e.g., `:timeout`)."
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
  process-status
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
- `stderr` (string): Captured standard error content.
- `stdout-file-path` (string or nil): Path to the temp file if stdout spilled.
- `stderr-file-path` (string or nil): Path to the temp file if stderr 
spilled."
  (cmd "" :type string)
  (args nil :type list)
  (exit 0 :type integer)
  (stdout "" :type string)
  (stderr "" :type string)
  (stdout-file-path nil :type (or string null))
  (stderr-file-path nil :type (or string null)))

(cl-defstruct (concur-process-output-state
               (:constructor make-concur-process-output-state))
  "Internal state for managing process output accumulation."
  cmd-exe promise on-stdout-user-cb on-stderr-user-cb
  output-to-file-explicit max-memory-output-bytes
  (output-spilled-p nil :type boolean)
  (stdout-chunks nil :type list)
  (stdout-size 0 :type integer)
  stdout-file-path
  (stderr-chunks nil :type list)
  (stderr-size 0 :type integer)
  stderr-file-path)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Utilities (File-Local)

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
  "Add FILES to a list for deferred deletion."
  (when files
    (concur--log :debug "Scheduling %d file(s) for deferred deletion." (length files))
    (setq concur--files-to-delete-deferred
          (nconc concur--files-to-delete-deferred (remq nil files)))
    (unless (and concur--deferred-cleanup-timer
                 (timerp concur--deferred-cleanup-timer))
      (setq concur--deferred-cleanup-timer
            (run-with-idle-timer 5.0 t #'concur--process-deferred-deletions)))))

(defun concur--process-deferred-deletions ()
  "Process the list of files for deferred deletion."
  (let ((files-to-process concur--files-to-delete-deferred))
    (concur--log :info "Running deferred cleanup for %d file(s)."
                 (length files-to-process))
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
    (concur--log :debug "Killing stdout dummy buffer: %S" stdout-buf)
    (kill-buffer stdout-buf))
  (when (and stderr-buf (buffer-live-p stderr-buf))
    (concur--log :debug "Killing stderr dummy buffer: %S" stderr-buf)
    (kill-buffer stderr-buf)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Common Process Execution Helpers (File-Local)

(defun concur--get-signal-from-event (event-string)
  "Parse a process sentinel EVENT-STRING to extract a signal name.
This provides compatibility for Emacs versions before 27.1."
  (when (string-match "signal-killed-by-\\([A-Z]+\\)" event-string)
    (match-string 1 event-string)))

(cl-defun concur--format-process-result (cmd args stdout stderr exit-code
                                          &key discard-ansi die-on-error
                                          cwd env process-status signal)
  "Format raw process output into a result struct or an error condition."
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
  "Initialize and return a new Emacs process."
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
                                         timeout cwd env cleanup-stdin-file
                                         stdout-buffer stderr-buffer)
  "Attach common context properties to a process object and set up handlers."
  (setf (concur-promise-proc promise) proc)
  (process-put proc 'concur-promise promise)
  (process-put proc 'concur-command command)
  (process-put proc 'concur-args args)
  (process-put proc 'concur-discard-ansi discard-ansi)
  (process-put proc 'concur-die-on-error die-on-error)
  (process-put proc 'concur-cwd cwd)
  (process-put proc 'concur-env env)
  (process-put proc 'concur-cleanup-stdin-file cleanup-stdin-file)
  (process-put proc 'concur-stdout-buffer stdout-buffer)
  (process-put proc 'concur-stderr-buffer stderr-buffer)

  (when timeout
    (concur--log :debug "Setting %ds timeout for process '%s'" timeout command)
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
    (concur--log :debug "Attaching cancel token to process '%s'" command)
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

;; **BUG FIX**: Changed from `defun` to `cl-defun` to correctly handle `&key`
;; arguments and prevent byte-compiler arity warnings.
(cl-defun concur--handle-creation-error (promise err &key command args cwd)
  "Handle process creation errors, ensuring promise rejection."
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
  "Helper to handle an output `chunk` for a specific stream."
  (let* ((on-user-cb (if (eq stream-type 'stdout)
                         (concur-process-output-state-on-stdout-user-cb output-state)
                       (concur-process-output-state-on-stderr-user-cb output-state)))
         (is-stdout (eq stream-type 'stdout)))
    (when on-user-cb (funcall on-user-cb chunk))
    (let* ((spilled-p (concur-process-output-state-output-spilled-p output-state))
           (max-mem (concur-process-output-state-max-memory-output-bytes output-state))
           (current-size (if is-stdout
                             (concur-process-output-state-stdout-size output-state)
                           (concur-process-output-state-stderr-size output-state)))
           (file-path-sym (if is-stdout 'stdout-file-path 'stderr-file-path))
           (chunks-sym (if is-stdout 'stdout-chunks 'stderr-chunks))
           (size-sym (if is-stdout 'stdout-size 'stderr-size)))
      (cond
       (spilled-p
        (when-let ((path (slot-value output-state file-path-sym)))
          (with-temp-buffer
            (insert chunk)
            (append-to-file (point-min) (point-max) path))))

       ((and (not spilled-p) max-mem (> max-mem 0)
             (> (+ current-size (length chunk)) max-mem))
        (concur--log :info "Output for '%s' exceeded %d bytes. Spilling to file."
                     (concur-process-output-state-cmd-exe output-state) max-mem)
        (setf (concur-process-output-state-output-spilled-p output-state) t)
        (let* ((exe (concur-process-output-state-cmd-exe output-state))
               (stdout-path (make-temp-file (format "concur-%s-stdout-" exe)))
               (stderr-path (make-temp-file (format "concur-%s-stderr-" exe))))
          (setf (slot-value output-state 'stdout-file-path) stdout-path)
          (setf (slot-value output-state 'stderr-file-path) stderr-path)
          (with-temp-buffer
            (dolist (c (nreverse (slot-value output-state 'stdout-chunks))) (insert c))
            (write-file stdout-path))
          (with-temp-buffer
            (dolist (c (nreverse (slot-value output-state 'stderr-chunks))) (insert c))
            (write-file stderr-path))
          (setf (slot-value output-state 'stdout-chunks) nil)
          (setf (slot-value output-state 'stderr-chunks) nil)
          (with-temp-buffer
            (insert chunk)
            (append-to-file (point-min) (point-max) (slot-value output-state file-path-sym)))))

       (t (push chunk (slot-value output-state chunks-sym))
          (cl-incf (slot-value output-state size-sym) (length chunk)))))))

(defun concur--process-filter-handler-internal (process chunk output-state)
  "Internal filter. Dispatches chunks to the correct stream handler."
  (if (eq (current-buffer) (process-buffer process))
      (concur--process-handle-output-chunk-for-stream chunk output-state 'stdout)
    (concur--process-handle-output-chunk-for-stream chunk output-state 'stderr)))

(defun concur--process-finalize-result-and-settle (process event output-state)
  "Finalize the process result and settles the associated promise."
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
         (signal (when (eq status 'signal) (concur--get-signal-from-event event)))
         (stdin-file-to-clean (process-get process 'concur-cleanup-stdin-file)))

    (concur--log :debug "Sentinel fired for '%s'. Event: %s" cmd event)
    (when (timerp timer) (cancel-timer timer))

    (concur--kill-process-buffers (process-get process 'concur-stdout-buffer)
                                  (process-get process 'concur-stderr-buffer))

    (when stdin-file-to-clean
      (concur--delete-files-deferred (list stdin-file-to-clean)))

    (when (concur:pending-p promise)
      (let* ((spilled (concur-process-output-state-output-spilled-p output-state))
             (stdout-path (concur-process-output-state-stdout-file-path output-state))
             (stderr-path (concur-process-output-state-stderr-file-path output-state))
             (stdout (if spilled stdout-path
                       (s-join "" (nreverse (concur-process-output-state-stdout-chunks output-state)))))
             (stderr (if spilled stderr-path
                       (s-join "" (nreverse (concur-process-output-state-stderr-chunks output-state))))))
        (let ((result-or-error
               (concur--format-process-result cmd args stdout stderr exit-code
                :discard-ansi (and discard-ansi (not spilled))
                :die-on-error die-on-error
                :cwd cwd :env env :process-status status :signal signal)))
          (when spilled
            (concur--delete-files-deferred (list stdout-path stderr-path)))
          (if (consp result-or-error)
              (progn
                (concur--log :warn "Process '%s' failed. Rejecting promise." cmd)
                (concur:reject promise (cdr result-or-error)))
            (progn
              (concur--log :info "Process '%s' succeeded. Resolving promise." cmd)
              (setf (concur-process-result-stdout-file-path result-or-error) stdout-path)
              (setf (concur-process-result-stderr-file-path result-or-error) stderr-path)
              (concur:resolve promise result-or-error))))))))

(defun concur--process-sentinel-handler (process event)
  "Sentinel for `concur:process`."
  (when (memq (process-status process) '(exit signal finished))
    (concur--process-finalize-result-and-settle
     process event (process-get process 'concur-output-state))))

;;;###autoload
(cl-defun concur:process (&rest plist)
  "Run COMMAND asynchronously, capturing output to memory or files.
This is the core process execution primitive. It returns a promise that
resolves with a `concur-process-result` struct upon completion.

Output is accumulated in memory by default. If `:output-to-file` is set,
or if output exceeds `:max-memory-output`, it spills to temporary files.
In this case, the `stdout`/`stderr` fields in the result struct will
contain the paths to these files.

Arguments:
  PLIST (plist): A property list of options.
    - `:command` (string): The executable command to run.
    - `:args` (list of string): Arguments for the command.
    - See the `concur-exec.el` file header for all other options.

Returns:
  (`concur-promise`): A promise that resolves to a `concur-process-result`
  struct or rejects with a `concur-exec-error-info` struct."
  (let* ((command (plist-get plist :command))
         (args (plist-get plist :args))
         (cwd (plist-get plist :cwd))
         (env (plist-get plist :env))
         (stdin (plist-get plist :stdin))
         (stdin-file (plist-get plist :stdin-file))
         (merge-stderr (plist-get plist :merge-stderr))
         (cancel-token (plist-get plist :cancel-token))
         (timeout (plist-get plist :timeout))
         (on-stdout (plist-get plist :on-stdout))
         (on-stderr (plist-get plist :on-stderr))
         (output-to-file (plist-get plist :output-to-file))
         (promise (concur:make-promise :cancel-token cancel-token))
         (output-state
          (make-concur-process-output-state
           :cmd-exe command :promise promise :on-stdout-user-cb on-stdout
           :on-stderr-user-cb on-stderr :output-to-file-explicit output-to-file
           :max-memory-output-bytes (unless output-to-file
                                      (or (plist-get plist :max-memory-output)
                                          (* 1024 1024))))))
    (concur--log :info "Starting process: `%s %s' with options %S"
                 command (s-join " " args)
                 (concur--filter-plist plist '(:command :args)))
    (unwind-protect
        (condition-case err
            (let (proc stdout-buf stderr-buf)
              (setq stdout-buf (generate-new-buffer "*concur-stdout-dummy*"))
              (unless merge-stderr
                (setq stderr-buf (generate-new-buffer "*concur-stderr-dummy*")))
              (let ((process-connection-type nil)) ; Use default pipe
                (setq proc
                      (concur--start-process
                       "concur" command args :cwd cwd :env env
                       :sentinel #'concur--process-sentinel-handler
                       :filter (lambda (p c)
                                 (concur--process-filter-handler-internal
                                  p c output-state))
                       :stdout-buf stdout-buf :stderr-buf stderr-buf
                       :merge-stderr merge-stderr)))
              (process-put proc 'concur-output-state output-state)
              (concur--setup-process-context
               promise proc :command command :args args
               :cancel-token cancel-token :timeout timeout :cwd cwd :env env
               :discard-ansi (plist-get plist :discard-ansi)
               :die-on-error (plist-get plist :die-on-error)
               :cleanup-stdin-file (plist-get plist :cleanup-stdin-file)
               :stdout-buffer stdout-buf :stderr-buffer stderr-buf)
              (cond (stdin-file
                     (with-temp-buffer
                       (insert-file-contents stdin-file)
                       (process-send-region proc (point-min) (point-max))))
                    (stdin (process-send-string proc stdin)))
              (when (or stdin stdin-file) (process-send-eof proc)))
          (error (concur--handle-creation-error promise err
                                                :command command :args args
                                                :cwd cwd))))
    promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; High-level `concur:command` and `concur:pipe!`

(defun concur--parse-command-args (command-form keys)
  "Internal helper to parse and merge arguments for `concur:command`."
  (let (cmd cmd-args final-keys)
    (if (stringp command-form)
        (let ((parts (s-split " " command-form t)))
          (setq cmd (car parts))
          (setq cmd-args (cdr parts)))
      (setq cmd (car command-form))
      (setq cmd-args (cdr command-form)))

    (let ((user-args (plist-get keys :args))
          (user-dir (plist-get keys :dir))
          (user-cwd (plist-get keys :cwd))
          (other-keys (concur--filter-plist keys '(:args :dir :cwd))))
      (setq cmd-args (append cmd-args user-args))
      (let ((final-cwd (or user-cwd user-dir)))
        (setq final-keys (if final-cwd
                             (append (list :cwd final-cwd) other-keys)
                           other-keys))))
    (concur--log :debug "Parsed command: '%s' with args: %S" cmd cmd-args)
    (list cmd cmd-args final-keys)))

;;;###autoload
(defmacro concur:command (command &rest keys)
  "Run COMMAND and return a promise that resolves to its result.
This is a high-level, user-friendly wrapper around `concur:process`."
  (declare (indent 1) (debug t))
  (let ((parsed (gensym "parsed-"))
        (cmd (gensym "cmd-"))
        (cmd-args (gensym "cmd-args-"))
        (final-keys (gensym "final-keys-")))
    `(let* ((,parsed (concur--parse-command-args ,command (list ,@keys)))
            (,cmd (car ,parsed))
            (,cmd-args (cadr ,parsed))
            (,final-keys (caddr ,parsed)))
       (apply #'concur:process :command ,cmd :args ,cmd-args ,final-keys))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands, piping stdout of one to stdin of the next."
  (declare (indent 1) (debug t))
  (unless command-forms (error "concur:pipe! requires at least one command"))
  (if (= 1 (length command-forms))
      `(concur:command ,@(car command-forms))
    (let ((chain (gensym "pipe-chain-")))
      `(let ((,chain
              (concur:command ,@(car command-forms) :output-to-file t)))
         ,@(cl-loop for form in (cdr command-forms)
                    for i from 1
                    collect
                    (let* ((is-last (= i (1- (length command-forms))))
                           (prev-res (gensym "prev-res-")))
                      `(setq ,chain
                             (concur:then
                              ,chain
                              (lambda (,prev-res)
                                (concur--log :info "Pipe step: passing output to: %S" ',form)
                                (concur:command
                                 ,@form
                                 :stdin-file (concur-process-result-stdout-file-path
                                              ,prev-res)
                                 :cleanup-stdin-file t
                                 ,@(unless is-last
                                     '(:output-to-file t))))))))
         ,chain))))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr &rest keys)
  "Define NAME as a function that runs an async command via `concur:command`."
  (declare (indent 1) (debug t))
  (let* ((interactive-spec (plist-get keys :interactive))
         (default-keys (concur--filter-plist keys '(:interactive)))
         (args-sym (make-symbol "args")))
    `(cl-defun ,name (,@arglist &rest ,args-sym)
       ,docstring
       ,@(when interactive-spec `((interactive ,interactive-spec)))
       (let ((command ,command-expr))
         (apply #'concur:command command
                (append ,args-sym (list ,@default-keys)))))))

(provide 'concur-exec)
;;; concur-exec.el ends here