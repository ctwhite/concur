;;; concur-shell.el --- A worker pool for executing shell commands. -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file implements a specialized worker pool, built on top of the
;; `concur-abstract-pool` framework, for efficiently executing shell commands
;; in the background.
;;
;; It provides a default pool instance for convenience, along with a simple
;; macro `concur:shell!` for quick, one-off commands.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'concur-async)
(require 'concur-abstract-pool)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors and Customization

(define-error 'concur-shell-error "A shell-specific error occurred."
  'concur-abstract-pool-error)

(defcustom concur-shell-default-timeout 60
  "Default timeout in seconds for shell commands."
  :type 'integer :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (concur-shell-pool (:include concur-abstract-pool))
  "A pool of persistent shell workers.

Fields:
  shell-program (string): The path to the shell executable that workers
    will use to run commands (e.g., \"/bin/bash\" or \"zsh\")."
  (shell-program "sh" :type string))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker Logic

(defvar-local concur--shell-program nil
  "The shell executable used inside the worker process.")

(defun concur--shell-run-command-process (command context)
  "Start a shell process to execute COMMAND with CONTEXT.

Arguments:
  COMMAND (string): The shell command to execute.
  CONTEXT (plist): A plist containing :cwd and :timeout.

Returns:
  (process): The process object for the running command."
  (let* ((cwd (plist-get context :cwd))
         (output-buffer (generate-new-buffer " *shell-cmd-output*"))
         (proc (start-process "shell-cmd" output-buffer
                              concur--shell-program "-c" command)))
    (when cwd (setf (process-contact proc :cwd) cwd))
    (process-put proc 'output-buffer output-buffer)
    proc))

(defun concur--shell-await-command-result (proc context)
  "Wait for PROC to finish and return its output.

Arguments:
  PROC (process): The process to wait for.
  CONTEXT (plist): A plist containing the :timeout.

Returns:
  (string): The cleaned standard output of the command.

Signals:
  `error`: If the command times out or returns a non-zero exit status."
  (let* ((timeout (or (plist-get context :timeout) concur-shell-default-timeout))
         (output-buffer (process-get proc 'output-buffer))
         (exit-code 0)
         (cleaned-result ""))
    (unwind-protect
        (progn
          (while (accept-process-output proc timeout))
          (when (process-live-p proc)
            (kill-process proc)
            (error "Command timed out after %s seconds" timeout))

          (setq exit-code (process-exit-status proc))
          (setq cleaned-result
                (with-current-buffer output-buffer
                  (let* ((lines (split-string (buffer-string) "\n" t))
                         (filtered
                          (cl-remove-if
                           (lambda (line)
                             (string-match-p "\\`Process .* finished\\'" line))
                           lines)))
                    (string-trim (string-join filtered "\n")))))

          (unless (zerop exit-code)
            (error "Command failed with exit code %d: %s"
                   exit-code cleaned-result)))
      ;; Cleanup
      (when (buffer-live-p output-buffer) (kill-buffer output-buffer)))
    cleaned-result))

(defun concur--shell-task-executor-fn (payload context)
  "The function that executes a shell command inside a worker.
This is the core logic that runs in the background process.

Arguments:
  PAYLOAD (string): The shell command string to execute.
  CONTEXT (plist): Additional data, including :cwd and :timeout.

Returns:
  (string): The standard output of the executed command if successful."
  (let ((proc (concur--shell-run-command-process payload context)))
    (concur--shell-await-command-result proc context)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Pool Factory Helpers

(defun concur--shell-worker-factory-fn (worker shell-program)
  "Create a new Emacs worker process for the shell pool.

Arguments:
  WORKER (concur-abstract-worker): The worker struct to populate.
  SHELL-PROGRAM (string): The shell executable (e.g., \"/bin/bash\").

Returns:
  nil. Populates the process slot of WORKER."
  (let ((worker-script
         `(lambda ()
            (setq-local concur--shell-program ,shell-program)
            (concur--abstract-worker-entry-point
             #'concur--shell-task-executor-fn nil))))
    (setf (concur-abstract-worker-process worker)
          ;; REGRESSION FIX: Explicitly pass the parent's `load-path` to ensure
          ;; the worker can find all required libraries.
          (concur:async-launch worker-script
                               :require '(concur-shell)
                               :load-path load-path))))

(defun concur--shell-ipc-filter-fn (worker chunk pool)
  "Process incoming output chunks from a worker process.
It buffers partial lines and dispatches full lines based on IPC prefixes.

Arguments:
  WORKER (concur-abstract-worker): The worker sending output.
  CHUNK (string): The string of output received.
  POOL (concur-abstract-pool): The parent pool.

Returns:
  nil."
  (let* ((proc (concur-abstract-worker-process worker))
         (buffer (concat (or (process-get proc 'ipc-buffer) "") chunk))
         (start 0)
         end)
    (while (setq end (string-match "\n" buffer start))
      (let* ((line (substring buffer start end))
             (task (concur-abstract-worker-current-task worker)))
        (when (and task (>= (length line) 2))
          (let ((prefix (substring line 0 2))
                (payload (substring line 2)))
            (pcase prefix
              ("R:" (concur--abstract-pool-handle-worker-output
                     worker task `(:type :result :payload ,payload) pool))
              ("E:" (concur--abstract-pool-handle-worker-output
                     worker task `(:type :error :payload ,payload) pool))
              ("M:" (concur--abstract-pool-handle-worker-output
                     worker task `(:type :message :payload ,payload) pool))))))
      (setq start (1+ end)))
    (process-put proc 'ipc-buffer (substring buffer start))))

(defun concur--shell-result-parser-fn (s)
  "Parse a JSON result string from a worker.

Arguments:
  S (string): The raw JSON string `{\"id\":...,\"result\":...}`.

Returns:
  The extracted result value."
  (let ((json-object-type 'plist))
    (plist-get (json-read-from-string s) :result)))

(defun concur--shell-error-parser-fn (s)
  "Parse a JSON error string from a worker.

Arguments:
  S (string): The raw JSON string `{\"id\":...,\"error\":...}`.

Returns:
  (concur-error): The deserialized error object."
  (let ((json-object-type 'plist))
    (concur-deserialize-error (plist-get (json-read-from-string s) :error))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Pool Creation and Management

(defvar *concur-default-shell-pool* nil
  "The global default instance of the shell worker pool.")

(defun concur--shell-pool-get-default ()
  "Return or create the default global shell worker pool.

Returns:
  (concur-shell-pool): The default shell worker pool instance."
  (unless (and *concur-default-shell-pool*
               (concur-abstract-pool-p *concur-default-shell-pool*)
               (not (concur-abstract-pool-shutdown-p *concur-default-shell-pool*)))
    (setq *concur-default-shell-pool* (concur:shell-pool-create)))
  *concur-default-shell-pool*)

(cl-defun concur:shell-pool-create (&key (shell-program "sh") (size 4))
  "Create and initialize a new shell worker pool.

Arguments:
  :shell-program (string): The shell executable (e.g., \"/bin/bash\").
  :size (integer): The number of worker processes in the pool.

Returns:
  (concur-shell-pool): A new, initialized shell worker pool instance."
  (concur-abstract-pool-create
   :name (format "shell-pool[%s]" shell-program)
   :size size
   :worker-factory-fn (lambda (worker _pool)
                        (concur--shell-worker-factory-fn worker shell-program))
   :worker-ipc-filter-fn #'concur--shell-ipc-filter-fn
   :worker-ipc-sentinel-fn #'concur--abstract-pool-handle-worker-death
   :task-serializer-fn (lambda (payload context)
                         (json-encode `(:id nil
                                        :payload ,payload
                                        :context ,context)))
   :result-parser-fn #'concur--shell-result-parser-fn
   :error-parser-fn #'concur--shell-error-parser-fn
   :message-parser-fn #'json-read-from-string))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(cl-defun concur:shell-submit-task (pool command &key cwd timeout)
  "Submit a COMMAND string to the shell POOL for asynchronous execution.

Arguments:
  POOL (concur-shell-pool): The pool to submit the task to.
  COMMAND (string): The shell command string to execute.
  :cwd (string): The working directory for the command.
  :timeout (number): A timeout in seconds for the command.

Returns:
  (concur-promise): A promise that resolves with the command's stdout."
  (concur-abstract-pool-submit-task
   pool command :context `(:cwd ,cwd :timeout ,timeout)))

(defmacro concur:shell! (command-string &rest keys)
  "Run COMMAND-STRING in the default shell pool. A convenient shorthand.

Arguments:
  COMMAND-STRING (string): The shell command to run.
  KEYS (plist): Keyword arguments for `concur:shell-submit-task`,
    such as :cwd or :timeout.

Returns:
  (concur-promise): A promise for the command's result."
  (declare (indent 1))
  `(apply #'concur:shell-submit-task
          (concur--shell-pool-get-default) ,command-string ',keys))

(defun concur:shell-pool-shutdown! (&optional pool)
  "Shut down the shell worker pool.

Arguments:
  POOL (concur-shell-pool): The pool to shut down. If nil, shuts down the
    default global pool.

Returns:
  nil."
  (interactive)
  (let ((p (or pool *concur-default-shell-pool*)))
    (when p (concur-abstract-pool-shutdown! p)))
  (when (eq p *concur-default-shell-pool*)
    (setq *concur-default-shell-pool* nil)))

(provide 'concur-shell)
;;; concur-shell.el ends here