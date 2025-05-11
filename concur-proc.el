;;; concur-proc.el --- Run command-line processes asynchronously -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; Provides `concur-proc`, a utility to launch external command-line processes
;; asynchronously from Emacs, with structured output handling and customizable
;; execution context (e.g., working directory, environment, stdin/stderr control).
;;
;; The callback receives a plist containing:
;;   :cmd     — command name
;;   :args    — list of arguments
;;   :exit    — exit status code
;;   :stdout  — cleaned standard output (optionally stripped of ANSI codes)
;;   :stderr  — captured standard error output
;;
;; ANSI color codes can be removed, stderr can be merged or separated, and
;; callbacks are safely wrapped to prevent errors from hanging Emacs.
;;
;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'concur-util)
(require 'dash)
(require 's)

(defun concur--exec-process-output (cmd args output discard-ansi die-on-error exit-code &optional stderr)
  "Process OUTPUT from an async command.

If DISCARD-ANSI is non-nil, strip ANSI codes using `ansi-color-apply`.
If DIE-ON-ERROR is non-nil and EXIT-CODE is non-zero, signal an error.
Return a plist: (:exit CODE :stdout STRING :stderr STRING)."
  (concur--log! "[concur-exec] Processing output (exit: %d)" exit-code)
  (let* ((safe-output (or output ""))
         (clean-output (if discard-ansi
                           (ansi-color-apply safe-output)
                         safe-output)))
    (when (and die-on-error (not (zerop exit-code)))
      ;; Avoid hard error if inside a sentinel — let the caller decide how to reject
      (let ((msg (if (stringp die-on-error) die-on-error "Command failed")))
        (signal 'error (list (format "%s (exit code: %d)\n\n%s" msg exit-code clean-output)))))
    (list :cmd cmd
          :args args
          :exit exit-code
          :stdout clean-output
          :stderr (or stderr ""))))

;;;###autoload
(cl-defun concur-proc
    (&key command args callback cwd env discard-ansi die-on-error trace
          stdin stderr-buffer-name merge-stderr
          &allow-other-keys)
  "Run COMMAND asynchronously and call CALLBACK with (:exit :stdout :stderr) plist."
  (concur--log! "Running async: %s" (cons command args))
  (let* ((exe command)
         (args args)
         (default-directory (or cwd default-directory))
         (process-environment
          (append (--map (format "%s=%s" (car it) (cdr it)) env)
                  process-environment))
         (stdout-buf (generate-new-buffer "*exec-stdout*"))
         (stderr-buf (unless merge-stderr
                       (generate-new-buffer (or stderr-buffer-name "*exec-stderr*")))))
    (when trace
      (concur--log! "%s:\n  %s"
               (or trace "Running async:")
               (s-join " " (cons exe args))))
    (let ((proc (make-process
                 :name "exec-async-process"
                 :buffer stdout-buf
                 :command (cons exe args)
                 :stderr stderr-buf
                 :noquery t
                 :connection-type 'pipe)))
      (when stdin
        (process-send-string proc stdin)
        (process-send-eof proc))
      ;; Closure around callback and buffers
      (let ((cb callback)
            (out stdout-buf)
            (err stderr-buf))
        (set-process-sentinel
         proc
         (lambda (_proc _event)
           (concur--log! "[concur-exec] Process sentinel: %S" _proc)
           (when (memq (process-status _proc) '(exit signal))
             (let ((stdout nil) (stderr nil) (exit-status nil))
               (condition-case err
                   (setq stdout (when (buffer-live-p out)
                                  (with-current-buffer out (buffer-string))))
                 (error (message "Error reading stdout: %s" err)))
               (condition-case err
                   (setq stderr (when (and err (buffer-live-p err))
                                  (with-current-buffer err (buffer-string))))
                 (error (message "Error reading stderr: %s" err)))
               (condition-case err
                   (progn
                     (when (buffer-live-p out) (kill-buffer out))
                     (when (and err (buffer-live-p err)) (kill-buffer err)))
                 (error (message "Error killing buffers: %s" err)))

               (setq exit-status (process-exit-status _proc))
               (concur--log! "[concur-exec] Processing output (exit: %d)" exit-status)

               ;; Wrap the callback in condition-case to avoid silent hangs
               (condition-case err
                   (funcall cb
                            (concur--exec-process-output
                             exe args stdout discard-ansi die-on-error
                             exit-status stderr))
                 (error
                  (message "[concur-exec] Error in callback: %s"
                           (error-message-string err)))))))))
      proc)))

(provide 'concur-proc)
;;; concur-proc.el ends here