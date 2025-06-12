;;; concur-exec.el --- Asynchronous Process Execution with Promises
;;
;; -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library runs external commands asynchronously, handling their results with
;; promises from `concur-promise.el`. It streamlines common patterns for process
;; execution and chaining.
;;
;; Key Components:
;; - `concur:process`: A low-level function for async command execution. Returns a
;;   promise that resolves with a detailed plist of process information.
;;
;; - `concur:command`: A higher-level convenience function built on `concur:process`.
;;   It simplifies executing a command string and returns the trimmed stdout on
;;   success.
;;
;; - `concur:pipe!`: A macro to chain multiple async commands, piping the stdout
;;   of one to the stdin of the next.
;;
;; - `concur:define-command!`: A macro to define reusable async command functions
;;   with default options and interactive specs.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'concur-promise)
(require 'ansi-color)
(require 'concur-core)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur-exec--plist-delete (plist key)
  "Return a copy of PLIST with KEY and its value removed.

This is a private, non-destructive helper for `concur-exec`.

Arguments:
- `plist` (plist): The property list to modify.
- `key` (keyword): The key to remove.

Returns:
  (plist): A new plist without the specified key-value pair."
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

This helper takes the raw output from a completed process and
constructs a standardized plist. It also handles error detection
based on `die-on-error` and optional ANSI code stripping.

Arguments:
- `cmd` (string): The command that was executed.
- `args` (list): A list of arguments passed to the command.
- `stdout` (string): The raw standard output from the process.
- `stderr` (string): The raw standard error from the process.
- `exit-code` (integer): The exit status code of the process.
- `:discard-ansi` (boolean): If non-nil, remove ANSI escape codes.
- `:die-on-error` (boolean | string): If non-nil and exit-code is
  non-zero, an `:error` entry is added to the result plist.

Returns:
  (plist): A plist containing process information with keys `:cmd`,
  `:args`, `:exit`, `:stdout`, `:stderr`, and optionally `:error`."
  (let* ((clean-stdout (if discard-ansi
                           (ansi-color-filter-apply stdout)
                         stdout))
         (result `(:cmd ,cmd :args ,args :exit ,exit-code
                   :stdout ,clean-stdout :stderr ,stderr)))
    (if (and die-on-error (/= exit-code 0))
        (let* ((error-msg
                (if (stringp die-on-error)
                    die-on-error
                  (format "Command '%s' failed with exit code %d"
                          (s-join " " (cons cmd args))
                          exit-code)))
               (error-info `(:error-type concur-exec-error
                             :message ,error-msg
                             :exit-code ,exit-code
                             :stdout ,clean-stdout
                             :stderr ,stderr)))
          (plist-put result :error error-info))
      result)))

