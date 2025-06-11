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

Internal helper for `concur:process`. If `die-on-error` is non-nil and the
process failed, an `:error` key is added to the result plist, containing
details about the failure.

Arguments:
- `CMD` (string): The command executable.
- `ARGS` (list): The list of arguments.
- `STDOUT` (string): The raw standard output.
- `STDERR` (string): The raw standard error.
- `EXIT-CODE` (integer): The process exit code.
- `:discard-ansi` (boolean): If non-nil, filter ANSI codes from stdout.
- `:die-on-error` (boolean or string): Controls error creation on non-zero exit.

Returns:
A plist with process results. If `die-on-error` is set and the
process failed, an `:error` key is added."
  (let* ((clean-stdout (if discard-ansi
                           (ansi-color-filter-apply stdout)
                         stdout))
         (result `(:cmd ,cmd :args ,args :exit ,exit-code
                   :stdout ,clean-stdout :stderr ,stderr)))
    (if (and die-on-error (not (zerop exit-code)))
        ;; If the process failed, add error details to the result.
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

This is the low-level interface for process execution. It returns a
promise that resolves with a detailed plist containing the process
outcome. The promise rejects if process creation fails or if the
command exits non-zero and `:die-on-error` is enabled.

Arguments:
- `:command` (string): The executable command (e.g., \"git\").
- `:args` (list of strings, optional): Command arguments.
- `:cwd` (string, optional): Working directory. Defaults to `default-directory`.
- `:env` (alist, optional): Environment variables, e.g., `'((\"VAR\" . \"val\"))`.
- `:discard-ansi` (boolean, optional): If non-nil, filter ANSI codes from stdout.
- `:die-on-error` (boolean or string, optional): If non-nil, the promise
  rejects on non-zero exit. If a string, it is used as the error message.
- `:trace` (string, optional): A message to log before execution.
- `:stdin` (string, optional): Content to pass to the command's stdin.
- `:merge-stderr` (boolean, optional): If non-nil, merge stderr into stdout.
- `:cancel-token` (concur-cancel-token, optional): Kills the process if canceled.
- `:error-callback` (function, optional): `(lambda (err))` called synchronously
  if process creation fails (e.g., command not found).

Returns:
A promise that resolves to a plist with keys `:cmd`, `:args`,
`:exit`, `:stdout`, `:stderr`. If rejected, the reason is a plist
with error details."
  (unless (and command (stringp command) (not (string-empty-p command)))
    (error "concur:process: :command must be a non-empty string"))

  (when trace (concur--log :debug "Trace: %s" trace))

  (concur:with-executor
   (lambda (resolve reject)
     (let* ((proc-name (format "concur-%s" (file-name-nondirectory command)))
            (stdout-buf (generate-new-buffer (format "*%s-stdout*" proc-name)))
            (stderr-buf (unless merge-stderr
                          (generate-new-buffer (format "*%s-stderr*" proc-name))))
            (proc nil))
       (condition-case err
           (progn
             (setq proc
                   (let ((default-directory (or cwd default-directory))
                         (process-environment (append
                                               (--map (format "%s=%s"
                                                              (car it) (cdr it))
                                                      env)
                                               process-environment)))
                     (make-process
                      :name proc-name
                      :buffer stdout-buf
                      :command (cons command (or args '()))
                      :stderr (if merge-stderr proc-pty-slave stderr-buf)
                      :noquery t
                      :connection-type 'pipe)))

             ;; Attach all state directly to the process object
             ;; instead of relying on a fragile lexical closure.
             (process-put proc 'concur-resolve-fn resolve)
             (process-put proc 'concur-reject-fn reject)
             (process-put proc 'concur-stdout-buf stdout-buf)
             (process-put proc 'concur-stderr-buf stderr-buf)
             (process-put proc 'concur-cmd-info
                          (list command args discard-ansi die-on-error))

             (when stdin
               (process-send-string proc stdin)
               (process-send-eof proc))

             (set-process-sentinel
              proc
              (lambda (process _event)
                "Sentinel that retrieves its state from the process object."
                ;; Retrieve all state from the process's property list.
                (let* ((resolve-fn (process-get process 'concur-resolve-fn))
                       (reject-fn (process-get process 'concur-reject-fn))
                       (s-buf (process-get process 'concur-stdout-buf))
                       (e-buf (process-get process 'concur-stderr-buf))
                       (cmd-info (process-get process 'concur-cmd-info))
                       ;; Unpack command info
                       (cmd (nth 0 cmd-info))
                       (cmd-args (nth 1 cmd-info))
                       (d-ansi (nth 2 cmd-info))
                       (d-err (nth 3 cmd-info)))
                  (unwind-protect
                      (let* ((exit-code (process-exit-status process))
                             (stdout (with-current-buffer s-buf (buffer-string)))
                             (stderr (if e-buf (with-current-buffer e-buf
                                                 (buffer-string)) "")))
                        (let* ((result (concur--process-output
                                        cmd cmd-args stdout stderr exit-code
                                        :discard-ansi d-ansi
                                        :die-on-error d-err))
                               (error-info (plist-get result :error)))
                          (if error-info
                              (funcall reject-fn result)
                            (funcall resolve-fn result))))
                    (when (buffer-live-p s-buf) (kill-buffer s-buf))
                    (when (buffer-live-p e-buf) (kill-buffer e-buf))))))

             (when cancel-token
               (concur:cancel-token-on-cancel
                cancel-token
                (lambda ()
                  (when (process-live-p proc)
                    (kill-process proc)
                    (funcall reject
                             `(:error-type concur-exec-cancelled
                               :message ,(format "Process '%s' cancelled" command))))))))
         (error
          (let ((error-info `(:error-type concur-exec-creation-error
                              :message ,(error-message-string err)
                              :original-error ,err)))
            (when error-callback (funcall error-callback error-info))
            (funcall reject error-info)
            (when (buffer-live-p stdout-buf) (kill-buffer stdout-buf))
            (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf)))))))
   cancel-token))

;;;###autoload
(defun concur:command (command &rest keys)
  "Run COMMAND asynchronously and return a promise.

This is a higher-level convenience function built on `concur:process`.
The promise's resolution and rejection behavior depends on `:die-on-error`:

- If `:die-on-error` is `t` (default):
  The promise resolves to the trimmed stdout string on success.
  The promise rejects with the full result plist on non-zero exit.

- If `:die-on-error` is `nil`:
  The promise always resolves with the full result plist (containing
  `:stdout`, `:stderr`, `:exit`, and optionally `:error` if command failed).
  It never rejects due to non-zero exit.

Arguments:
- `COMMAND` (string or list): The command to run. If a string, it is split
  by spaces. If a list, the first element is the executable.
- `KEYS` (plist): Keyword arguments passed directly to `concur:process`.

Results:
  A promise that resolves or rejects based on `:die-on-error`."
  (let* ((cmd-list (if (listp command) command (s-split " " command t)))
         (exe (car cmd-list))
         (args (cdr cmd-list))
         (original-die-on-error (plist-get keys :die-on-error))
         ;; Ensure concur:process receives `die-on-error` flag based on final_keys,
         ;; so its primary rejection logic is correct.
         (final-keys (plist-put (copy-sequence keys)
                                :die-on-error (or original-die-on-error t))))

    (unless (and exe (not (string-empty-p exe)))
      (error "Invalid command provided to concur:command: %S" command))

    (concur:chain
     (apply #'concur:process :command exe :args args final-keys)
     :then (let ((result-plist <>)) ; Process resolves with the full plist now
             (if (or (zerop (plist-get result-plist :exit))
                     (not original-die-on-error)) ; If succeeded OR not dying on error
                 (if original-die-on-error ; If we are dying on error, resolve with stdout
                     (let ((stdout (plist-get result-plist :stdout)))
                       (if (stringp stdout) (s-trim stdout) ""))
                   result-plist) ; If not dying on error, resolve with the whole plist
               ;; If non-zero exit AND original-die-error is true, this path
               ;; might be taken if concur:process resolved unexpectedly.
               ;; Re-reject with the full result plist.
               (concur:rejected! result-plist)))
     :catch
     (let ((err-info <!>)) ;
       ;; If original-die-on-error is nil, this catch block means something went
       ;; wrong *before* process execution (e.g., creation error), not just exit status.
       (if (not original-die-on-error)
           ;; If user specified :die-on-error nil, they expect resolution.
           ;; But if it's a creation error, that's still an error.
           ;; For consistency with :die-on-error nil, resolve with error info.
           err-info
         ;; Otherwise, it's a rejection, so re-reject it.
         (concur:rejected! err-info))))))

;;;###autoload
(defmacro concur:pipe! (&rest command-forms)
  "Chain asynchronous commands, piping stdout of one to stdin of the next.

This macro creates a sequence of `concur:command` calls. It is ideal for
building command-line data processing pipelines.

Arguments:
- `COMMAND-FORMS`: One or more forms, each specifying a command for
  `concur:command`, e.g., `\"ls -l\"` or `('(\"grep\" \"foo\") :cwd \"/tmp\")`.
  Note: Commands in the pipe (except the last) will implicitly have `:die-on-error t`
  to ensure the pipe breaks on failure. The last command respects its own
  `:die-on-error` setting.

Results:
  A promise that resolves with the trimmed stdout of the *last* command (if
  `:die-on-error t` for last command) or the full result plist (if
  `:die-on-error nil` for last command), or rejects if any command in the pipe
  fails and `:die-on-error` is `t` for that command."
  (declare (indent 2))
  (unless command-forms
    (error "concur:pipe! requires at least one command form"))

  (let* ((pipeline
          (--map
           (let* ((cmd-form it)
                  (cmd (if (listp cmd-form) (car cmd-form) cmd-form))
                  (args (if (listp cmd-form) (cdr cmd-form) nil))
                  (is-last (eq cmd-form (car (last command-forms))))
                  ;; Ensure commands in pipe (except last) die on error to break pipe
                  (final-args (if is-last
                                  args
                                (plist-put (copy-sequence args) :die-on-error t))))
             `(lambda (<>) (concur:command ,cmd :stdin <> ,@final-args)))
           (cdr command-forms)))
         (first-form (car command-forms))
         (first-cmd (if (listp first-form) (car first-form) first-form))
         (first-args (if (listp first-form) (cdr first-form) nil)))

    `(concur:chain (concur:command ,first-cmd ,@first-args) ,@pipeline)))

;;;###autoload
(defmacro concur:define-command! (name arglist docstring command-expr
                                       &rest default-keys-plist)
  "Define NAME as a function that runs an async command via `concur:command`.

Arguments:
- `NAME` (symbol): The name of the new function.
- `ARGLIST` (list): The argument list for the new function.
- `DOCSTRING` (string): The docstring for the new function.
- `COMMAND-EXPR` (form): A form that evaluates to the command string/list.
- `DEFAULT-KEYS-PLIST`: Default keyword arguments for `concur:command`.

Keyword Arguments:
- `:interactive` (string or t, optional): An `interactive` spec for the function.

Results:
  This macro defines a new function and has no return value."
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