;;; concur-async.el --- Low-Level Asynchronous Primitives -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides foundational primitives for launching and managing
;; background Emacs Lisp processes. It offers a robust, self-contained
;; replacement for external async libraries.
;;
;; The module provides two main entry points for asynchronous execution:
;;
;; 1. `concur:async-start`: For single-shot background tasks. It launches a
;;    process, computes one result, returns it via a promise, and terminates.
;;
;; 2. `concur:async-stream`: For background tasks that produce a continuous
;;    stream of data. It returns a `concur-stream` that emits items as the
;;    worker produces them.

;;; Code:

(require 'cl-lib)
(require 'cl-extra)

(require 'concur-core)
(require 'concur-log)
(require 'concur-stream)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom concur-async-emacs-executable (executable-find "emacs")
  "The path to the Emacs executable to use for worker processes."
  :type 'string
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-async-error
  "A generic error during an asynchronous operation." 'concur-error)

(define-error 'concur-async-worker-error
  "An error occurred within a background worker process." 'concur-async-error)

(define-error 'concur-async-exec-not-found
  "The 'emacs' executable could not be found." 'concur-async-error)

(define-error 'concur-async-timeout
  "An asynchronous worker process timed out." 'concur-async-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(defvar concur-async--tasks (make-hash-table :test 'equal)
  "Global map from task IDs to `concur-async-task` structs.
Used only by `concur:async-start`.")

(cl-defstruct concur-async-task
  "Represents a single-shot task sent to a temporary worker.

Fields:
- `id` (string): The unique ID for this task.
- `promise` (concur-promise): The promise to be settled with the result.
- `process` (process): The OS process running this task.
- `timeout-timer` (timer): An optional timer for process timeouts.
- `task-form` (form): The original Lisp form executed by the worker.
- `task-vars` (alist): Variables bound during worker execution."
  id promise process
  (timeout-timer nil :type (or null timer))
  (task-form nil)
  (task-vars nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Worker Entry Points

(defun concur-async--prepare-worker-env (task-lisp)
  "Configure a worker's environment from a task payload.
This function, called inside the worker, sets up the `load-path`
and `require`s specified by the parent process.

Arguments:
- `TASK-LISP` (plist): The payload sent from the parent."
  (let ((load-path (plist-get task-lisp :load-path))
        (features (plist-get task-lisp :require)))
    (dolist (path load-path) (add-to-list 'load-path path))
    (dolist (feature features) (require feature))))

(defun concur-async--handle-fatal-worker-error (err)
  "Report a fatal, unexpected error from within a worker process.

Arguments:
- `ERR` (error): The error condition to report."
  (let ((fatal-error
         (concur:make-error
          :type 'concur-async-worker-error
          :message "Fatal error during worker initialization."
          :cause err)))
    ;; Attempt to send a structured error back to the parent.
    (princ (prin1-to-string
            `(:error ,(concur:serialize-error fatal-error))))
    (finish-output (standard-output))
    (kill-emacs 1)))

(defun concur-async-batch-invoke ()
  "Entry-point for a single-shot worker (`concur:async-start`).
Reads one task payload, executes it, sends the response, and exits."
  (let ((coding-system-for-write 'utf-8-emacs-unix)
        (print-escape-nonascii t))
    (condition-case err
        (let* ((task-lisp (read))
               (id (plist-get task-lisp :id))
               (form (plist-get task-lisp :form))
               (vars (plist-get task-lisp :vars))
               (response nil))
          (concur-async--prepare-worker-env task-lisp)
          (setq response
                (condition-case task-err
                    (list :id id :result (eval `(let ,vars ,form) t))
                  (error
                   (list :id id
                         :error (concur:serialize-error
                                 (concur:make-error
                                  :type 'concur-async-worker-error
                                  :cause task-err
                                  :cmd (format "%S" form)
                                  :args (format "%S" vars)))))))
          (prin1 response (standard-output))
          (kill-emacs 0))
      (error (concur-async--handle-fatal-worker-error err)))))

(defun concur-async-stream-invoke ()
  "Entry-point for a streaming worker (`concur:async-stream`).
Reads a task payload and evaluates the user's form. The form is
then responsible for printing S-expressions to stdout."
  (let ((coding-system-for-write 'utf-8-emacs-unix)
        (print-escape-nonascii t))
    (condition-case err
        (let* ((task-lisp (read))
               (form (plist-get task-lisp :form))
               (vars (plist-get task-lisp :vars)))
          (concur-async--prepare-worker-env task-lisp)
          (eval `(let ,vars ,form) t)) ; User's code streams data.
      (error (concur-async--handle-fatal-worker-error err)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Process Management

(defun concur-async--reject-with-context (promise err-obj task)
  "Reject a task's `PROMISE`, enhancing the `ERR-OBJ` with context from `TASK`.

Arguments:
- `PROMISE` (concur-promise): The promise to reject.
- `ERR-OBJ` (concur-error): The error to report.
- `TASK` (concur-async-task): The task that failed."
  (when (concur-error-p err-obj)
    (unless (concur-error-cmd err-obj)
      (setf (concur-error-cmd err-obj)
            (format "%S" (concur-async-task-task-form task))))
    (unless (concur-error-args err-obj)
      (setf (concur-error-args err-obj)
            (format "%S" (concur-async-task-task-vars task)))))
  (concur:reject promise err-obj))

(defun concur-async--process-filter (proc string)
  "Process filter for single-shot tasks (`concur:async-start`).
It parses the single S-expression response and resolves the promise.

Arguments:
- `PROC` (process): The worker process.
- `STRING` (string): The output received from the process."
  (let ((buffer (process-get proc 'filter-buffer)))
    (unless buffer
      (setq buffer (generate-new-buffer
                    (format "*%s-filter*" (process-name proc))))
      (process-put proc 'filter-buffer buffer))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      ;; A single-shot worker sends exactly one response.
      (when (ignore-errors (read (current-buffer)))
        ;; `elisp--preceding-sexp` returns (SEXPR . START-POS).
        (let* ((response (car (elisp--preceding-sexp)))
               (id (plist-get response :id))
               (task (gethash id concur-async--tasks)))
          (when task
            (when-let (timer (concur-async-task-timeout-timer task))
              (cancel-timer timer))
            (if-let ((err (plist-get response :error)))
                (concur-async--reject-with-context
                 (concur-async-task-promise task)
                 (concur:deserialize-error err)
                 task)
              (concur:resolve (concur-async-task-promise task)
                              (plist-get response :result)))
            (remhash id concur-async--tasks)
            (kill-buffer (current-buffer))))))))

(defun concur-async--process-sentinel (proc event)
  "Process sentinel for single-shot tasks (`concur:async-start`).
Handles unexpected termination and rejects the associated promise.

Arguments:
- `PROC` (process): The worker process that died.
- `EVENT` (string): A string describing the termination event."
  (dolist (task (hash-table-values concur-async--tasks))
    (when (eq proc (concur-async-task-process task))
      (when-let (timer (concur-async-task-timeout-timer task))
        (cancel-timer timer))
      (remhash (concur-async-task-id task) concur-async--tasks)
      (let* ((stderr-buffer (process-get proc 'stderr-buffer))
             (stderr (and stderr-buffer (with-current-buffer stderr-buffer
                                           (buffer-string)))))
        (concur-async--reject-with-context
         (concur-async-task-promise task)
         (concur:make-error :type 'concur-async-worker-error
                            :message (format "Worker died unexpectedly: %s" event)
                            :stderr stderr)
         task)))))

(defun concur-async--stream-filter (proc string stream)
  "Process filter for streaming tasks (`concur:async-stream`).
Parses S-expressions from output and writes them to `STREAM`.

Arguments:
- `PROC` (process): The worker process.
- `STRING` (string): The output received from the process.
- `STREAM` (concur-stream): The stream to write data chunks to."
  (let ((buffer (process-get proc 'filter-buffer)))
    (unless buffer
      (setq buffer (generate-new-buffer
                    (format "*%s-stream-filter*" (process-name proc))))
      (process-put proc 'filter-buffer buffer))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      (while (ignore-errors (read (current-buffer)))
        (let ((chunk (car (elisp--preceding-sexp))))
          (if (and (consp chunk) (eq (car chunk) :error))
              (concur:stream-error stream (concur:deserialize-error (cadr chunk)))
            (concur:stream-write stream chunk)))
        (delete-region (point-min) (point))))))

(defun concur-async--stream-sentinel (proc event stream task-form task-vars)
  "Process sentinel for streaming tasks (`concur:async-stream`).
Closes the stream on clean exit or errors it on unexpected termination.

Arguments:
- `PROC` (process): The worker process that died.
- `EVENT` (string): A string describing the termination event.
- `STREAM` (concur-stream): The stream associated with the process.
- `TASK-FORM` (form): The original Lisp form executed by the worker.
- `TASK-VARS` (alist): Variables bound during worker execution."
  (when-let (timer (process-get proc 'concur-async-timeout-timer))
    (cancel-timer timer))
  (let* ((stderr-buffer (process-get proc 'stderr-buffer))
         (stderr (and stderr-buffer (with-current-buffer stderr-buffer
                                       (buffer-string)))))
    (if (or (string-match-p "\\(finished\\|killed\\)" event))
        (concur:stream-close stream)
      (concur:stream-error
       stream
       (concur:make-error :type 'concur-async-worker-error
                          :message (format "Worker process died: %s" event)
                          :stderr stderr
                          :cmd (format "%S" task-form)
                          :args (format "%S" task-vars))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(cl-defun concur:async-launch (start-func &key name filter sentinel emacs-path
                                           (load-path '()) (require '()) env)
  "Launch a subordinate Emacs process. (Low-level primitive).

Arguments:
- `START-FUNC` (list): The lambda expression to `funcall` on startup.
- `:NAME` (string): Optional name for the subprocess.
- `:FILTER` (function): Optional process filter function.
- `:SENTINEL` (function): Optional sentinel for process exit handling.
- `:EMACS-PATH` (string): Path to the Emacs executable to use.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path` via `-L`.
- `:REQUIRE` (list): A list of features to `require` via the `-l` flag.
- `:ENV` (alist): Environment variables for the worker `(\"KEY\" . \"VAL\")`.

Returns:
- `(process)`: The newly created Emacs worker process."
  (let* ((exec (or emacs-path concur-async-emacs-executable))
         (proc-name (or name "concur-worker")))
    (unless (and exec (executable-find exec))
      (signal 'concur-async-exec-not-found (list exec)))

    ;; Combine paths from the argument and the parent process's global load-path.
    ;; The `load-path` argument shadows the global, so we use `symbol-value`.
    (let* ((all-paths (cl-delete-duplicates
                       (append load-path (symbol-value 'load-path))
                       :test #'string-equal))
           (load-path-args
            (cl-loop for path in all-paths
                     when (stringp path)
                     collect "-L" collect path))
           (require-args
            (cl-loop for feat in require
                     when (symbolp feat)
                     collect "-l" collect (symbol-name feat)))
           (command
            (append (list exec "-Q" "-batch")
                    load-path-args
                    require-args
                    (list "--eval" (format "(funcall %S)" start-func))))
           (stderr-buffer (generate-new-buffer (format "*%s-stderr*" proc-name))))
      (let ((proc (make-process
                   :name proc-name
                   :command command
                   :connection-type 'pipe
                   :noquery t
                   :coding 'utf-8-emacs-unix
                   :stderr stderr-buffer
                   :filter filter
                   :sentinel sentinel
                   :environment (append (--map (format "%s=%s" (car it) (cdr it)) env)
                                        process-environment))))
        (process-put proc 'stderr-buffer stderr-buffer)
        proc))))

(cl-defun concur:async-start (form &key vars cancel-token load-path require
                                    timeout env)
  "Execute `FORM` in a subordinate Emacs process, returning a promise.
This is for a single-shot task. For streaming or high-throughput
work, use `concur:async-stream` or a worker pool.

Arguments:
- `FORM` (form): The Lisp form to execute in the background.
- `:VARS` (alist): An alist of `(symbol . value)` pairs to `let`-bind around `FORM`.
- `:CANCEL-TOKEN` (concur-cancel-token): A token to cancel the process.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path`.
- `:REQUIRE` (list): Features to `require` in the worker.
- `:TIMEOUT` (number): Seconds to wait before killing the process and rejecting.
- `:ENV` (alist): Environment variables for the worker `(\"KEY\" . \"VAL\")`.

Returns:
- `(concur-promise)`: A promise that resolves with the result of `FORM`."
  (let* ((id (format "async-task-%s" (make-temp-name "")))
         (proc (concur:async-launch 'concur-async-batch-invoke
                                    :name (format "concur-worker-batch-%s" id)
                                    :filter #'concur-async--process-filter
                                    :sentinel #'concur-async--process-sentinel
                                    :require '(concur-async)
                                    :env env))
         (promise (concur:make-promise :cancel-token cancel-token :proc proc))
         (task (make-concur-async-task :id id :promise promise :process proc
                                       :task-form form :task-vars vars)))
    (puthash id task concur-async--tasks)

    (when timeout
      (setf (concur-async-task-timeout-timer task)
            (run-at-time
             timeout nil
             (lambda ()
               (concur-log :warn nil "Async task %S timed out." id)
               (when (process-live-p proc) (delete-process proc))
               (concur-async--reject-with-context
                promise (concur:make-error :type 'concur-async-timeout) task)))))

    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (concur-log :info nil "Cancellation requested for async task %S." id)
         (when (process-live-p proc) (delete-process proc))
         (concur-async--reject-with-context
          promise (concur:make-error :type 'concur-cancel-error) task))))

    (let ((payload `(:id ,id :form ,form :vars ,vars
                         :load-path ,load-path :require ,require)))
      (process-send-string proc (prin1-to-string payload)))
    promise))

(cl-defun concur:async-stream (form &key vars cancel-token load-path require
                                     timeout env)
  "Execute `FORM` in a subordinate process, returning a stream of its output.
Each S-expression `prin1`'d to stdout by the worker becomes an item
in the returned stream.

Arguments:
- `FORM` (form): The Lisp form to execute in the background.
- `:VARS` (alist): An alist of `(symbol . value)` pairs to `let`-bind around `FORM`.
- `:CANCEL-TOKEN` (concur-cancel-token): A token to cancel the process.
- `:LOAD-PATH` (list): Paths to add to the worker's `load-path`.
- `:REQUIRE` (list): Features to `require` in the worker.
- `:TIMEOUT` (number): Seconds to wait before killing the process and erroring.
- `:ENV` (alist): Environment variables for the worker `(\"KEY\" . \"VAL\")`.

Returns:
- `(concur-stream)`: A stream that emits items from the worker."
  (let* ((stream (concur:stream-create))
         (proc-name (format "concur-worker-stream-%s" (concur-stream-name stream)))
         (proc (concur:async-launch
                'concur-async-stream-invoke
                :name proc-name
                :filter (lambda (p s) (concur-async--stream-filter p s stream))
                :sentinel (lambda (p e)
                            (concur-async--stream-sentinel p e stream form vars))
                :require '(concur-async)
                :env env)))

    (when timeout
      (process-put
       proc 'concur-async-timeout-timer
       (run-at-time
        timeout nil
        (lambda ()
          (concur-log :warn nil "Async stream %S timed out."
                       (concur-stream-name stream))
          (when (process-live-p proc) (delete-process proc))
          (concur:stream-error
           stream (concur:make-error
                   :type 'concur-async-timeout
                   :cmd (format "%S" form)
                   :args (format "%S" vars)))))))

    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token (lambda () (when (process-live-p proc)
                                 (delete-process proc)))))

    (let ((payload `(:form ,form :vars ,vars
                           :load-path ,load-path :require ,require)))
      (process-send-string proc (prin1-to-string payload)))
    stream))

(provide 'concur-async)
;;; concur-async.el ends here