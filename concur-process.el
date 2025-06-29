;;; concur-process.el --- Async Process Execution with Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a robust, high-level framework for running external
;; commands asynchronously. It is the primary interface for executing standard,
;; one-off external processes within a Concur-based application.
;;
;; The core function, `concur:process`, spawns an external command and returns
;; a promise that is tied to the process's lifecycle. This promise resolves
;; with a result object containing streams for stdout and stderr, allowing for
;; flexible, real-time data processing.
;;
;; For high-frequency or stateful shell commands, users should use the
;; persistent shell pool provided by `concur-shell.el` directly.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'ansi-color)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-stream)
(require 'concur-shell)                ; For pipe/session-based utilities
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Data Structures

(define-error 'concur-process-error "Generic error during process execution." 'concur-error)
(define-error 'concur-process-creation-error "Failed to create the process." 'concur-process-error)
(define-error 'concur-process-exit-error "Process exited with non-zero status." 'concur-process-error)
(define-error 'concur-process-signal-error "Process was killed by a signal." 'concur-process-error)

(cl-defstruct (concur-process-result (:constructor %%make-process-result))
  "Represents the successful result of an external process.
This object is the resolution value of a promise from `concur:process`.

Fields:
- `command` (string): The command executable that was run.
- `args` (list): The list of arguments passed to the command.
- `exit-code` (integer): The final exit code of the process.
- `stdout-stream` (concur-stream): The stream for standard output.
- `stderr-stream` (concur-stream): The stream for standard error."
  command args exit-code stdout-stream stderr-stream)

(cl-defstruct (concur-process-state (:constructor %%make-process-state))
  "Internal state for managing a non-persistent async process."
  promise process command args cwd stdout-stream stderr-stream
  on-stdout-cb on-stderr-cb (die-on-error t) timeout-timer)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Standard Process Lifecycle

(defun concur--proc-reject-promise (process-state error-type message &rest keys)
  "Centralized function to reject a process promise with a rich error object.

Arguments:
- `PROCESS-STATE` (concur-process-state): The state object of the process.
- `ERROR-TYPE` (symbol): The error symbol to signal.
- `MESSAGE` (string): The primary error message.
- `KEYS` (plist): Additional properties for `concur:make-error`."
  (let* ((promise (concur-process-state-promise process-state))
         (error-obj (apply #'concur:make-error
                           :type error-type :message message :promise promise
                           :cmd (concur-process-state-command process-state)
                           :args (concur-process-state-args process-state)
                           :cwd (concur-process-state-cwd process-state)
                           keys)))
    (when-let (s (concur-process-state-stdout-stream process-state))
      (concur:stream-error s error-obj))
    (when-let (s (concur-process-state-stderr-stream process-state))
      (concur:stream-error s error-obj))
    (concur:reject promise error-obj)))

(defun concur--proc-finalize-promise (process-state event)
  "Finalize the promise based on the process termination event.

Arguments:
- `PROCESS-STATE` (concur-process-state): The state object of the process.
- `EVENT` (string): The event string from the process sentinel."
  (let* ((promise (concur-process-state-promise process-state))
         (proc (concur-process-state-process process-state))
         (cmd (concur-process-state-command process-state))
         (exit-code (process-exit-status proc))
         (signal (when (string-match "signal" event)
                   (cadr (s-split "-" event)))))
    (cond
     (signal
      (apply #'concur--proc-reject-promise process-state 'concur-process-signal-error
             (format "Command '%s' killed by signal %s" cmd signal)
             `(:signal ,signal :process-status ,(process-status proc))))
     ((and (/= exit-code 0) (concur-process-state-die-on-error process-state))
      (apply #'concur--proc-reject-promise process-state 'concur-process-exit-error
             (format "Command '%s' exited with code %d" cmd exit-code)
             `(:exit-code ,exit-code :process-status ,(process-status proc))))
     (t
      (concur:resolve
       promise
       (%%make-process-result
        :command cmd :args (concur-process-state-args process-state)
        :exit-code exit-code
        :stdout-stream (concur-process-state-stdout-stream process-state)
        :stderr-stream (concur-process-state-stderr-stream process-state)))))))

(defun concur--proc-sentinel (process event)
  "The main process sentinel for non-persistent processes.
This function cleans up all resources associated with the process.

Arguments:
- `PROCESS` (process): The Emacs process object.
- `EVENT` (string): The event string (e.g., \"finished\")."
  (when (memq (process-status process) '(exit signal finished))
    (when-let ((state (process-get process 'concur-process-state)))
      (when-let (timer (concur-process-state-timeout-timer state))
        (cancel-timer timer))
      (when-let (s (concur-process-state-stdout-stream state)) (concur:stream-close s))
      (when-let (s (concur-process-state-stderr-stream state)) (concur:stream-close s))
      (when (concur:pending-p (concur-process-state-promise state))
        (concur--proc-finalize-promise state event))
      (when-let (buf (process-buffer process)) (ignore-errors (kill-buffer buf)))
      (when-let (buf (process-get process 'stderr-buffer))
        (ignore-errors (kill-buffer buf))))))

(defun concur--proc-filter (state stream-type chunk)
  "Dispatch a CHUNK of data to the correct user callback and `concur-stream`.

Arguments:
- `STATE` (concur-process-state): The process state object.
- `STREAM-TYPE` (keyword): Either `:stdout` or `:stderr`.
- `CHUNK` (string): The data chunk received from the process."
  (let ((stream (if (eq stream-type :stdout)
                    (concur-process-state-stdout-stream state)
                  (concur-process-state-stderr-stream state)))
        (user-cb (if (eq stream-type :stdout)
                     (concur-process-state-on-stdout-cb state)
                   (concur-process-state-on-stderr-cb state))))
    (when user-cb (funcall user-cb chunk))
    (when stream (concur:stream-write stream chunk))))

(defun concur--spawn-standard-process (promise command args plist)
  "Orchestrate the creation of a standard, one-off Emacs process.

Arguments:
- `PROMISE` (concur-promise): The promise to associate with this process.
- `COMMAND` (string): The executable command.
- `ARGS` (list): A list of string arguments for the command.
- `PLIST` (plist): The original property list of options."
  (let* ((cwd (or (plist-get plist :cwd) default-directory))
         (state (%%make-process-state
                 :promise promise :command command :args args :cwd cwd
                 :stdout-stream (concur:stream-create)
                 :stderr-stream (concur:stream-create)
                 :on-stdout-cb (plist-get plist :on-stdout)
                 :on-stderr-cb (plist-get plist :on-stderr)
                 :die-on-error (not (eq (plist-get plist :die-on-error) nil)))))
    (condition-case err
        (let* ((stderr-buf (generate-new-buffer
                            (format "*stderr:%s*" (file-name-nondirectory command))))
               (proc (make-process
                      :name (format "concur-%s" (file-name-nondirectory command))
                      :command (cons command args)
                      :buffer (generate-new-buffer
                               (format "*stdout:%s*" (file-name-nondirectory command)))
                      :stderr stderr-buf
                      :sentinel #'concur--proc-sentinel
                      :filter (lambda (_p c) (concur--proc-filter state :stdout c))
                      :stderr-filter (lambda (_p c) (concur--proc-filter state :stderr c))
                      :noquery t :connection-type 'pipe :coding 'utf-8
                      :current-directory cwd
                      :environment (append (plist-get plist :env) process-environment))))
          (process-put proc 'concur-process-state state)
          (process-put proc 'stderr-buffer stderr-buf)
          (setf (concur-promise-proc promise) proc) ; Link promise to process for cancellation.
          (setf (concur-process-state-process state) proc)
          (when-let (timeout (plist-get plist :timeout))
            (setf (concur-process-state-timeout-timer state)
                  (run-at-time timeout nil (lambda () (ignore-errors (delete-process proc)))))))
      (error
       (apply #'concur--proc-reject-promise state 'concur-process-creation-error
              (format "Failed to create process for '%s': %s"
                      (s-join " " (cons command args)) (error-message-string err))
              `(:cause ,err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Core Functions

;;;###autoload
(cl-defun concur:process (command &rest keys)
  "Run an external command asynchronously, returning a promise.
This function spawns a standard, one-off OS process. The returned promise
resolves with a `concur-process-result` object, which contains streams
for stdout and stderr.

Arguments:
- `COMMAND` (string or list): The command to run.
  - If a list `(EXE ARG1 ARG2 ...)`: This is the recommended, safest usage.
  - If a string: It will be executed via `/bin/sh -c`. Use with caution.
- `KEYS` (plist): A property list of options:
  - `:cwd` (string): The working directory for the process.
  - `:env` (alist): An alist of `(VAR . VAL)` strings to set as environment
    variables for the command.
  - `:on-stdout` (function): A callback `(lambda (chunk))` for stdout data.
  - `:on-stderr` (function): A callback `(lambda (chunk))` for stderr data.
  - `:timeout` (number): Timeout in seconds. The process will be killed.
  - `:cancel-token` (concur-cancel-token): Token to cancel the process.
  - `:die-on-error` (boolean): If `t` (default), reject on non-zero exit.

Returns:
- (concur-promise): A promise for the `concur-process-result`.

Signals:
- `concur-process-creation-error` if the process cannot be spawned.
- `concur-process-exit-error` if `:die-on-error` is `t` and exit code is non-zero.
- `concur-process-signal-error` if the process is killed by a signal."
  (let* ((cancel-token (plist-get keys :cancel-token))
         (promise (concur:make-promise :cancel-token cancel-token))
         (cmd-and-args (if (listp command)
                           command
                         (list "/bin/sh" "-c" command)))
         (executable (car cmd-and-args))
         (args (cdr cmd-and-args)))
    (concur--spawn-standard-process promise executable args keys)
    promise))

;;;###autoload
(cl-defun concur:command (command &rest keys)
  "Run a command and return a promise for its complete stdout string.
This high-level wrapper around `concur:process` handles common cases:
- Rejects if the process exits with a non-zero code.
- Rejects if the process produces any output on stderr.
- Resolves with the complete, trimmed stdout content on success.
- Filters out ANSI color escape codes from the successful output.

Arguments:
- `COMMAND` (string or list): The command to run (see `concur:process`).
- `KEYS` (plist): Options, same as `concur:process`.

Returns:
- (concur-promise): A promise that resolves with the trimmed stdout string."
  (let ((process-promise (apply #'concur:process command keys)))
    (concur:chain
        process-promise
      ;; When the process succeeds, drain its streams.
      (:then (lambda (result)
               (concur:chain
                   (concur:all
                    (list (concur:stream-drain
                           (concur-process-result-stdout-stream result))
                          (concur:stream-drain
                           (concur-process-result-stderr-stream result))))
                 (:let ((stdout-chunks (car <>)) (stderr-chunks (cadr <>))))
                 (let ((stdout-str (s-trim (s-join "" stdout-chunks)))
                       (stderr-str (s-trim (s-join "" stderr-chunks))))
                   (if (s-blank? stderr-str)
                       stdout-str
                     (concur:rejected!
                      (concur:make-error
                       :type 'concur-process-stderr-output-error
                       :stderr stderr-str :stdout stdout-str
                       :exit-code 0
                       :message "Command produced output on stderr")))))))
      ;; Filter ANSI color codes from the final successful output.
      (:then #'ansi-color-filter-apply))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Command Pipelines & Definitions

;;;###autoload
(defmacro concur:command-pipe! (&rest command-forms)
  "Chain commands sequentially in the same persistent shell.
Uses `concur:shell-session` to ensure all commands run in the same stateful
environment. If any command fails, the entire pipe aborts.

Arguments:
- `COMMAND-FORMS` (list of lists): Each element is a form suitable for
  `concur:shell-command`, e.g., `'((\"cd /tmp\") (\"touch file\"))`.

Returns:
- (concur-promise): A promise that resolves with the stdout of the *last* command."
  (declare (indent 1) (debug t))
  (unless command-forms (error "`concur:command-pipe!` requires at least one command"))
  (let ((session-var (gensym "session")))
    `(concur:shell-session (,session-var)
       (let ((last-result nil))
         (concur:chain
             t ; Initial value.
           ,@(--map `(:then (lambda (_)
                              (setq last-result (apply ,session-var ,it))))
                    command-forms)
           (:then (lambda (_) last-result)))))))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr &rest keys)
  "Define `NAME` as a function that runs an async command via `concur:command`.
This is a convenient way to create reusable, documented async commands
that return promises for their results.

Arguments:
- `NAME` (symbol): The name of the function to define.
- `ARGLIST` (list): The argument list for the new function.
- `DOCSTRING` (string): The documentation string for the new function.
- `COMMAND-EXPR` (form): A form evaluating to the command list/string, which
  can use the variables bound in `ARGLIST`.
- `KEYS` (plist): Default options for `concur:command`. An `:interactive`
  spec for the function can also be provided here.

Returns:
- `(symbol)`: The defined function name `NAME`."
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
           (apply #'concur:command command
                  (append ,rest-args ',default-keys)))))))

(provide 'concur-process)
;;; concur-process.el ends here