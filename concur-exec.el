;;; concur-exec.el --- Asynchronous Process Execution with Promises -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides functions and macros to run external commands
;; asynchronously and handle their results using promises from `concur-promise.el`.
;; It aims to simplify common patterns of process execution and chaining in Emacs.
;;
;; Key Components:
;; - `concur:process`: A low-level function for running an external command
;;   asynchronously. It returns a promise that resolves with a detailed plist
;;   containing the exit status, stdout, and stderr of the process.
;;   This function provides fine-grained control over process execution.
;;
;; - `concur:command`: A higher-level convenience function built on
;;   `concur:process`. It simplifies executing a command string, automatically
;;   splitting it into an executable and arguments. Its promise typically
;;   resolves with just the trimmed stdout string from the command.
;;
;; - `concur:define-command`: A macro to easily define new, reusable asynchronous
;;   command functions. These generated functions are based on `concur:command`
;;   and can have interactive specifications for ease of use.
;;
;; - `concur:pipe!`: A macro to chain multiple asynchronous commands, where the
;;   stdout of one command is piped to the stdin of the next. This allows for
;;   building complex data processing pipelines.
;;
;;; Code:

(require 'cl-lib)
(require 's)               ; String manipulation
(require 'subr-x)           ; `file-name-nondirectory`, `generate-new-buffer`
(require 'concur-promise)   ; Core promise functionality, including concur:chain
(require 'ansi-color)       ; For `ansi-color-filter-apply`
(require 'scribe nil t)     ; Optional structured logging

;; Ensure `log!` is available if scribe isn't fully loaded/configured.
;; This placeholder uses `message` and prefixes logs.
(unless (fboundp 'log!)
  (defun log! (level format-string &rest args)
    "Placeholder logging function if scribe's log! is not available."
    (apply #'message (concat "CONCUR-EXEC-LOG [" (if (keywordp level) (symbol-name level) (format "%S" level)) "]: " format-string) args)))

(defun concur--process-output (cmd args output discard-ansi die-on-error exit-code &optional stderr)
  "Process the output from an asynchronous command and return a descriptive plist.
CMD: The command executable string.
ARGS: A list of string arguments.
OUTPUT: The raw stdout string.
DISCARD-ANSI: If non-nil, filter ANSI escape codes from stdout.
DIE-ON-ERROR: If non-nil and process exits non-zero, an :error key is added to the result.
              If a string, it's used as the error message.
EXIT-CODE: The integer exit code of the process.
STDERR: The raw stderr string, if captured separately.

Returns a plist with keys :cmd, :args, :exit, :stdout, :stderr, and optionally :error."
  (log! :debug "concur--process-output: exit=%d, cmd='%s', args=(%s)"
        exit-code cmd (s-join " " args))
  (let* ((stdout-str (or output ""))
         (stderr-str (or stderr ""))
         (clean-stdout (if discard-ansi (ansi-color-filter-apply stdout-str) stdout-str))
         (base-result (list :cmd cmd
                            :args args
                            :exit exit-code
                            :stdout clean-stdout
                            :stderr stderr-str))
         (error-details nil))

    (when (and die-on-error (not (zerop exit-code)))
      (let ((error-message
             (if (stringp die-on-error)
                 die-on-error ; Use custom message if `die-on-error` is a string
               (format "Command '%s %s' failed with exit code %d"
                       cmd (s-join " " args) exit-code))))
        (log! :error "concur--process-output: Command failed: %s\n  STDOUT: %s\n  STDERR: %s"
              error-message clean-stdout stderr-str)
        (setq error-details (list :error-type 'concur-exec-error
                                  :message error-message
                                  :exit-code exit-code
                                  :stdout clean-stdout
                                  :stderr stderr-str))
        (setq base-result (append base-result (list :error error-details)))))
    base-result))

;;;###autoload
(cl-defun concur:process (&key command args cwd env discard-ansi die-on-error
                               trace stdin stderr-buffer-name merge-stderr
                               cancel-token error-callback
                               &allow-other-keys)
  "Run COMMAND asynchronously with ARGS and optional settings. Returns a `concur-promise`.
The promise resolves with a plist: `(:cmd CMD :args ARGS :exit INT :stdout STR :stderr STR)`.
If `die-on-error` is non-nil and the process exits non-zero, or if process
creation fails, the promise is rejected with a plist containing error details.

Arguments:
  :command (string): The executable command.
  :args (list of strings, optional): Arguments for the command.
  :cwd (string, optional): Working directory for the command. Defaults to `default-directory`.
  :env (alist, optional): Environment variables to set, e.g., `'((\"VAR\" . \"val\"))`.
  :discard-ansi (boolean, optional): If non-nil, filter ANSI codes from stdout.
  :die-on-error (boolean or string, optional): If t (default), reject promise on non-zero exit.
                 If a string, use it as the error message. If nil, resolve even on error.
  :trace (string, optional): A message to print for tracing before execution.
  :stdin (string, optional): String to pass to the command's standard input.
  :stderr-buffer-name (string, optional): Custom name for the stderr buffer.
  :merge-stderr (boolean, optional): If non-nil, merge stderr into stdout (uses PTY).
  :cancel-token (concur-cancel-token, optional): For cooperative cancellation.
  :error-callback (function, optional): A function `(lambda (error-info))` called
                   synchronously if process creation itself fails.

This function is the low-level interface for process execution."
  (unless (and command (stringp command) (not (string-empty-p command)))
    (error "concur:process: :command must be a non-empty string, got %S" command))

  (log! :info "concur:process: Launching: '%s', Args: %S" command (or args '()))

  (let* ((exe command)
         (args-list (or args '()))
         (current-default-directory default-directory)
         (current-process-environment process-environment)
         (exe-basename (file-name-nondirectory exe))
         (process-name (format "concur-%s" exe-basename))
         (stdout-buffer-name (format "*concur-stdout-%s-%s*" exe-basename (make-temp-name "")))
         (stdout-buf (generate-new-buffer stdout-buffer-name))
         (stderr-buffer-name-actual (unless merge-stderr
                                      (or stderr-buffer-name
                                          (format "*concur-stderr-%s-%s*" exe-basename (make-temp-name "")))))
         (stderr-buf (if stderr-buffer-name-actual (generate-new-buffer stderr-buffer-name-actual)))
         (final-command-list (cons exe args-list))
         (final-stderr-target (if merge-stderr proc-pty-slave stderr-buf))
         process final-cwd final-env)

    (when trace
      (log! :debug "ConcurExecTrace: %s: %s %s" trace exe (s-join " " args-list)))

    (concur:with-executor
     (lambda (resolve reject)
       (condition-case err ; Using 'err' as the error variable name
           (progn
             (setq final-cwd (or cwd current-default-directory))
             (setq final-env (append (--map (lambda (p) (format "%s=%s" (car p) (cdr p))) env)
                                     current-process-environment))

             (log! :debug "concur:process: Preparing to call make-process. Name: %s, Cmd: %S, CWD: %s"
                   process-name final-command-list final-cwd)

             (let ((default-directory final-cwd)
                   (process-environment final-env))
               (setq process
                     (make-process
                      :name process-name
                      :buffer stdout-buf
                      :command final-command-list
                      :stderr final-stderr-target
                      :noquery t
                      :connection-type 'pipe)))

             (when stdin
               (process-send-string process stdin)
               (process-send-eof process))

             (set-process-sentinel
              process
              (lambda (_proc event)
                (log! :debug "concur:process: Sentinel for %S (event: %S, status: %S)."
                      _proc event (process-status _proc))
                (when (memq (process-status _proc) '(exit signal))
                  (let ((exit-code (process-exit-status _proc))
                        stdout-content stderr-content)
                    (condition-case sentinel-err
                        (progn
                          (setq stdout-content (with-current-buffer stdout-buf (buffer-string)))
                          (when stderr-buf
                            (setq stderr-content (with-current-buffer stderr-buf (buffer-string)))))
                      (error
                       (log! :error "concur:process: Sentinel error capturing output: %S" sentinel-err)))
                    
                    (ignore-errors (when (buffer-live-p stdout-buf) (kill-buffer stdout-buf)))
                    (ignore-errors (when (and stderr-buf (buffer-live-p stderr-buf)) (kill-buffer stderr-buf)))

                    (log! :info "concur:process: Process '%s' finished (exit=%d)." exe exit-code)
                    (let* ((result (concur--process-output exe args-list
                                                           stdout-content discard-ansi die-on-error
                                                           exit-code stderr-content))
                           (error-in-result (plist-get result :error)))
                      (if error-in-result
                          (funcall reject result)
                        (funcall resolve result)))))))

             (when cancel-token
               (concur:cancel-token-on-cancel
                cancel-token
                (lambda ()
                  (when (process-live-p process)
                    (log! :warn "concur:process: Process %S killed by cancel token." process)
                    (kill-process process)
                    (funcall reject
                             (list :error-type 'concur-exec-cancelled
                                   :message (format "Process '%s' cancelled by token" exe)
                                   :cmd exe :args args-list)))))))
         (error ; Handler for errors from the progn block, `err` is bound here
          (let* ((original-error-condition err) ; Explicitly bind the caught condition
                 (msg (error-message-string original-error-condition))
                 (error-info (list :error-type 'concur-exec-creation-error
                                   :message (format "Process setup/make-process failed for '%s': %s" exe msg)
                                   :cmd exe :args args-list
                                   :original-error original-error-condition)))
            (log! :error "concur:process: Process creation block failed. Raw error: %S. Details: %S"
                  original-error-condition error-info)
            (ignore-errors (when (buffer-live-p stdout-buf) (kill-buffer stdout-buf)))
            (ignore-errors (when (and stderr-buf (buffer-live-p stderr-buf)) (kill-buffer stderr-buf)))
            (when error-callback (funcall error-callback error-info))
            (funcall reject error-info)))))
     cancel-token)))

;;;###autoload
(cl-defun concur:command (command &rest keys)
  "Run COMMAND asynchronously and return a promise resolving with trimmed stdout.
COMMAND can be a string (e.g., \"ls -l\") or a list `(EXE ARG1 ARG2 ...)`.
KEYS are passed to `concur:process`, with `:die-on-error` defaulting to `t`.
If the command fails and `:die-on-error` is true, the promise rejects,
and an error is signaled. Otherwise, on failure with `:die-on-error nil`,
it resolves with an empty string.

Example:
  (concur:then (concur:command \"echo hello\")
               (lambda (output) (message \"Echoed: %s\" output)))"
  (let* ((cmd-list (if (listp command) command (s-split " " command t)))
         (exe (car cmd-list))
         (args-from-cmd (cdr cmd-list))
         (explicit-args (plist-get keys :args))
         (final-args (or explicit-args args-from-cmd))
         (input-string (plist-get keys :input-string))
         (die-on-error (or (plist-get keys :die-on-error) t))
         (forward-keys (copy-sequence keys)))

    (cl-remf forward-keys :args)
    (cl-remf forward-keys :input-string)
    (cl-remf forward-keys :log-max-len)

    (setq forward-keys (plist-put forward-keys :die-on-error die-on-error))

    (unless (and exe (not (string-empty-p exe)))
      (error "concur:command: invalid command string or list: %S" command))

    (log! :info "concur:command: Running '%s', Args: %S, Input: %s"
          exe (s-join " " final-args)
          (if input-string
              (format "\"%s\" (len %d)" (s-truncate 20 input-string) (length input-string))
            "none"))

    (concur:chain
     (apply #'concur:process
            :command exe
            :args final-args
            (when input-string `(:stdin ,input-string))
            forward-keys)

     (let* ((resolved-value <>)
            (stdout-raw (plist-get resolved-value :stdout))
            (stdout-str (if (stringp stdout-raw) (s-trim stdout-raw) "")))
       (log! :debug "concur:command: Success. Stdout length: %d" (length stdout-str))
       stdout-str)

     :catch
     (let* ((raw-failure-info <!>)
            (cmd-display-str (if (stringp exe) exe (format "%S" exe)))
            (args-display-str (s-join " " final-args))
            (error-message-final "")
            (exit-code-for-message -1)
            (stderr-for-message ""))

       (if (plistp raw-failure-info)
           (let* ((cmd-in-err (plist-get raw-failure-info :cmd))
                  (cmd-to-show (if (stringp cmd-in-err) cmd-in-err cmd-display-str))
                  (stderr-val (plist-get raw-failure-info :stderr))
                  (stderr-final (if (stringp stderr-val) stderr-val (format "%S" stderr-val)))
                  (msg-val (plist-get raw-failure-info :message))
                  (msg-final (if (stringp msg-val) msg-val (format "%S" msg-val)))
                  (exit-val (plist-get raw-failure-info :exit)))
             (setq exit-code-for-message (if (integerp exit-val) exit-val -1))
             (setq stderr-for-message (or stderr-final ""))
             (setq error-message-final (format "FAIL: %s %s | exit=%d | error: %s | stderr: '%s'"
                                               cmd-to-show args-display-str exit-code-for-message
                                               msg-final stderr-for-message)))
         (setq error-message-final (format "FAIL: %s %s | Direct error: %S"
                                           cmd-display-str args-display-str raw-failure-info)))

       (log! :error error-message-final)
       (if die-on-error
           (error "Command failed: %s" error-message-final)
         "")))))

;;;###autoload
(cl-defmacro concur:pipe! (&rest command-forms)
  "Chain multiple asynchronous commands, piping stdout of one to stdin of the next.
Each form in COMMAND-FORMS is like an argument to `concur:command`,
e.g., \"cmd1 args\" or '(\"cmd1\" \"arg1\" :key val).
Intermediate commands in the pipe always use `:die-on-error t`.
The last command respects its own `:die-on-error` or `concur:command`'s default."
  (declare (indent 0))
  (unless command-forms
    (error "concur:pipe!: At least one command form must be provided."))

  (let* ((first-cmd-form (car command-forms))
         (rest-cmd-forms (cdr command-forms))
         (forms
          (cons
           ;; First command, always force :die-on-error t unless provided
           (if (listp first-cmd-form)
               (let* ((cmd (car first-cmd-form))
                      (args (cdr first-cmd-form))
                      (keys (if (plist-member args :die-on-error)
                                args
                              (append (list :die-on-error t) args))))
                 `(concur:command ,cmd ,@keys))
             `(concur:command ,first-cmd-form :die-on-error t))

           ;; Rest of pipeline, using lambdas with input string piping
           (--map
            (let* ((is-last (eq it (car (last rest-cmd-forms))))
                   (cmd (if (listp it) (car it) it))
                   (args (if (listp it) (cdr it) nil))
                   (final-args (if (or is-last (plist-member args :die-on-error))
                                   args
                                 (append (list :die-on-error t) args))))
              `(lambda (<>) (concur:command ,cmd :input-string <> ,@final-args)))
            rest-cmd-forms))))

    ;; Final wrapped form
    `(concur:chain ,@forms)))

;;;###autoload
(cl-defmacro concur:define-command (name arglist docstring command-expr
                                      &rest default-keys-plist &key interactive)
  "Define NAME as a function that runs an async command via `concur:command`.
COMMAND-EXPR should evaluate to a command string or a list `(EXE ARGS...)`.
DEFAULT-KEYS-PLIST are default keyword arguments for `concur:command`.
If :interactive is non-nil, an `(interactive)` form is added.
  If :interactive is a string, it's used as the interactive spec.

Example:
  (concur:define-command my-git-version (arg)
    \"Get git version asynchronously.\"
    (format \"git --version %s\" arg) ; command-expr
    :cwd \"/tmp/\")
  (concur:then (my-git-version \"verbose\") #'print)"
  (declare (indent 4) (debug (_name arglist docstring command-expr &key interactive &rest _keys)))
  (let* ((fn-actual-args (if (memq '&rest arglist) arglist (append arglist '(&rest more-keys))))
         (command-var (gensym "cmd-expr-val-"))
         (keys-var (gensym "merged-keys-"))
         (interactive-form (cond ((null interactive) nil)
                                 ((eq interactive t) '(interactive))
                                 ((stringp interactive) `(interactive ,interactive))
                                 (t (error "concur:define-command: :interactive spec must be string, t, or nil")))))
    `(defun ,name ,fn-actual-args
       ,docstring
       ,@(when interactive-form (list interactive-form))
       (let* ((,command-var ,command-expr)
              (,keys-var (append (list ,@default-keys-plist)
                                 (if (and (boundp 'more-keys) more-keys) more-keys nil))))
         (apply #'concur:command ,command-var ,keys-var)))))

(provide 'concur-exec)
;;; concur-exec.el ends here