;;; concur-exec.el --- Asynchronous Process Execution with Promises
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library runs external commands asynchronously, handling their results
;; with promises from `concur-promise.el`. It streamlines common patterns for
;; process execution and chaining, providing a higher-level API over raw
;; Emacs processes.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 's)
(require 'concur-promise)
(require 'ansi-color)
(require 'concur-hooks)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Process Output & Cleanup

(defun concur-exec--plist-delete (plist key)
  "Return a copy of PLIST with KEY and its value removed.

Arguments:
- PLIST (plist): The property list to modify.
- KEY (symbol): The key to remove.

Returns:
A new plist with the specified key and its value removed."
  (let (new-plist)
    (while plist
      (let ((k (car plist))
            (v (cadr plist)))
        (setq plist (cddr plist))
        (unless (eq k key)
          (setq new-plist (nconc new-plist (list k v))))))
    new-plist))

(cl-defun concur--process-output (cmd args stdout stderr exit-code
                                     &key discard-ansi die-on-error)
  "Format the raw output of a finished process into a result plist.
This includes stripping ANSI codes and creating a proper Lisp error
condition if the process failed and `die-on-error` is set.

Arguments:
- CMD (string): The command that was executed.
- ARGS (list of string): The arguments passed to the command.
- STDOUT (string): The standard output captured from the process.
- STDERR (string): The standard error captured from the process.
- EXIT-CODE (integer): The exit status of the process.
- :DISCARD-ANSI (boolean): If non-nil, remove ANSI codes from `stdout`.
- :DIE-ON-ERROR (boolean): If non-nil and `exit-code` is non-zero,
  an error condition is added to the result plist.

Returns:
A plist containing process results, optionally with an `:error` key."
  (let* ((clean-stdout (if discard-ansi
                           (ansi-color-filter-apply stdout)
                         stdout))
         (result `(:cmd ,cmd :args ,args :exit ,exit-code
                   :stdout ,clean-stdout :stderr ,stderr)))
    (if (and die-on-error (/= exit-code 0))
        (let* ((error-msg (format "Command '%s' failed with exit code %d"
                                  (s-join " " (cons cmd args))
                                  exit-code))
               (error-info `(concur-exec-error
                             :message ,error-msg
                             :exit-code ,exit-code
                             :stdout ,clean-stdout
                             :stderr ,stderr)))
          (plist-put result :error error-info))
      result)))

(defun concur--kill-process-buffers (stdout-buf stderr-buf)
  "Safely kill the stdout and stderr buffers associated with a process.

Arguments:
- STDOUT-BUF (buffer): The buffer holding standard output.
- STDERR-BUF (buffer or `nil`): The buffer holding standard error."
  (when (buffer-live-p stdout-buf)
    (kill-buffer stdout-buf))
  (when (and stderr-buf (buffer-live-p stderr-buf))
    (kill-buffer stderr-buf)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Process Sentinel & Context

(defun concur--sentinel-handler (process event)
  "The sentinel function for `concur:process`.
Handles all process termination events and settles the associated promise.

Arguments:
- PROCESS (process): The Emacs process object.
- EVENT (string): The event string provided by Emacs, e.g., 'finished'."
  (let ((status (process-status process)))
    (concur--log :debug ">> SENTINEL FIRED for %S with status %S and event: %S"
                 (process-name process) status event)
    ;; This regex robustly matches all standard Emacs termination events.
    (if (string-match-p "\\`\\(finished\\|exited\\|killed\\|signal\\)" event)
        (let* ((promise (process-get process 'concur-promise)))
          (when (and promise (concur:pending-p promise))
            (let* ((s-buf (process-get process 'concur-stdout-buf))
                   (e-buf (process-get process 'concur-stderr-buf))
                   (cmd (process-get process 'concur-command))
                   (args (process-get process 'concur-args))
                   (d-ansi (process-get process 'concur-discard-ansi))
                   (d-err (process-get process 'concur-die-on-error))
                   (exit-code (process-exit-status process))
                   (stdout (if (buffer-live-p s-buf)
                               (with-current-buffer s-buf (buffer-string)) ""))
                   (stderr (if (and e-buf (buffer-live-p e-buf))
                               (with-current-buffer e-buf (buffer-string)) ""))
                   (result (concur--process-output cmd args stdout stderr exit-code
                                                   :discard-ansi d-ansi
                                                   :die-on-error d-err))
                   (error-info (plist-get result :error)))
              (concur--kill-process-buffers s-buf e-buf)
              (if error-info
                  (concur:reject promise error-info)
                (concur:resolve promise result))))))))

(cl-defun concur--setup-process-context (promise proc stdout-buf stderr-buf
                                                 &key command args discard-ansi
                                                 die-on-error cancel-token
                                                 &allow-other-keys)
  "Attach all necessary context to the promise and process objects."
  (setf (concur-promise-proc promise) proc)
  (process-put proc 'concur-promise promise)
  (process-put proc 'concur-stdout-buf stdout-buf)
  (process-put proc 'concur-stderr-buf stderr-buf)
  (process-put proc 'concur-command command)
  (process-put proc 'concur-args args)
  (process-put proc 'concur-discard-ansi discard-ansi)
  (process-put proc 'concur-die-on-error die-on-error)
  (when cancel-token
    (concur:cancel-token-on-cancel
     cancel-token
     (lambda ()
       (when (process-live-p proc)
         (kill-process proc)
         (concur:reject promise
                        `(concur-exec-cancelled
                          :message ,(format "Process '%s' cancelled" command))))))))

(cl-defun concur--handle-creation-error (promise err proc stdout-buf stderr-buf
                                                 &key error-callback)
  "Handle errors during process creation, ensuring resource cleanup."
  (when (and proc (process-live-p proc)) (kill-process proc))
  (when stdout-buf (concur--kill-process-buffers stdout-buf stderr-buf))
  (let ((error-info `(concur-exec-creation-error
                      :message ,(error-message-string err)
                      :original-error ,err)))
    (when error-callback (funcall error-callback error-info))
    (concur:reject promise error-info)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Process Execution

;;;###autoload
(cl-defun concur:process (&key command args cwd env discard-ansi die-on-error
                               trace stdin merge-stderr cancel-token
                               error-callback &allow-other-keys)
  "Run COMMAND asynchronously and return a promise with the result.
This is the low-level process primitive. Prefer `concur:command` for
most use cases.

Arguments:
- :COMMAND (string): The executable command to run.
- :ARGS (list of string): Arguments to pass to the command.
- :CWD (string): The working directory. Defaults to `default-directory`.
- :ENV (alist): Environment variables to set for the process.
- :DISCARD-ANSI (boolean): If `t`, remove ANSI escape codes from stdout.
- :DIE-ON-ERROR (boolean): If `t`, the promise rejects if the command exits
  with a non-zero status.
- :STDIN (string): A string to send to the process's standard input.
- :MERGE-STDERR (boolean): If `t`, merge stderr into stdout.
- :CANCEL-TOKEN (`concur-cancel-token`): Token to cancel the process.
- :ERROR-CALLBACK (function): A function to call on creation error.

Returns:
A `concur-promise` that resolves to a plist of process results on successful
completion, or rejects on error."
  (concur--log :debug "-> ENTERING concur:process for: '%s' with args: %S"
               command args)
  (unless (and command (stringp command) (not (string-empty-p command)))
    (error "concur:process: :command must be a non-empty string"))
  (let ((promise (concur:make-promise :cancel-token cancel-token)))
    (let (proc stdout-buf stderr-buf)
      (condition-case err
          (progn
            (setq stdout-buf (generate-new-buffer
                              (format "*concur-%s-stdout*"
                                      (file-name-nondirectory command))))
            (unless merge-stderr
              (setq stderr-buf (generate-new-buffer
                                (format "*concur-%s-stderr*"
                                        (file-name-nondirectory command)))))
            (setq proc
                  (let ((default-directory (or cwd default-directory))
                        (process-environment
                         (if env (append (--map (format "%s=%s" (car it) (cdr it)) env)
                                         process-environment)
                           process-environment)))
                    (make-process
                     :name (format "concur-%s" (file-name-nondirectory command))
                     :buffer stdout-buf
                     :command (cons command (or args '()))
                     :stderr (if merge-stderr t stderr-buf)
                     :noquery t
                     :sentinel #'concur--sentinel-handler
                     :connection-type 'pipe)))
            (apply #'concur--setup-process-context promise proc stdout-buf stderr-buf
                   (list :command command :args args
                         :discard-ansi discard-ansi :die-on-error die-on-error
                         :cancel-token cancel-token))
            (when stdin
              (process-send-string proc stdin)
              (process-send-eof proc)))
        (error
         (concur--handle-creation-error promise err proc stdout-buf stderr-buf
                                        :error-callback error-callback))))
    promise))

;;;###autoload
(defmacro concur:command (command &rest keys)
  "Run COMMAND and return a promise that resolves to its output string.
This is a high-level wrapper around `concur:process`.

Arguments:
- COMMAND (string or list of string): The command to run. If a string,
  it's split by spaces.
- KEYS (plist, optional): Additional arguments passed to `concur:process`.
  A special key `:die-on-error` (defaults to `t`) controls rejection on
  non-zero exit codes.

Returns:
A `concur-promise` that resolves to the command's standard output (trimmed)
on success, or rejects with an error condition on failure."
  (declare (indent 1) (debug t))
  `(let* ((cmd-arg ,command)
          (cmd-list (if (listp cmd-arg) cmd-arg (s-split " " cmd-arg t)))
          (exe (car cmd-list))
          (implicit-args (cdr cmd-list))
          (user-provided-keys (list ,@keys))
          (die-on-error-final (or (plist-get user-provided-keys :die-on-error) t))
          (explicit-args (plist-get user-provided-keys :args))
          (combined-args (append implicit-args (or explicit-args '())))
          (filtered-user-keys
           (concur-exec--plist-delete
            (concur-exec--plist-delete user-provided-keys :args) :die-on-error))
          ;; Let `concur:command` handle the error logic by telling `concur:process`
          ;; to always resolve successfully, even on non-zero exit.
          (plist-for-process
           (append (list :command exe :args combined-args :die-on-error nil)
                   filtered-user-keys)))
     (unless (and exe (not (string-empty-p exe)))
       (error "Invalid command provided to concur:command: %S" cmd-arg))
     ;; The `concur:then` macro will lift `die-on-error-final` and `cmd-list`
     ;; from the lexical scope so they are available in the handler.
     (concur:then
      (apply #'concur:process plist-for-process)
      ;; on-resolved handler for the `concur:process` promise
      (lambda (result-plist)
        (let ((exit-code (plist-get result-plist :exit)))
          (if (zerop exit-code)
              ;; Success: resolve with trimmed stdout or the full result.
              (if die-on-error-final
                  (s-trim (plist-get result-plist :stdout))
                result-plist)
            ;; Failure: reject with a proper error or resolve with full result.
            (if die-on-error-final
                (concur:rejected!
                 `(concur-exec-error
                   :message ,(format "Command '%s' failed with exit code %d"
                                     (s-join " " cmd-list) exit-code)
                   :exit-code ,exit-code
                   :stdout ,(plist-get result-plist :stdout)
                   :stderr ,(plist-get result-plist :stderr)))
              result-plist))))
      ;; on-rejected handler for the `concur:process` promise
      (lambda (err-info)
        (concur--log :error "--> concur:command: Process creation failed: %S"
                     (plist-get err-info :message))
        (concur:rejected! err-info)))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands, piping stdout of one to stdin of the next.

Arguments:
- COMMAND-FORMS (forms): A sequence of command forms, e.g., `(\"ls -l\")`.

Returns:
A promise that resolves to the stdout of the final command."
  (declare (indent 1) (debug t))
  (unless command-forms
    (error "concur:pipe! requires at least one command form"))
  (let* ((pipeline
          (--map
           (let* ((cmd-form it)
                  (cmd (if (listp cmd-form) (car cmd-form) cmd-form))
                  (args (if (listp cmd-form) (cdr cmd-form) nil))
                  (is-last (eq cmd-form (car (last command-forms))))
                  (final-args (if is-last args
                                (plist-put (copy-sequence args) :die-on-error t))))
             `(lambda (input-value)
                (concur:command ,cmd :stdin input-value ,@final-args)))
           (cdr command-forms)))
         (first-form (car command-forms))
         (first-cmd (if (listp first-form) (car first-form) first-form))
         (first-args (if (listp first-form) (cdr first-form) nil)))
    `(concur:chain (concur:command ,first-cmd ,@first-args)
                   ,@pipeline)))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr
                                       &rest default-keys-plist)
  "Define NAME as a function that runs an async command via `concur:command`.
This creates a convenient, reusable wrapper around a common command pattern.

Arguments:
- NAME (symbol): The name of the new function to define.
- ARGLIST (list): The argument list for the new function.
- DOCSTRING (string): The docstring for the new function.
- COMMAND-EXPR (form): A form that evaluates to the command string/list.
- DEFAULT-KEYS-PLIST (plist, optional): Default keys for `concur:command`."
  (declare (indent 1) (debug t))
  (let* ((interactive-spec (plist-get default-keys-plist :interactive))
         (fn-keys (copy-sequence default-keys-plist)))
    (cl-remf fn-keys :interactive)
    `(defun ,name ,arglist
       ,docstring
       ,@(when interactive-spec `((interactive ,interactive-spec)))
       (apply #'concur:command
              ,command-expr
              (append (list ,@fn-keys)
                      (if (and (boundp 'keys) keys) keys '()))))))

(provide 'concur-exec)
;;; concur-exec.el ends here