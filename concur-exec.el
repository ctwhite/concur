;;; concur-exec.el --- Asynchronous Process Execution with Promises
;; -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library runs external commands asynchronously, handling
;; their results with promises from `concur-promise.el`.
;; It streamlines common patterns for process execution and chaining.
;;
;; Key Components:
;; - `concur:process`: Low-level function for async command
;;   execution. Returns a promise with detailed process info.
;;
;; - `concur:command`: Higher-level convenience function built on
;;   `concur:process`. Simplifies executing a command string, returning
;;   trimmed stdout on success, or a full result/error on failure based on
;;   `:die-on-error` flag.
;;
;; - `concur:define-command!`: Macro to define reusable async
;;   command functions.
;;
;; - `concur:pipe!`: Macro to chain multiple async commands,
;;   piping stdout of one to stdin of the next.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'concur-promise)
(require 'ansi-color)
(require 'concur-core) ; Assumes concur-core defines concur--log

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(cl-defun concur--process-output (cmd args stdout stderr exit-code
                                   &key discard-ansi die-on-error)
  "Format the raw output of a finished process into a result plist.

This helper function takes the raw output, error streams, and exit code
from a completed process and constructs a standardized plist. It also
handles error detection based on `die-on-error` and optional ANSI code
discarding.

Arguments:
- `cmd` (string): The command string that was executed.
- `args` (list): A list of arguments passed to the command.
- `stdout` (string): The raw standard output captured from the process.
- `stderr` (string): The raw standard error captured from the process.
- `exit-code` (integer): The exit status code of the process.
- `discard-ansi` (boolean, optional): If non-nil, ANSI escape codes are
  removed from `stdout`. Defaults to nil.
- `die-on-error` (boolean or string, optional): If non-nil and `exit-code` is
  non-zero, an `:error` entry is added to the result plist. If a string,
  it's used as the error message. Defaults to nil.

Returns:
  (plist): A plist containing process information.
  Keys include:
  - `:cmd` (string): The executed command.
  - `:args` (list): Arguments to the command.
  - `:exit` (integer): The process's exit code.
  - `:stdout` (string): Standard output (potentially stripped of ANSI codes).
  - `:stderr` (string): Standard error.
  - `:error` (plist, optional): Present if `die-on-error` is active and
    `exit-code` is non-zero. Contains:
    - `:error-type` (symbol): Always `concur-exec-error`.
    - `:message` (string): A descriptive error message.
    - `:exit-code` (integer): The non-zero exit code.
    - `:stdout` (string): Standard output at the time of error.
    - `:stderr` (string): Standard error at the time of error."
  (let* ((clean-stdout (if discard-ansi
                           (ansi-color-filter-apply stdout)
                         stdout))
         (result `(:cmd ,cmd :args ,args :exit ,exit-code
                   :stdout ,clean-stdout :stderr ,stderr)))
    (if (and die-on-error (not (zerop exit-code)))
        (let* ((error-msg (if (stringp die-on-error)
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:process (&key command args cwd env discard-ansi die-on-error
                               trace stdin merge-stderr cancel-token
                               error-callback &allow-other-keys)
  "Run COMMAND asynchronously and return a promise with the result.

This function provides a low-level interface for executing external processes.
It returns a promise that resolves or rejects with a detailed plist containing
information about the process's execution, including standard output,
standard error, and exit code.

Arguments:
- `command` (string): The executable command to run. This cannot be empty.
- `args` (list, optional): A list of strings representing command-line arguments.
  Defaults to nil.
- `cwd` (string, optional): The current working directory for the process.
  Defaults to `default-directory`.
- `env` (plist, optional): A plist of environment variables to set for the process.
  e.g., `(:VAR1 "value1" :VAR2 "value2")`. These are prepended to
  `process-environment`.
- `discard-ansi` (boolean, optional): If non-nil, ANSI escape codes are
  removed from the captured `stdout`. Defaults to nil.
- `die-on-error` (boolean or string, optional): If non-nil and the process exits
  with a non-zero status, the promise will reject with a result plist
  containing an `:error` key. If `die-on-error` is a string, it will be
  used as the error message. Defaults to nil (promise always resolves).
- `trace` (string, optional): A debug string to log when the process starts,
  useful for tracking.
- `stdin` (string, optional): A string to send to the process's standard input.
  Defaults to nil.
- `merge-stderr` (boolean, optional): If non-nil, stderr is merged into stdout.
  Defaults to nil, meaning stdout and stderr are captured separately.
- `cancel-token` (concur:cancel-token, optional): A cancel token object. If
  the token is cancelled, the running process will be killed and the promise
  will reject with a `concur-exec-cancelled` error.
- `error-callback` (function, optional): A function to call if there is an
  error during the *creation* of the process (e.g., command not found).
  It receives one argument: an error plist.

Returns:
  (concur:promise): A promise that, when resolved, yields a plist with the
  process result. The plist contains keys such as `:cmd`, `:args`, `:exit`,
  `:stdout`, and `:stderr`. If `die-on-error` is non-nil and the process
  fails, the promise will reject with this plist (containing an `:error` key).
  If a process creation error occurs, the promise will reject with an error plist
  containing `:error-type` as `concur-exec-creation-error`."
  (unless (and command (stringp command) (not (string-empty-p command)))
    (error "concur:process: :command must be a non-empty string"))

  (when trace (concur--log :debug "Trace: %s" trace))

  ;; `concur:with-executor` ensures the promise is correctly managed
  ;; within the Concur framework.
  (concur:with-executor
   (lambda (resolve reject)
     (let* ((proc-name (format "concur-%s" (file-name-nondirectory command)))
            ;; Create dedicated buffers for stdout and stderr to capture output.
            (stdout-buf (generate-new-buffer (format "*%s-stdout*" proc-name)))
            (stderr-buf (unless merge-stderr
                          (generate-new-buffer (format "*%s-stderr*" proc-name))))
            (proc nil))
       ;; Use `condition-case` to catch errors that occur during process creation.
       (condition-case err
           (progn
             (setq proc
                   (let ((default-directory (or cwd default-directory))
                         ;; Prepend specified environment variables.
                         (process-environment (append
                                               (--map (format "%s=%s"
                                                              (car it) (cdr it))
                                                      env)
                                               process-environment)))
                     ;; Create the external process.
                     (make-process
                      :name proc-name          ; Name for the Emacs process object.
                      :buffer stdout-buf       ; Buffer for stdout.
                      :command (cons command (or args '())) ; Full command and args.
                      :stderr (if merge-stderr proc-pty-slave stderr-buf) ; Stderr handling.
                      :noquery t               ; Don't query user if process fails.
                      :connection-type 'pipe))) ; Use pipes for I/O.

             ;; Store promise resolution/rejection functions and buffer info on the process object.
             ;; This allows the sentinel to access them after the process completes.
             (process-put proc 'concur-resolve-fn resolve)
             (process-put proc 'concur-reject-fn reject)
             (process-put proc 'concur-stdout-buf stdout-buf)
             (process-put proc 'concur-stderr-buf stderr-buf)
             (process-put proc 'concur-cmd-info
                          (list command args discard-ansi die-on-error))

             ;; If stdin content is provided, send it to the process.
             (when stdin
               (process-send-string proc stdin)
               (process-send-eof proc)) ; Signal end of input.

             ;; Set a sentinel function to be called when the process changes state (e.g., exits).
             (set-process-sentinel
              proc
              (lambda (process _event)
                "Sentinel that retrieves its state from the process object."
                (let* ((resolve-fn (process-get process 'concur-resolve-fn))
                       (reject-fn (process-get process 'concur-reject-fn))
                       (s-buf (process-get process 'concur-stdout-buf))
                       (e-buf (process-get process 'concur-stderr-buf))
                       (cmd-info (process-get process 'concur-cmd-info))
                       (cmd (nth 0 cmd-info))
                       (cmd-args (nth 1 cmd-info))
                       (d-ansi (nth 2 cmd-info))
                       (d-err (nth 3 cmd-info)))
                  ;; Ensure buffers are killed even if an error occurs during output processing.
                  (unwind-protect
                      (let* ((exit-code (process-exit-status process))
                             ;; Retrieve full buffer content.
                             (stdout (with-current-buffer s-buf (buffer-string)))
                             (stderr (if e-buf (with-current-buffer e-buf
                                                 (buffer-string)) "")))
                        ;; Format the output and resolve/reject the promise.
                        (let* ((result (concur--process-output
                                        cmd cmd-args stdout stderr exit-code
                                        :discard-ansi d-ansi
                                        :die-on-error d-err))
                               (error-info (plist-get result :error)))
                          (if error-info
                              (funcall reject-fn result)
                            (funcall resolve-fn result))))
                    ;; Clean up the temporary buffers.
                    (when (buffer-live-p s-buf) (kill-buffer s-buf))
                    (when (buffer-live-p e-buf) (kill-buffer e-buf))))))

             ;; If a cancel token is provided, set up a listener to kill the process.
             (when cancel-token
               (concur:cancel-token-on-cancel
                cancel-token
                (lambda ()
                  (when (process-live-p proc)
                    (kill-process proc)
                    ;; Reject the promise upon cancellation.
                    (funcall reject
                             `(:error-type concur-exec-cancelled
                               :message ,(format "Process '%s' cancelled" command))))))))
         ;; Handle errors that occur *before* the process is successfully created.
         (error
          (let ((error-info `(:error-type concur-exec-creation-error
                              :message ,(error-message-string err)
                              :original-error ,err)))
            ;; Call the optional error callback.
            (when error-callback (funcall error-callback error-info))
            ;; Reject the promise with creation error info.
            (funcall reject error-info)
            ;; Ensure buffers are killed even if process creation fails.
            (when (buffer-live-p stdout-buf) (kill-buffer stdout-buf))
            (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf)))))))
   cancel-token))

;;;###autoload
(defun concur:command (command &rest keys)
  "Run COMMAND asynchronously and return a promise.

This is a higher-level convenience function built on `concur:process`.
It simplifies command execution and provides flexible resolution/rejection
behavior based on the `:die-on-error` flag.

The promise's resolution and rejection behavior depends on `:die-on-error`:

- If `:die-on-error` is `t` (or unspecified):
  The promise resolves to the **trimmed stdout string** on success (exit code 0).
  The promise rejects with the **full result plist** on non-zero exit.

- If `:die-on-error` is `nil`:
  The promise always resolves with the **full result plist** (containing
  `:stdout`, `:stderr`, `:exit`, etc.), regardless of exit code.

Arguments:
- `command` (string or list): The command to run.
  - If a string, it is split by spaces to determine the executable and arguments.
  - If a list (e.g., `(\"ls\" \"-l\")`), the first element is the executable,
    and subsequent elements are arguments.
- `keys` (plist): Keyword arguments passed directly to `concur:process`.
  Common keys include:
  - `:args` (list): Additional arguments (if `command` is a string).
  - `:cwd` (string): Current working directory.
  - `:env` (plist): Environment variables.
  - `:stdin` (string): Input to the process's stdin.
  - `:discard-ansi` (boolean): Remove ANSI codes from stdout.
  - `:die-on-error` (boolean or string): Controls resolution/rejection behavior.
    Defaults to `t` for `concur:command`.
  - `:cancel-token` (concur:cancel-token): Token to cancel the process.

Returns:
  (concur:promise): A promise that resolves or rejects based on the
  process's exit code and the `:die-on-error` argument.
  - On success (`exit-code` 0): resolves with trimmed stdout (if `:die-on-error` is t)
    or the full result plist (if `:die-on-error` is nil).
  - On failure (`exit-code` non-zero): rejects with the full result plist (if
    `:die-on-error` is t) or resolves with the full result plist (if
    `:die-on-error` is nil).
  - On process creation failure: rejects with an error plist."
  (let* ((cmd-list (if (listp command) command (s-split " " command t)))
         (exe (car cmd-list))
         (args (cdr cmd-list))
         ;; Default :die-on-error to `t` for `concur:command` if the user doesn't specify.
         (die-on-error (or (plist-get keys :die-on-error) t))
         ;; Create the key list to pass to `concur:process`.
         ;; We override `:die-on-error` to be `nil` for `concur:process` so that
         ;; `concur:process` *always* resolves with the full result plist.
         ;; This allows `concur:command` to handle the logic of whether to
         ;; resolve with just stdout or reject with the full plist.
         (process-keys (plist-put (copy-sequence keys) :die-on-error nil)))

    (concur--log :debug "concur:command: Running '%s', :die-on-error=%S"
                 (s-join " " (cons exe args)) die-on-error)

    (unless (and exe (not (string-empty-p exe)))
      (error "Invalid command provided to concur:command: %S" command))

    ;; Use `concur:chain` to process the result of `concur:process`.
    (concur:chain
     ;; 1. Run the process using `concur:process`.
     ;; This promise will *always* resolve with the full result plist,
     ;; because we set `:die-on-error` to `nil` for `concur:process-keys`.
     (apply #'concur:process :command exe :args args process-keys)

     ;; 2. Handle the result plist from the resolved promise (`<>` holds the result).
     :then
     (let* ((result-plist <>)
            (exit-code (plist-get result-plist :exit)))
       (concur--log :debug "concur:command: Process finished with exit code %d." exit-code)

       (if (zerop exit-code)
           ;; --- SUCCESS CASE (exit code is 0) ---
           (if die-on-error
               ;; If die-on-error is true, resolve with trimmed stdout.
               (let ((stdout (s-trim (plist-get result-plist :stdout))))
                 (concur--log :debug "concur:command: Success, resolving with stdout string.")
                 stdout)
             ;; If die-on-error is false, resolve with the full result plist.
             (progn
               (concur--log :debug "concur:command: Success, resolving with full result plist.")
               result-plist))

         ;; --- FAILURE CASE (exit code is non-zero) ---
         (if die-on-error
             ;; If die-on-error is true, reject with the full result plist.
             (progn
               (concur--log :debug "concur:command: Failure, rejecting with result plist.")
               (concur:rejected! result-plist))
           ;; If die-on-error is false, resolve with the full result plist even on failure.
           (progn
             (concur--log :debug "concur:command: Failure, resolving with result plist (:die-on-error is nil).")
             result-plist))))

     ;; 3. This `:catch` block only handles true *creation* errors from `concur:process`
     ;; (e.g., the command executable not found).
     :catch
     (let ((err-info <!>))
       (concur--log :error "concur:command: Process creation failed: %S" err-info)
       ;; Re-reject the promise with the original error information.
       (concur:rejected! err-info)))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands, piping stdout of one to stdin of the next.

This macro creates a sequence of `concur:command` calls where the standard
output (stdout) of each command is used as the standard input (stdin) for
the subsequent command in the chain. The result of the entire pipeline
is the result of the last command.

Arguments:
- `command-forms` (list): A list of command specifications. Each element
  can be either a string (e.g., `\"ls -l\"`) or a list (e.g., `(\"grep\" \"foo\")`).
  Additional keyword arguments for `concur:command` can be included in the list
  after the command itself (e.g., `(\"ls\" \"-l\" :cwd \"/tmp\")`).
  For all but the last command, `:die-on-error t` is implicitly added to ensure
  the pipeline breaks on an error.

Returns:
  (concur:promise): A promise that resolves with the result of the last command
  in the pipeline, or rejects if any command in the pipeline fails."
  (declare (indent 2))
  (unless command-forms
    (error "concur:pipe! requires at least one command form"))

  (let* ((pipeline
          ;; Map over all command forms *except* the first one.
          ;; For each of these, create a lambda that takes the previous command's
          ;; stdout (`<>`) as its stdin.
          (--map
           (let* ((cmd-form it)
                  (cmd (if (listp cmd-form) (car cmd-form) cmd-form))
                  (args (if (listp cmd-form) (cdr cmd-form) nil))
                  (is-last (eq cmd-form (car (last command-forms))))
                  ;; For all commands except the last, ensure `:die-on-error t`
                  ;; so the pipeline breaks on errors. The last command's
                  ;; `:die-on-error` behavior is determined by its own args.
                  (final-args (if is-last
                                  args
                                (plist-put (copy-sequence args) :die-on-error t))))
             ;; Each element in `pipeline` will be a `concur:command` call
             ;; with `:stdin` set to the promise's resolved value (`<>`).
             `(lambda (<>) (concur:command ,cmd :stdin <> ,@final-args)))
           (cdr command-forms)))
         (first-form (car command-forms))
         (first-cmd (if (listp first-form) (car first-form) first-form))
         (first-args (if (listp first-form) (cdr first-form) nil)))

    ;; Construct the `concur:chain`. The first command starts the chain,
    ;; and then the generated `pipeline` lambdas are chained sequentially.
    `(concur:chain (concur:command ,first-cmd ,@first-args) ,@pipeline)))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr
                                       &rest default-keys-plist)
  "Define NAME as a function that runs an async command via `concur:command`.

This macro simplifies the creation of reusable Emacs Lisp functions
that execute external commands asynchronously using `concur:command`.
It allows defining an `interactive` spec and default keyword arguments
for the underlying `concur:command` call.

Arguments:
- `name` (symbol): The name of the function to define.
- `arglist` (list): The argument list for the function, similar to `defun`.
  If `&rest keys` is included, any additional keyword arguments passed to
  the defined function will be forwarded to `concur:command`.
- `docstring` (string): The documentation string for the defined function.
- `command-expr` (form): An Emacs Lisp form that evaluates to the `COMMAND`
  argument for `concur:command`. This can be a string, a list, or a variable.
  It is evaluated at the time `NAME` is called.
- `default-keys-plist` (plist, optional): A plist of default keyword arguments
  to pass to `concur:command`. These defaults can be overridden by arguments
  passed to the defined function `NAME`.
  A special key `:interactive` can be included to define an `interactive` spec.

Example:
  (concur:define-command! my-ls (dir &rest keys)
    \"Run ls -l in DIR.\"
    (format \"ls -l %s\" dir)
    :discard-ansi t
    :interactive \"Ddir\\n\")

  Calling `(my-ls \"/tmp\")` would execute `concur:command` with
  `:command \"ls -l /tmp\"` and `:discard-ansi t`.

Returns:
  (nil): This macro has side effects (defines a function)."
  (declare (indent 2))
  (let* ((interactive-spec (plist-get default-keys-plist :interactive))
         (fn-keys (copy-sequence default-keys-plist)))
    ;; Remove the special :interactive key before passing remaining keys to `concur:command`.
    (cl-remf fn-keys :interactive)
    `(defun ,name ,arglist
       ,docstring
       ;; Include interactive spec if provided.
       ,@(when interactive-spec `((interactive ,interactive-spec)))
       ;; Apply `concur:command` with the `command-expr`,
       ;; appended with default keys and any extra keys passed to the defined function.
       (apply #'concur:command
              ,command-expr
              (append (list ,@fn-keys) ; Default keys provided to the macro.
                      ;; `(boundp 'keys) keys` checks if `&rest keys` was used in `arglist`
                      ;; and if `keys` is non-nil (contains additional arguments).
                      (if (and (boundp 'keys) keys) keys '()))))))

(provide 'concur-exec)
;;; concur-exec.el ends here