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

(define-error 'concur-exec-error "Error during process execution.")

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




;; ;;; concur-exec.el --- Asynchronous Process Execution with Promises -*-
;; ;;; lexical-binding: t; -*-

;; ;;; Commentary:
;; ;;
;; ;; This library provides a robust framework for running external commands
;; ;; asynchronously, handling their results with promises. It streamlines common
;; ;; patterns for process execution and chaining, offering a high-level API over
;; ;; raw Emacs processes.
;; ;;
;; ;; At its core, this module offers two low-level process primitives:
;; ;;
;; ;; 1. `concur:process` (formerly `concur:process-raw`): A traditional,
;; ;;    non-coroutine-based process execution that captures output to in-memory
;; ;;    buffers or streams it to direct callbacks. It is suitable for commands
;; ;;    with manageable output sizes.
;; ;;
;; ;; 2. `concur:iprocess`: A highly optimized, coroutine-based primitive that
;; ;;    excels at handling commands with very large outputs. It always buffers
;; ;;    process output to an internal temporary file and provides a coroutine
;; ;;    to yield chunks from a small, efficiently refilled in-memory buffer.
;; ;;
;; ;; Building on these primitives, the library provides high-level macros:
;; ;;
;; ;; - `concur:command`: A user-friendly wrapper around `concur:iprocess` that
;; ;;   dynamically manages output, accumulating it in memory for smaller results
;; ;;   and automatically spilling to a temporary file for larger ones.
;; ;;
;; ;; - `concur:pipe!`: A macro for elegantly chaining multiple commands, piping
;; ;;   the stdout of one to the stdin of the next.
;; ;;
;; ;; - `concur:define-command!`: A convenience macro for defining reusable
;; ;;   asynchronous command functions.
;; ;;
;; ;; The module extensively uses `cl-defstruct` for clear, type-safe data
;; ;; structures and emphasizes robust error handling and resource management.

;; ;;; Code:

;; (require 'cl-lib)
;; (require 'dash)
;; (require 's)
;; (require 'concur-promise)
;; (require 'ansi-color)
;; (require 'concur-hooks) ; For concur--log
;; (require 'coroutines)
;; (require 'seq)

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Configuration Constants
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (defconst concur-output-ring-buffer-size 100
;;   "Default maximum number of chunks to store in the internal ring buffer
;; for `concur:iprocess` output coroutines. This acts as a cushion
;; between file reads and coroutine yields.")

;; (defconst concur-output-read-chunk-size 4096
;;   "Default size (in bytes) of chunks to read from internal temporary files
;; into the ring buffer for `concur:iprocess` output coroutines.")

;; (defconst concur-output-buffer-fill-threshold 50
;;   "Minimum number of chunks remaining in the ring buffer before
;; triggering a background read to refill it.")

;; (defcustom concur-process-background-read-interval 0.05
;;   "Interval in seconds for the background reader in `concur:iprocess`
;; to check for new output to read from temporary files."
;;   :type 'number
;;   :group 'concur-exec)

;; (defcustom concur-output-file-buffer-size 16384
;;   "Size in bytes for the internal buffer used when writing to temporary
;; files in process filters. Larger buffers reduce file I/O calls."
;;   :type 'integer
;;   :group 'concur-exec)

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Structs & Error Conditions
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (define-error 'concur-exec-error "Error during process execution.")
;; (define-error 'concur-exec-creation-error "Error creating process." 'concur-exec-error)
;; (define-error 'concur-exec-cancelled "Process was cancelled." 'concur-exec-error)
;; (define-error 'concur-exec-timeout "Process execution timed out." 'concur-exec-error)
;; (define-error 'concur-pipe-error "Error during pipe execution." 'concur-exec-error)

;; (cl-defstruct (concur-exec-error-info
;;                (:constructor make-concur-exec-error-info
;;                              (&key message exit-code stdout stderr cmd args
;;                                    cwd env original-error timeout
;;                                    process-status signal reason)))
;;   "Detailed information about a `concur-exec` error."
;;   (message "" :type string)
;;   (exit-code nil :type (or integer null))
;;   (stdout nil :type (or string null))
;;   (stderr nil :type (or string null))
;;   (cmd nil :type (or string null))
;;   (args nil :type (or list null))
;;   (cwd nil :type (or string null))
;;   (env nil :type (or list null))
;;   (original-error nil)
;;   (timeout nil :type (or number null))
;;   (process-status nil :type (or symbol string null))
;;   (signal nil :type (or string null))
;;   (reason nil :type (or symbol null)))

;; (cl-defstruct (concur-process-result
;;                (:constructor make-concur-process-result
;;                              (&key cmd args exit stdout stderr
;;                                    stdout-file-path stderr-file-path cleanup-fn
;;                                    stdout-coroutine stderr-coroutine)))
;;   "Represents the result of a process execution."
;;   (cmd "" :type string)
;;   (args nil :type list)
;;   (exit 0 :type integer)
;;   (stdout "" :type string)
;;   (stderr "" :type string)
;;   (stdout-file-path nil :type (or string null))
;;   (stderr-file-path nil :type (or string null))
;;   (cleanup-fn nil :type (or function null))
;;   (stdout-coroutine nil)
;;   (stderr-coroutine nil))

;; (cl-defstruct (concur-command-output-state
;;                (:constructor make-concur-command-output-state))
;;   "Internal state for managing output accumulation in `concur:command`."
;;   cmd-exe
;;   explicit-output-to-file
;;   max-memory-output-bytes
;;   (output-spilled-to-file-p nil :type boolean)
;;   (stdout-chunks nil :type list)
;;   (stdout-size 0 :type integer)
;;   (stdout-file-path nil :type (or string null))
;;   stdout-file-fd
;;   (stdout-file-buffer "" :type string)
;;   (stderr-chunks nil :type list)
;;   (stderr-size 0 :type integer)
;;   (stderr-file-path nil :type (or string null))
;;   stderr-file-fd
;;   (stderr-file-buffer "" :type string))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Core Utilities
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (defun concur--filter-plist (plist keys-to-remove)
;;   "Return a copy of PLIST with KEYS-TO-REMOVE and their values removed."
;;   (let (new-plist)
;;     (while plist
;;       (let ((k (pop plist))
;;             (v (pop plist)))
;;         (unless (member k keys-to-remove)
;;           (setq new-plist (nconc new-plist (list k v))))))
;;     new-plist))

;; (defun concur--delete-file-if-exists (file-path)
;;   "Delete FILE-PATH if it exists, logging any errors."
;;   (when (and file-path (file-exists-p file-path))
;;     (condition-case err
;;         (delete-file file-path)
;;       (error (concur--log :error "Failed to delete temporary file %s: %S"
;;                           file-path err)
;;              nil))))

;; (defvar concur--deferred-cleanup-timer nil
;;   "Timer for deferred file cleanup.")
;; (defvar concur--files-to-delete-deferred nil
;;   "A list of file paths to be deleted by `concur--deferred-cleanup-timer`.")

;; (defun concur--delete-files-deferred (files)
;;   "Add FILES to a list for deferred deletion.
;; This is useful for cleaning up temporary files from process results
;; without blocking and without risking deleting a file that might still
;; be briefly in use."
;;   (when files
;;     (setq concur--files-to-delete-deferred
;;           (nconc concur--files-to-delete-deferred (remq nil files)))
;;     (unless (and concur--deferred-cleanup-timer (timerp concur--deferred-cleanup-timer))
;;       (setq concur--deferred-cleanup-timer
;;             (run-with-idle-timer 5.0 t #'concur--process-deferred-deletions)))))

;; (defun concur--process-deferred-deletions ()
;;   "Process the list of files for deferred deletion."
;;   (let ((files-to-process concur--files-to-delete-deferred))
;;     (setq concur--files-to-delete-deferred nil)
;;     (dolist (file files-to-process)
;;       (concur--delete-file-if-exists file)))
;;   (when (null concur--files-to-delete-deferred)
;;     (when (timerp concur--deferred-cleanup-timer)
;;         (cancel-timer concur--deferred-cleanup-timer))
;;     (setq concur--deferred-cleanup-timer nil)))

;; (defun concur--kill-process-buffers (stdout-buf stderr-buf)
;;   "Safely kill the stdout and stderr buffers if they are live."
;;   (when (and stdout-buf (buffer-live-p stdout-buf))
;;     (kill-buffer stdout-buf))
;;   (when (and stderr-buf (buffer-live-p stderr-buf))
;;     (kill-buffer stderr-buf)))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Common Process Execution Helpers
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (cl-defun concur--format-process-result (cmd args stdout stderr exit-code
;;                                           &key discard-ansi die-on-error
;;                                           cwd env process-status signal)
;;   "Formats raw process output into a result struct or an error condition."
;;   (let ((clean-stdout (if discard-ansi
;;                           (ansi-color-filter-apply stdout)
;;                         stdout)))
;;     (if (and die-on-error (/= exit-code 0))
;;         `(concur-exec-error .
;;           ,(make-concur-exec-error-info
;;             :message (format "Command '%s' failed with exit code %d"
;;                              (s-join " " (cons cmd args)) exit-code)
;;             :exit-code exit-code :stdout clean-stdout :stderr stderr
;;             :cmd cmd :args args :cwd cwd :env env
;;             :process-status process-status :signal signal))
;;       (make-concur-process-result
;;        :cmd cmd :args args :exit exit-code
;;        :stdout clean-stdout :stderr stderr))))

;; (cl-defun concur--start-process (name-prefix command args
;;                                  &key cwd env sentinel filter
;;                                  stdout-buf stderr-buf merge-stderr)
;;   "Initializes and returns a new Emacs process.
;; This consolidates the call to `make-process` and sets the environment."
;;   (let ((default-directory (or cwd default-directory))
;;         (process-environment
;;          (if env (append (seq-map (lambda (it) (format "%s=%s" (car it) (cdr it))) env)
;;                          process-environment)
;;            process-environment)))
;;     (make-process
;;      :name (format "%s-%s" name-prefix (file-name-nondirectory command))
;;      :buffer stdout-buf
;;      :command (cons command (or args '()))
;;      :stderr (if merge-stderr t stderr-buf)
;;      :noquery t
;;      :sentinel sentinel
;;      :filter filter
;;      :connection-type 'pipe)))

;; (cl-defun concur--setup-process-context (promise proc
;;                                          &key command args discard-ansi
;;                                          die-on-error cancel-token
;;                                          timeout cwd env)
;;   "Attaches common context properties to a process object.
;; This includes setting up timeout and cancellation handlers."
;;   (setf (concur-promise-proc promise) proc)
;;   (process-put proc 'concur-promise promise)
;;   (process-put proc 'concur-command command)
;;   (process-put proc 'concur-args args)
;;   (process-put proc 'concur-discard-ansi discard-ansi)
;;   (process-put proc 'concur-die-on-error die-on-error)
;;   (process-put proc 'concur-cwd cwd)
;;   (process-put proc 'concur-env env)

;;   (when timeout
;;     (let ((timer (run-at-time
;;                   timeout nil
;;                   (lambda ()
;;                     (when (process-live-p proc)
;;                       (kill-process proc)
;;                       (concur--log :warn "Process '%s' timed out after %s seconds."
;;                                    command timeout)
;;                       (concur:reject
;;                        promise `(concur-exec-timeout .
;;                                  ,(make-concur-exec-error-info
;;                                    :reason :timeout :timeout timeout
;;                                    :message (format "Command '%s' timed out" command)
;;                                    :cmd command :args args :cwd cwd :env env))))))))
;;       (process-put proc 'concur-timeout-timer timer)))

;;   (when cancel-token
;;     (concur:cancel-token-on-cancel
;;      cancel-token
;;      (lambda ()
;;        (when (process-live-p proc)
;;          (kill-process proc)
;;          (concur:reject promise
;;                         `(concur-exec-cancelled .
;;                           ,(make-concur-exec-error-info
;;                             :reason :cancelled
;;                             :message (format "Process '%s' cancelled" command)
;;                             :cmd command :args args :cwd cwd :env env))))))))

;; (cl-defun concur--handle-creation-error (promise err
;;                                          &key command args error-callback
;;                                          cwd env proc
;;                                          stdout-buf stderr-buf)
;;   "Handles process creation errors, ensuring resource cleanup and rejection."
;;   (when (and proc (process-live-p proc)) (kill-process proc))
;;   ;; Only kill buffers if they were created internally for capture.
;;   (when (and stdout-buf
;;              (buffer-name stdout-buf)
;;              (s-starts-with-p "*concur-raw-" (buffer-name stdout-buf)))
;;     (concur--kill-process-buffers stdout-buf stderr-buf))

;;   (let ((error-info `(concur-exec-creation-error .
;;                       ,(make-concur-exec-error-info
;;                         :message (error-message-string err)
;;                         :original-error err
;;                         :cmd command :args args :cwd cwd :env env
;;                         :reason :creation-error))))
;;     (when error-callback (funcall error-callback error-info))
;;     (concur--log :error "Process creation for '%s' failed: %s"
;;                  command (error-message-string err))
;;     (concur:reject promise error-info)))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Coroutine-based Process Execution (`concur:iprocess`)
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (defcoroutine! concur--output-coroutine (process-obj file-path-in file-fd-in)
;;   "Coroutine that yields chunks of process output from a file-backed stream.
;; It reads from a temporary file into a small in-memory ring buffer, which
;; is refilled by a background timer.

;; This coroutine expects the process to have finished and all output to have
;; been written to the file before it is consumed.

;; Yields:
;; - `(:chunk CHUNK)`: A chunk of output string.
;; - (Coroutines convention): The final return value is the done plist."
;;   :locals ((process process-obj)
;;            (file-path file-path-in)
;;            (file-fd file-fd-in)
;;            (buffer-queue (make-ring concur-output-ring-buffer-size))
;;            (background-reader-timer nil)
;;            (eof-reached-p nil))

;;   ;; `unwind-protect` ensures cleanup happens even if the coroutine is killed.
;;   (unwind-protect
;;       (progn
;;         (concur--log :debug "Output coroutine started for file: %S" file-path)

;;         ;; Start background file reader timer.
;;         (setq background-reader-timer
;;               (run-with-timer 0.0 concur-process-background-read-interval
;;                               (lambda ()
;;                                 (when (and file-fd (not eof-reached-p)
;;                                            (< (ring-length buffer-queue)
;;                                               concur-output-buffer-fill-threshold))
;;                                   (condition-case err
;;                                       (let ((chunk (read-string concur-output-read-chunk-size file-fd)))
;;                                         (if chunk
;;                                             (ring-insert buffer-queue chunk)
;;                                           ;; EOF reached.
;;                                           (setq eof-reached-p t)))
;;                                     (error
;;                                      (concur--log :error "Error reading from temp file %s: %S" file-path err)
;;                                      ;; Stop the timer on error.
;;                                      (setq eof-reached-p t)))))))

;;         ;; Main yield loop.
;;         (while (not (and eof-reached-p (ring-empty-p buffer-queue)))
;;           (if-let ((chunk (ring-pop buffer-queue)))
;;               (yield! `(:chunk ,chunk))
;;             ;; Buffer is empty but not EOF yet, so we wait.
;;             ;; `sit-for` is a simple way to yield control without a complex `receive!`
;;             ;; loop, as this coroutine is designed to be pulled from, not pushed to.
;;             (sit-for 0.01))))

;;   ;; --- Cleanup ---
;;   (when (timerp background-reader-timer)
;;     (cancel-timer background-reader-timer))
;;   (when file-fd
;;     (close file-fd))
;;   (concur--log :debug "Output coroutine finished for file: %S" file-path)))


;; (defun concur--iprocess-sentinel (process event)
;;   "Sentinel for `concur:iprocess`. Resolves the promise upon process completion."
;;   (let ((status (process-status process)))
;;     (when (memq status '(exit signal finished))
;;       (let* ((promise (process-get process 'concur-promise))
;;              (timer (process-get process 'concur-timeout-timer))
;;              (cmd (process-get process 'concur-command))
;;              (args (process-get process 'concur-args))
;;              (die-on-error (process-get process 'concur-die-on-error))
;;              (cwd (process-get process 'concur-cwd))
;;              (env (process-get process 'concur-env))
;;              (exit-code (process-exit-status process))
;;              (process-signal (if (eq status 'signal) (process-signal-process process) nil))
;;              ;; Retrieve file FDs to close them.
;;              (stdout-write-fd (process-get process 'concur-stdout-write-fd))
;;              (stderr-write-fd (process-get process 'concur-stderr-write-fd))
;;              (stdout-write-buffer (process-get process 'concur-stdout-write-buffer))
;;              (stderr-write-buffer (process-get process 'concur-stderr-write-buffer)))

;;         (when (timerp timer) (cancel-timer timer))

;;         ;; Flush any remaining data from process filter buffers to the files.
;;         (when (and stdout-write-fd (file-descriptor-p stdout-write-fd) (> (length stdout-write-buffer) 0))
;;             (file-write-string stdout-write-buffer stdout-write-fd))
;;         (when (and stderr-write-fd (file-descriptor-p stderr-write-fd) (> (length stderr-write-buffer) 0))
;;             (file-write-string stderr-write-buffer stderr-write-fd))

;;         ;; Close the write ends of the file descriptors.
;;         (when (and stdout-write-fd (file-descriptor-p stdout-write-fd)) (close stdout-write-fd))
;;         (when (and stderr-write-fd (file-descriptor-p stderr-write-fd)) (close stderr-write-fd))

;;         ;; Clean up dummy buffers.
;;         (concur--kill-process-buffers (process-buffer process) (process-stderr-buffer process))

;;         (when (and promise (concur:pending-p promise))
;;           (let ((result-or-error
;;                  (concur--format-process-result cmd args "" "" exit-code
;;                                                 :die-on-error die-on-error
;;                                                 :cwd cwd :env env
;;                                                 :process-status status
;;                                                 :signal process-signal)))
;;             (if (consp result-or-error) ;; Error case
;;                 (concur:reject promise (cdr result-or-error))
;;               ;; Success case: Set up result with coroutines for output.
;;               (let* ((stdout-path (process-get process 'concur-stdout-temp-file))
;;                      (stderr-path (process-get process 'concur-stderr-temp-file))
;;                      (merge-stderr (process-get process 'concur-merge-stderr))
;;                      (stdout-read-fd (cl-open stdout-path :direction 'input))
;;                      (stderr-read-fd (unless merge-stderr (cl-open stderr-path :direction 'input))))

;;                 (setf (concur-process-result-stdout-coroutine result-or-error)
;;                       (concur--output-coroutine process stdout-path stdout-read-fd))
;;                 (unless merge-stderr
;;                   (setf (concur-process-result-stderr-coroutine result-or-error)
;;                         (concur--output-coroutine process stderr-path stderr-read-fd)))

;;                 (setf (concur-process-result-stdout-file-path result-or-error) stdout-path)
;;                 (setf (concur-process-result-stderr-file-path result-or-error) stderr-path)
;;                 (setf (concur-process-result-cleanup-fn result-or-error)
;;                       (lambda ()
;;                         (concur--delete-files-deferred (list stdout-path stderr-path))))
;;                 (concur:resolve promise result-or-error)))))))))

;; (cl-defun concur--create-temp-file-for-output (cmd-name stream-name)
;;   "Creates a temporary file for stdout or stderr and returns a plist."
;;   (let* ((path (make-temp-file (format "concur-%s-%s-" cmd-name stream-name)))
;;          (fd (cl-open path :direction 'output
;;                       :if-exists 'supersede :if-does-not-exist 'create)))
;;     `(:path ,path :fd ,fd)))

;; ;;;###autoload
;; (cl-defun concur:iprocess (&key command args cwd env die-on-error
;;                                 stdin merge-stderr cancel-token
;;                                 error-callback timeout stdin-file &allow-other-keys)
;;   "Run COMMAND asynchronously, streaming output to temp files.
;; This is a low-level primitive using coroutines for output streaming, ideal
;; for very large data. The promise resolves to a `concur-process-result` struct
;; where `stdout-coroutine` and `stderr-coroutine` fields can be used to consume
;; the output chunk by chunk.

;; Arguments:
;; - `command` (string): The executable command to run.
;; - `args` (list of string): Arguments for the command.
;; - `cwd` (string, optional): The working directory.
;; - `env` (alist, optional): Environment variables.
;; - `die-on-error` (boolean, optional): If t, reject on non-zero exit.
;; - `stdin` (string, optional): String to send to stdin.
;; - `stdin-file` (string, optional): Path to a file for stdin. Overrides `stdin`.
;; - `merge-stderr` (boolean, optional): If t, merge stderr into stdout.
;; - `cancel-token` (`concur-cancel-token`, optional): Token to cancel the process.
;; - `error-callback` (function, optional): Called on process creation error.
;; - `timeout` (number, optional): Timeout in seconds.

;; Results:
;; - (`concur-promise`): A promise that resolves to a `concur-process-result` struct."
;;   (unless (and command (stringp command) (not (s-blank-p command)))
;;     (error "concur:iprocess: :command must be a non-empty string"))
;;   (let ((promise (concur:make-promise :cancel-token cancel-token))
;;         (proc nil)
;;         (stdout-info nil) (stderr-info nil)
;;         (stdout-write-buffer "") (stderr-write-buffer ""))
;;     (unwind-protect
;;          (condition-case err
;;              (progn
;;                ;; 1. Setup temporary files for output.
;;                (setq stdout-info (concur--create-temp-file-for-output (file-name-nondirectory command) "stdout"))
;;                (unless merge-stderr
;;                  (setq stderr-info (concur--create-temp-file-for-output (file-name-nondirectory command) "stderr")))

;;                ;; 2. Initialize the process.
;;                (setq proc
;;                      (concur--start-process
;;                       "concur" command args :cwd cwd :env env
;;                       :sentinel #'concur--iprocess-sentinel
;;                       :filter (lambda (_p chunk)
;;                                 (if (eq (current-buffer) (process-buffer _p))
;;                                     ;; Stdout
;;                                     (progn
;;                                       (setq stdout-write-buffer (concat stdout-write-buffer chunk))
;;                                       (when (>= (length stdout-write-buffer) concur-output-file-buffer-size)
;;                                         (file-write-string stdout-write-buffer (plist-get stdout-info :fd))
;;                                         (setq stdout-write-buffer "")))
;;                                   ;; Stderr
;;                                   (progn
;;                                     (setq stderr-write-buffer (concat stderr-write-buffer chunk))
;;                                     (when (>= (length stderr-write-buffer) concur-output-file-buffer-size)
;;                                       (file-write-string stderr-write-buffer (plist-get stderr-info :fd))
;;                                       (setq stderr-write-buffer "")))))
;;                       :stdout-buf (get-buffer-create (format "*concur-%s-stdout-dummy*" (process-id proc)))
;;                       :stderr-buf (unless merge-stderr (get-buffer-create (format "*concur-%s-stderr-dummy*" (process-id proc))))
;;                       :merge-stderr merge-stderr))

;;                ;; 3. Attach context to the process object.
;;                (process-put proc 'concur-stdout-temp-file (plist-get stdout-info :path))
;;                (process-put proc 'concur-stdout-write-fd (plist-get stdout-info :fd))
;;                (process-put proc 'concur-stdout-write-buffer stdout-write-buffer) ; Pass buffer reference
;;                (unless merge-stderr
;;                  (process-put proc 'concur-stderr-temp-file (plist-get stderr-info :path))
;;                  (process-put proc 'concur-stderr-write-fd (plist-get stderr-info :fd))
;;                  (process-put proc 'concur-stderr-write-buffer stderr-write-buffer))
;;                (process-put proc 'concur-merge-stderr merge-stderr)

;;                (concur--setup-process-context promise proc
;;                  :command command :args args :die-on-error die-on-error
;;                  :cancel-token cancel-token :timeout timeout :cwd cwd :env env)

;;                ;; 4. Handle stdin.
;;                (cond
;;                 (stdin-file
;;                  (unless (file-exists-p stdin-file)
;;                    (error "concur:iprocess: :stdin-file '%s' does not exist" stdin-file))
;;                  (with-temp-buffer
;;                    (insert-file-contents stdin-file)
;;                    (process-send-string proc (buffer-string))))
;;                 (stdin
;;                  (process-send-string proc stdin)))
;;                (when (or stdin stdin-file)
;;                  (process-send-eof proc)))

;;            (error
;;             (concur--handle-creation-error promise err
;;                                            :command command :args args
;;                                            :error-callback error-callback
;;                                            :cwd cwd :env env :proc proc)))
;;       ;; Unwind-protect cleanup: Ensure files/fds are cleaned up if an error
;;       ;; occurs during setup before the sentinel can take over.
;;       (when (concur:pending-p promise)
;;         (when-let ((fd (plist-get stdout-info :fd))) (close fd))
;;         (when-let ((fd (plist-get stderr-info :fd))) (close fd))
;;         (concur--delete-file-if-exists (plist-get stdout-info :path))
;;         (concur--delete-file-if-exists (plist-get stderr-info :path)))))
;;     promise))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; Raw Buffer-based Process Execution (`concur:process`)
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (defun concur--raw-process-filter (process string)
;;   "Process filter for `concur:process`. Writes to buffers or calls callbacks."
;;   (let* ((on-stdout (process-get process 'concur-on-stdout))
;;          (on-stderr (process-get process 'concur-on-stderr))
;;          (is-stdout (eq (current-buffer) (process-buffer process))))
;;     (cond
;;      ((and is-stdout on-stdout) (funcall on-stdout string))
;;      ((and (not is-stdout) on-stderr) (funcall on-stderr string))
;;      (t (with-current-buffer (current-buffer) (insert string))))))

;; (defun concur--raw-sentinel-handler (process event)
;;   "Sentinel for `concur:process`. Settles the promise with buffer content."
;;   (let ((status (process-status process)))
;;     (when (memq status '(exit signal finished))
;;       (let* ((promise (process-get process 'concur-promise))
;;              (timer (process-get process 'concur-timeout-timer))
;;              (s-buf (process-get process 'concur-stdout-buf))
;;              (e-buf (process-get process 'concur-stderr-buf))
;;              (on-stdout (process-get process 'concur-on-stdout))
;;              (on-stderr (process-get process 'concur-on-stderr))
;;              (cmd (process-get process 'concur-command))
;;              (args (process-get process 'concur-args))
;;              (d-ansi (process-get process 'concur-discard-ansi))
;;              (d-err (process-get process 'concur-die-on-error))
;;              (cwd (process-get process 'concur-cwd))
;;              (env (process-get process 'concur-env))
;;              (exit-code (process-exit-status process))
;;              (process-signal (if (eq status 'signal) (process-signal-process process) nil)))

;;         (when (timerp timer) (cancel-timer timer))

;;         (when (and promise (concur:pending-p promise))
;;           (let* ((stdout (if on-stdout "" (if (buffer-live-p s-buf) (with-current-buffer s-buf (buffer-string)) "")))
;;                  (stderr (if on-stderr "" (if (and e-buf (buffer-live-p e-buf)) (with-current-buffer e-buf (buffer-string)) "")))
;;                  (result-or-error
;;                   (concur--format-process-result cmd args stdout stderr exit-code
;;                                                  :discard-ansi d-ansi :die-on-error d-err
;;                                                  :cwd cwd :env env :process-status status
;;                                                  :signal process-signal)))
;;             (unless on-stdout (concur--kill-process-buffers s-buf e-buf))
;;             (if (consp result-or-error)
;;                 (concur:reject promise (cdr result-or-error))
;;               (concur:resolve promise result-or-error))))))))

;; ;;;###autoload
;; (cl-defun concur:process (&key command args cwd env discard-ansi die-on-error
;;                                stdin merge-stderr cancel-token stdin-file
;;                                error-callback on-stdout on-stderr timeout
;;                                &allow-other-keys)
;;   "Run COMMAND asynchronously, capturing output to buffers or callbacks.
;; This is a traditional async process primitive, suitable for commands
;; with manageable output sizes.

;; Arguments:
;; - `command` (string): The executable command to run.
;; - `args` (list of string): Arguments for the command.
;; - `on-stdout` (function, optional): Callback `(lambda (string))` for stdout
;;   chunks. If provided, `stdout` in the result will be empty.
;; - `on-stderr` (function, optional): Callback `(lambda (string))` for stderr
;;   chunks. If provided, `stderr` in the result will be empty.
;; - (Other keys are the same as `concur:iprocess`)

;; Results:
;; - (`concur-promise`): A promise resolving to a `concur-process-result` struct."
;;   (unless (and command (stringp command) (not (s-blank-p command)))
;;     (error "concur:process: :command must be a non-empty string"))
;;   (let ((promise (concur:make-promise :cancel-token cancel-token))
;;         (proc nil) (stdout-buf nil) (stderr-buf nil))
;;     (condition-case err
;;         (progn
;;           ;; 1. Create buffers for capturing output.
;;           (setq stdout-buf (generate-new-buffer (format "*concur-raw-%s-stdout*" command)))
;;           (unless merge-stderr
;;             (setq stderr-buf (generate-new-buffer (format "*concur-raw-%s-stderr*" command))))

;;           ;; 2. Initialize the process.
;;           (setq proc
;;                 (concur--start-process
;;                  "concur-raw" command args :cwd cwd :env env
;;                  :sentinel #'concur--raw-sentinel-handler
;;                  :filter #'concur--raw-process-filter
;;                  :stdout-buf stdout-buf :stderr-buf stderr-buf
;;                  :merge-stderr merge-stderr))

;;           ;; 3. Attach context.
;;           (concur--setup-process-context promise proc
;;             :command command :args args :discard-ansi discard-ansi
;;             :die-on-error die-on-error :cancel-token cancel-token
;;             :timeout timeout :cwd cwd :env env)
;;           (process-put proc 'concur-stdout-buf stdout-buf)
;;           (process-put proc 'concur-stderr-buf stderr-buf)
;;           (process-put proc 'concur-on-stdout on-stdout)
;;           (process-put proc 'concur-on-stderr on-stderr)
;;           (process-put proc 'concur-merge-stderr merge-stderr)

;;           ;; 4. Handle stdin.
;;           (cond
;;            (stdin-file
;;             (unless (file-exists-p stdin-file)
;;               (error "concur:process: :stdin-file '%s' does not exist" stdin-file))
;;             (with-temp-buffer
;;               (insert-file-contents stdin-file)
;;               (process-send-string proc (buffer-string))))
;;            (stdin
;;             (process-send-string proc stdin)))
;;           (when (or stdin stdin-file)
;;             (process-send-eof proc)))

;;       (error
;;        (concur--handle-creation-error promise err
;;                                       :command command :args args
;;                                       :error-callback error-callback
;;                                       :cwd cwd :env env :proc proc
;;                                       :stdout-buf stdout-buf
;;                                       :stderr-buf stderr-buf)))
;;     promise))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ;;; High-level `concur:command` and Helpers
;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (cl-defun concur--command-handle-chunk (chunk output-state stream-type user-callback)
;;   "Handles an output chunk for `concur:command`, managing memory/file spill."
;;   (when user-callback (funcall user-callback chunk))

;;   (let* ((output-spilled-p (concur-command-output-state-output-spilled-to-file-p output-state))
;;          (max-mem (concur-command-output-state-max-memory-output-bytes output-state))
;;          (is-stdout (eq stream-type 'stdout)))
;;     (cond
;;      ;; --- Case 1: Already writing to a file ---
;;      (output-spilled-p
;;       (let* ((fd (if is-stdout
;;                      (concur-command-output-state-stdout-file-fd output-state)
;;                    (concur-command-output-state-stderr-file-fd output-state)))
;;              (buffer-sym (if is-stdout
;;                              'stdout-file-buffer
;;                            'stderr-file-buffer)))
;;         (when fd
;;           (setf (slot-value output-state buffer-sym) (concat (slot-value output-state buffer-sym) chunk))
;;           (when (>= (length (slot-value output-state buffer-sym)) concur-output-file-buffer-size)
;;             (file-write-string (slot-value output-state buffer-sym) fd)
;;             (setf (slot-value output-state buffer-sym) "")))))

;;      ;; --- Case 2: In memory, check if we need to spill to file ---
;;      ((and max-mem
;;            (> (+ (if is-stdout
;;                      (concur-command-output-state-stdout-size output-state)
;;                    (concur-command-output-state-stderr-size output-state))
;;                  (length chunk))
;;               max-mem))
;;       (setf (concur-command-output-state-output-spilled-to-file-p output-state) t)
;;       (let* ((base-path (concur-command-output-state-explicit-output-to-file output-state))
;;              (exe (concur-command-output-state-cmd-exe output-state))
;;              (stdout-info (concur--create-temp-file-for-output exe "stdout"))
;;              (stderr-info (concur--create-temp-file-for-output exe "stderr")))
;;         ;; Set up file paths and FDs for both streams
;;         (setf (concur-command-output-state-stdout-file-path output-state) (plist-get stdout-info :path))
;;         (setf (concur-command-output-state-stdout-file-fd output-state) (plist-get stdout-info :fd))
;;         (setf (concur-command-output-state-stderr-file-path output-state) (plist-get stderr-info :path))
;;         (setf (concur-command-output-state-stderr-file-fd output-state) (plist-get stderr-info :fd))
;;         ;; Write existing chunks
;;         (dolist (c (concur-command-output-state-stdout-chunks output-state))
;;           (file-write-string c (plist-get stdout-info :fd)))
;;         (dolist (c (concur-command-output-state-stderr-chunks output-state))
;;           (file-write-string c (plist-get stderr-info :fd)))
;;         (setf (concur-command-output-state-stdout-chunks output-state) nil)
;;         (setf (concur-command-output-state-stderr-chunks output-state) nil)
;;         ;; Write the current chunk
;;         (file-write-string chunk
;;                            (if is-stdout
;;                                (concur-command-output-state-stdout-file-fd output-state)
;;                              (concur-command-output-state-stderr-file-fd output-state)))))

;;      ;; --- Case 3: Accumulate in memory ---
;;      (t (if is-stdout
;;             (progn
;;               (push chunk (concur-command-output-state-stdout-chunks output-state))
;;               (cl-incf (concur-command-output-state-stdout-size output-state) (length chunk)))
;;           (push chunk (concur-command-output-state-stderr-chunks output-state))
;;           (cl-incf (concur-command-output-state-stderr-size output-state) (length chunk)))))))

;; (cl-defun concur--finalize-command-output (result-obj output-state discard-ansi)
;;   "Finalizes the `concur:command` result based on the output state.
;; This function consumes the `output-state` struct, closing file
;; descriptors and assembling the final `stdout`/`stderr` values."
;;   (if (concur-command-output-state-output-spilled-to-file-p output-state)
;;       ;; --- File output mode ---
;;       (progn
;;         (when-let ((fd (concur-command-output-state-stdout-file-fd output-state)))
;;           (file-write-string (concur-command-output-state-stdout-file-buffer output-state) fd)
;;           (close fd))
;;         (when-let ((fd (concur-command-output-state-stderr-file-fd output-state)))
;;           (file-write-string (concur-command-output-state-stderr-file-buffer output-state) fd)
;;           (close fd))
;;         (setf (concur-process-result-stdout result-obj) (concur-command-output-state-stdout-file-path output-state))
;;         (setf (concur-process-result-stderr result-obj) (concur-command-output-state-stderr-file-path output-state))
;;         (setf (concur-process-result-stdout-file-path result-obj) (concur-command-output-state-stdout-file-path output-state))
;;         (setf (concur-process-result-stderr-file-path result-obj) (concur-command-output-state-stderr-file-path output-state))
;;         (setf (concur-process-result-cleanup-fn result-obj)
;;               (lambda ()
;;                 (concur--delete-files-deferred
;;                  (list (concur-command-output-state-stdout-file-path output-state)
;;                        (concur-command-output-state-stderr-file-path output-state))))))
;;     ;; --- Memory output mode ---
;;     (let* ((stdout-str (s-join "" (reverse (concur-command-output-state-stdout-chunks output-state))))
;;            (stderr-str (s-join "" (reverse (concur-command-output-state-stderr-chunks output-state)))))
;;       (setf (concur-process-result-stdout result-obj) (if discard-ansi (ansi-color-filter-apply stdout-str) stdout-str))
;;       (setf (concur-process-result-stderr result-obj) stderr-str)))
;;   result-obj)

;; (cl-defun concur--command-internal (command &rest keys)
;;   "Internal implementation of `concur:command`."
;;   (let* ((cmd-list (if (listp command) command (s-split " " command t)))
;;          (exe (car cmd-list))
;;          (implicit-args (cdr cmd-list))
;;          (explicit-args (plist-get keys :args))
;;          (combined-args (append implicit-args (or explicit-args '())))
;;          (die-on-error (plist-get keys :die-on-error t))
;;          (discard-ansi (plist-get keys :discard-ansi t))
;;          (on-stdout (plist-get keys :on-stdout))
;;          (on-stderr (plist-get keys :on-stderr))
;;          (explicit-output-to-file (plist-get keys :output-to-file))
;;          (max-mem (plist-get keys :max-memory-output))
;;          (merge-stderr (plist-get keys :merge-stderr))
;;          (iprocess-keys (concur--filter-plist
;;                          keys
;;                          '(:args :die-on-error :discard-ansi :on-stdout :on-stderr
;;                            :output-to-file :max-memory-output)))
;;          (output-state (make-concur-command-output-state
;;                         :cmd-exe exe
;;                         :explicit-output-to-file explicit-output-to-file
;;                         :max-memory-output-bytes (unless explicit-output-to-file max-mem))))

;;     (unless (and exe (not (s-blank-p exe)))
;;       (error "Invalid command provided to concur:command: %S" command))

;;     ;; Pre-setup files if output-to-file is explicit
;;     (when explicit-output-to-file
;;       (setf (concur-command-output-state-output-spilled-to-file-p output-state) t)
;;       (let* ((base (if (stringp explicit-output-to-file) explicit-output-to-file exe))
;;              (stdout-info (concur--create-temp-file-for-output base "stdout")))
;;         (setf (concur-command-output-state-stdout-file-path output-state) (plist-get stdout-info :path))
;;         (setf (concur-command-output-state-stdout-file-fd output-state) (plist-get stdout-info :fd))
;;         (unless merge-stderr
;;           (let ((stderr-info (concur--create-temp-file-for-output base "stderr")))
;;             (setf (concur-command-output-state-stderr-file-path output-state) (plist-get stderr-info :path))
;;             (setf (concur-command-output-state-stderr-file-fd output-state) (plist-get stderr-info :fd))))))

;;     (let ((proc-promise (apply #'concur:iprocess :command exe :args combined-args
;;                                ;; Force iprocess to always resolve, we handle die-on-error later
;;                                :die-on-error nil
;;                                iprocess-keys)))
;;       (concur:then
;;        proc-promise
;;        ;; --- on-success callback ---
;;        (lambda (result-obj)
;;          (let ((stdout-co (concur-process-result-stdout-coroutine result-obj))
;;                (stderr-co (concur-process-result-stderr-coroutine result-obj)))
;;            ;; Consume coroutines to gather all output
;;            (while (pcase (resume! stdout-co)
;;                     ((list :chunk chunk) (concur--command-handle-chunk chunk output-state 'stdout on-stdout) t)
;;                     (_ nil)))
;;            (when stderr-co
;;              (while (pcase (resume! stderr-co)
;;                       ((list :chunk chunk) (concur--command-handle-chunk chunk output-state 'stderr on-stderr) t)
;;                       (_ nil))))

;;            ;; Finalize result (memory vs file, etc.)
;;            (let* ((final-result (concur--finalize-command-output result-obj output-state discard-ansi)))
;;              (if (and die-on-error (/= (concur-process-result-exit final-result) 0))
;;                  (concur:rejected!
;;                   (make-concur-exec-error-info
;;                    :message (format "Command '%s' failed" exe)
;;                    :exit-code (concur-process-result-exit final-result)
;;                    :stdout (concur-process-result-stdout final-result)
;;                    :stderr (concur-process-result-stderr final-result)
;;                    :cmd exe :args combined-args
;;                    :cwd (plist-get keys :cwd) :env (plist-get keys :env)))
;;                final-result))))
;;        ;; --- on-error callback ---
;;        (lambda (err-info)
;;          (concur--log :error "concur:command failed: %S"
;;                       (if (concur-exec-error-info-p err-info)
;;                           (concur-exec-error-info-message err-info) err-info))
;;          ;; Cleanup files if they were created before the process failed.
;;          (when (concur-command-output-state-output-spilled-to-file-p output-state)
;;            (concur--delete-files-deferred
;;             (list (concur-command-output-state-stdout-file-path output-state)
;;                   (concur-command-output-state-stderr-file-path output-state))))
;;          (concur:rejected! err-info))))))

;; ;;;###autoload
;; (defmacro concur:command (command &rest keys)
;;   "Run COMMAND and return a promise that resolves to its result.
;; This is a high-level wrapper around `concur:iprocess` that intelligently
;; manages process output. It accumulates output in memory by default,
;; but can automatically spill to temporary files if a size threshold
;; is exceeded (`:max-memory-output`) or if explicitly requested
;; (`:output-to-file`).

;; Arguments:
;; - `command` (string or list): The command to run. If a string, it is split
;;   by spaces. E.g., `\"ls -la\"` or `'(\"ls\" \"-la\")`.
;; - `keys` (plist): Options for execution.
;;   - `:args` (list): Additional arguments to append to the command.
;;   - `:die-on-error` (boolean, default t): If t, reject the promise on a
;;     non-zero exit code. If nil, resolve with the failure result struct.
;;   - `:discard-ansi` (boolean, default t): If t, remove ANSI escape codes
;;     from stdout. Only applies when output is captured in memory.
;;   - `:on-stdout` (function): A callback `(lambda (string))` for each stdout
;;     chunk. Fired in addition to internal capture.
;;   - `:on-stderr` (function): A callback `(lambda (string))` for each stderr
;;     chunk. Fired in addition to internal capture.
;;   - `:output-to-file` (boolean or string): If t, stream output to temp
;;     files. If a string, use it as a base name for the files. The resolved
;;     `stdout`/`stderr` fields will be file paths.
;;   - `:max-memory-output` (integer): Max bytes to store in memory before
;;     spilling to a temp file. Ignored if `:output-to-file` is set.
;;   - Other keys (`:cwd`, `:env`, `:stdin`, `:stdin-file`, `:merge-stderr`,
;;     `:cancel-token`, `:timeout`) are passed to `concur:iprocess`.

;; Results:
;; - (`concur-promise`): A promise that resolves to a `concur-process-result`
;;   struct, or rejects with a `concur-exec-error-info` struct."
;;   (declare (indent 1) (debug t))
;;   `(apply #'concur--command-internal ,command (list ,@keys)))

;; ;;;###autoload
;; (defmacro concur:pipe! (&rest command-forms)
;;   "Chain asynchronous commands, piping stdout of one to stdin of the next.
;; Each command is a `concur:command` form, e.g., `(\"ls -l\")` or
;; `'(\"grep\" \".el\" :die-on-error nil)`. Intermediate commands automatically
;; use file-based piping for efficiency.

;; Arguments:
;; - `command-forms` (forms): A sequence of command forms.

;; Results:
;; - (`concur-promise`): A promise that resolves to the `concur-process-result`
;;   of the final command. Note: If the final command's output is a file,
;;   its `cleanup-fn` should be called by the user if cleanup is desired."
;;   (declare (indent 1) (debug t))
;;   (unless command-forms
;;     (error "concur:pipe! requires at least one command form"))
;;   (let ((pipeline-promise (make-symbol "pipeline-promise"))
;;         (last-result (make-symbol "last-result")))
;;     `(let ((,last-result nil))
;;        (->> ,(car command-forms)
;;             (concur:command)
;;             ,@(mapcar
;;                (lambda (form)
;;                  (let* ((cmd (if (listp form) (car form) form))
;;                         (args (if (listp form) (cdr form) nil))
;;                         (is-last (eq form (car (last command-forms)))))
;;                    `(concur:then
;;                      (lambda (,last-result)
;;                        ;; Clean up intermediate file from previous command.
;;                        (when-let ((cleanup (concur-process-result-cleanup-fn ,last-result)))
;;                          (funcall cleanup))
;;                        ;; Run next command.
;;                        (concur:command ,cmd
;;                          :stdin-file (concur-process-result-stdout-file-path ,last-result)
;;                          ;; For intermediate commands, always use file output and don't die on error
;;                          ;; until the final command.
;;                          ,@(unless is-last '(:output-to-file t :die-on-error nil))
;;                          ,@args)))))
;;                (cdr command-forms))))))

;; ;;;###autoload
;; (defmacro concur:define-command! (name arglist docstring command-expr &rest keys)
;;   "Define NAME as a function that runs an async command via `concur:command`.
;; This creates a convenient, reusable wrapper around a common command pattern.
;; The defined function accepts keyword arguments that override the defaults
;; provided in `KEYS`.

;; Arguments:
;; - `name` (symbol): The symbol name for the new function.
;; - `arglist` (list): Argument list for the new function (can be empty).
;; - `docstring` (string): Docstring for the new function.
;; - `command-expr` (form): A form that evaluates to the command string/list.
;; - `keys` (plist): Default keys for `concur:command`."
;;   (declare (indent 1) (debug t))
;;   (let* ((interactive-spec (plist-get keys :interactive))
;;          (default-keys (concur--filter-plist keys '(:interactive)))
;;          (args-sym (make-symbol "args")))
;;     `(defun ,name (,@arglist &rest ,args-sym)
;;        ,docstring
;;        ,@(when interactive-spec `((interactive ,interactive-spec)))
;;        (let ((command ,command-expr))
;;          (apply #'concur:command command
;;                 (append ,args-sym (list ,@default-keys)))))))

;; (provide 'concur-exec)
;; ;;; concur-exec.el ends here