(cl-defun concur--start-process-and-setup-sentinel
    (resolve reject command args cwd env stdin merge-stderr discard-ansi
             die-on-error cancel-token)
  "Internal helper to create a process and set up its sentinel.
This function contains the main success path of `concur:process`."
  (let* ((proc-name (format "concur-%s" (file-name-nondirectory command)))
         (stdout-buf (generate-new-buffer (format "*%s-stdout*" proc-name)))
         (stderr-buf (unless merge-stderr
                       (generate-new-buffer (format "*%s-stderr*" proc-name))))
         (proc
          (let ((default-directory (or cwd default-directory))
                (process-environment
                 (if env
                     (append
                      (--map (format "%s=%s" (car it) (cdr it)) env)
                      process-environment)
                   process-environment)))
            (concur--log :debug "-> Calling make-process for: %s" proc-name)
            (make-process
             :name proc-name
             :buffer stdout-buf
             :command (cons command (or args '()))
             :stderr (if merge-stderr t stderr-buf)
             :noquery t
             :connection-type 'pipe))))

    (concur--log :debug "-> make-process returned: %S" proc)
    (process-put proc 'concur-resolve-fn resolve)
    (process-put proc 'concur-reject-fn reject)
    (process-put proc 'concur-stdout-buf stdout-buf)
    (process-put proc 'concur-stderr-buf stderr-buf)
    (process-put proc 'concur-cmd-info
                 (list command args discard-ansi die-on-error))

    (when stdin
      (process-send-string proc stdin)
      (process-send-eof proc))

    (concur--log :debug "-> Calling set-process-sentinel for: %S" proc)
    (set-process-sentinel
     proc
     (lambda (process _event)
       "Sentinel that resolves or rejects the promise on process completion."
       (concur--log :debug ">> SENTINEL TRIGGERED for process: %S" process)
       (let* ((resolve-fn (process-get process 'concur-resolve-fn))
              (reject-fn (process-get process 'concur-reject-fn))
              (s-buf (process-get process 'concur-stdout-buf))
              (e-buf (process-get process 'concur-stderr-buf))
              (cmd-info (process-get process 'concur-cmd-info))
              (cmd (nth 0 cmd-info))
              (cmd-args (nth 1 cmd-info))
              (d-ansi (nth 2 cmd-info))
              (d-err (nth 3 cmd-info)))
         (unwind-protect
             (let* ((exit-code (process-exit-status process))
                    (stdout (with-current-buffer s-buf (buffer-string)))
                    (stderr (if e-buf (with-current-buffer e-buf
                                        (buffer-string)) ""))
                    (result (concur--process-output cmd cmd-args stdout stderr
                                                    exit-code
                                                    :discard-ansi d-ansi
                                                    :die-on-error d-err))
                    (error-info (plist-get result :error)))
               (if error-info
                   (progn
                     (concur--log :debug ">> Sentinel calling reject-fn...")
                     (funcall reject-fn result))
                 (progn
                   (concur--log :debug ">> Sentinel calling resolve-fn...")
                   (funcall resolve-fn result)))))
           (when (buffer-live-p s-buf) (kill-buffer s-buf))
           (when (buffer-live-p e-buf) (kill-buffer e-buf)))))

    (when cancel-token
      (concur:cancel-token-on-cancel
       cancel-token
       (lambda ()
         (when (process-live-p proc)
           (kill-process proc)
           (funcall reject
                    `(:error-type concur-exec-cancelled
                      :message ,(format "Process '%s' cancelled" command)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:process (&key command args cwd env discard-ansi die-on-error
                               trace stdin merge-stderr cancel-token
                               error-callback &allow-other-keys)
  "Run COMMAND asynchronously and return a promise with the result.

This function provides a low-level interface for executing external
processes. It returns a promise that resolves or rejects with a
detailed plist containing information about the process's
execution, including standard output, standard error, and exit
code.

Arguments:
- `:command` (string): The executable command to run.
- `:args` (list): A list of strings for command-line arguments.
- `:cwd` (string): The current working directory for the process.
- `:env` (list): A list of cons cells `(VAR . VAL)` for environment variables.
- `:discard-ansi` (boolean): If non-nil, remove ANSI codes from stdout.
- `:die-on-error` (boolean | string): If non-nil and the process fails,
  the promise will reject with a result plist.
- `:trace` (string): A debug string to log when the process starts.
- `:stdin` (string): A string to send to the process's standard input.
- `:merge-stderr` (boolean): If non-nil, merge stderr into stdout.
- `:cancel-token` (concur-cancel-token): Token to cancel the process.
- `:error-callback` (function): A function called on process creation error.

Returns:
  (concur:promise): A promise that yields a result plist on
  completion. If process creation fails, it rejects with an error
  plist where `:error-type` is `concur-exec-creation-error`."
  (unless (and command (stringp command) (not (string-empty-p command)))
    (error "concur:process: :command must be a non-empty string"))

  (concur--log :debug "-> Entering concur:process with command: %s" command)
  (when trace (concur--log :debug "Trace: %s" trace))

  (concur--log :debug "-> Calling concur:with-executor from concur:process")
  (concur:with-executor
   (lambda (resolve reject)
     (concur--log :debug "-> Inside executor-fn for concur:process")
     (condition-case err
         (concur--start-process-and-setup-sentinel
          resolve reject command args cwd env stdin merge-stderr
          discard-ansi die-on-error cancel-token)
       ;; Handle errors that occur *before* the process is created.
       (error
        (let ((error-info `(:error-type concur-exec-creation-error
                            :message ,(error-message-string err)
                            :original-error ,err)))
          (when error-callback (funcall error-callback error-info))
          (funcall reject error-info)))))))

;;;###autoload
(defun concur:command (command &rest keys)
  "Run COMMAND asynchronously and return a promise resolving to its output.

This is a higher-level convenience function built on `concur:process`.
It simplifies command execution by handling argument parsing and
providing a more direct result.

The promise's resolution and rejection behavior depends on `:die-on-error`:
- If `:die-on-error` is `t` (default):
  The promise resolves to the **trimmed stdout string** on success.
  The promise rejects with the **full result plist** on failure.
- If `:die-on-error` is `nil`:
  The promise always resolves with the **full result plist**, regardless
  of the exit code.

Arguments:
- `command` (string | list): The command to run. If a string, it is
  split by spaces. If a list, the car is the command and the cdr
  is the arguments.
- `keys` (plist): Keyword arguments passed directly to `concur:process`.

Returns:
  (concur:promise): A promise that resolves or rejects based on the
  process's exit code and the `:die-on-error` argument."
  (concur--log :debug "-> Entering concur:command with command: %S" command)
  (let* ((cmd-list (if (listp command) command (s-split " " command t)))
         (exe (car cmd-list))
         (implicit-args (cdr cmd-list))
         (user-provided-keys (copy-sequence keys))
         (die-on-error-final (or (plist-get user-provided-keys :die-on-error) t))
         (explicit-args (plist-get user-provided-keys :args))
         (combined-args (append implicit-args (or explicit-args '())))
         (filtered-user-keys
          (concur-exec--plist-delete
           (concur-exec--plist-delete user-provided-keys :args) :die-on-error))
         (plist-for-process
          (append (list :command exe :args combined-args :die-on-error nil)
                  filtered-user-keys)))

    (concur--log :debug "concur:command: Running '%s', final :die-on-error=%S"
                 (s-join " " (cons exe combined-args)) die-on-error-final)

    (unless (and exe (not (string-empty-p exe)))
      (error "Invalid command provided to concur:command: %S" command))

    ;; Refactor using concur:chain's full capabilities
    (concur:chain
     (apply #'concur:process plist-for-process)
     (:then
      ;; Use 'result-plist' as the lambda argument name
      (lambda (result-plist)
        (let ((exit-code (plist-get result-plist :exit)))
          (concur--log :debug "concur:command: Process finished with exit code %d."
                       exit-code)
          (if (zerop exit-code)
              (if die-on-error-final
                  (s-trim (plist-get result-plist :stdout))
                result-plist)
            ;; If non-zero exit and die-on-error-final is t, reject with the plist.
            ;; Otherwise (die-on-error-final is nil), resolve with the plist.
            (if die-on-error-final
                (concur:rejected! result-plist) ; Reject with the full result plist
              result-plist)))))
     (:catch
      ;; Use 'err-info' as the lambda argument name
      (lambda (err-info)
        (concur--log :error
                     "concur:command: Process creation or unhandled error: %S"
                     err-info)
        (concur:rejected! err-info))))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands, piping stdout of one to stdin of the next.

This macro creates a sequence of `concur:command` calls where the
stdout of each command is used as the stdin for the subsequent
command. The result of the entire pipeline is the result of the
last command.

Arguments:
- `command-forms` (list): A list of command specifications. Each
  element can be a string (`\"ls -l\"`) or a list (`'(\"grep\"
  \"foo\")`). Keyword arguments for `concur:command` can be
  included (e.g., `'(\"ls\" \"-l\" :cwd \"/tmp\")`)."
  (declare (indent 2))
  (unless command-forms
    (error "concur:pipe! requires at least one command form"))

  (let* ((pipeline
          (--map
           (let* ((cmd-form it)
                  (cmd (if (listp cmd-form) (car cmd-form) cmd-form))
                  (args (if (listp cmd-form) (cdr cmd-form) nil))
                  (is-last (eq cmd-form (car (last command-forms))))
                  ;; Ensure intermediate commands die on error so they propagate
                  ;; and don't silently succeed with non-zero exit.
                  (final-args (if is-last
                                  args
                                (plist-put (copy-sequence args)
                                           :die-on-error t))))
             ;; Use 'input-value' as the lambda argument name
             `(lambda (input-value) (concur:command ,cmd :stdin input-value ,@final-args)))
           (cdr command-forms)))
         (first-form (car command-forms))
         (first-cmd (if (listp first-form) (car first-form) first-form))
         (first-args (if (listp first-form) (cdr first-form) nil)))
    `(concur:chain (concur:command ,first-cmd ,@first-args) ,@pipeline)))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr
                                       &rest default-keys-plist)
  "Define NAME as a function that runs an async command via `concur:command`.

This macro simplifies creating reusable functions that execute
external commands asynchronously. It allows defining an
`interactive` spec and default keyword arguments.

Arguments:
- `name` (symbol): The name of the function to define.
- `arglist` (list): The argument list for the function. If `&rest
  keys` is included, additional keyword arguments passed to NAME
  will be forwarded to `concur:command`.
- `docstring` (string): The documentation string for the function.
- `command-expr` (form): An expression that evaluates to the
  `COMMAND` argument for `concur:command`.
- `default-keys-plist` (plist, optional): Default keyword arguments
  to pass to `concur:command`. A special key `:interactive` can be
  included to define an `interactive` spec."
  (declare (indent 2))
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