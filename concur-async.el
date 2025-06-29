;;; concur-async.el --- Low-Level Asynchronous Primitives -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides foundational primitives for launching and managing
;; background Emacs Lisp processes. It offers a robust, self-contained
;; replacement for external async libraries.
;;
;; The module provides three main entry points for asynchronous execution:
;;
;; 1. `concur:async-start`: For single-shot background tasks. It launches a
;;    process, computes one result, returns it via a promise, and terminates.
;;
;; 2. `concur:async-stream`: For background tasks that produce a continuous stream
;;    of data. It returns a `concur-stream` that emits items as the worker
;;    produces them. Ideal for search, compilation, or other long-running jobs.
;;
;; 3. `concur:async-launch`: A low-level primitive for creating workers, used
;;    by the functions above and by higher-level abstractions like thread pools.

;;; Code:

(require 'cl-lib)
(require 'cl-extra)                 
(require 's)

(require 'concur-core)
(require 'concur-log)
(require 'concur-stream)            

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom concur-async-emacs-executable (executable-find "emacs")
  "The path to the Emacs executable to use for worker processes.
This allows using alternative Emacs builds (e.g., `emacs-nox` or
a natively-compiled version) for background work."
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(defvar concur-async--tasks (make-hash-table :test 'equal)
  "A global hash table mapping task IDs to their `concur-async-task` structs.
This is used only by the single-shot `concur:async-start` function.")

(cl-defstruct concur-async-task
  "Represents a single-shot task sent to a temporary worker.

Fields:
- `id` (string): The unique ID for this task.
- `promise` (concur-promise): The promise to be settled with the result.
- `process` (process): The OS process running this task."
  id promise process)

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

(defun concur-async-batch-invoke ()
  "The entry-point for a single-shot worker (`concur:async-start`).
It reads one task payload, executes it, sends the response, and exits."
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
                   (require 'cl-extra)
                   (list :id id :error (cl-serialize-error task-err)))))
          (prin1 response (standard-output))
          (princ "\n" (standard-output))
          (finish-output (standard-output))
          (sleep-for 0.1)             ; Ensure output is flushed.
          (kill-emacs 0))
      (error                          ; Fatal error in the worker itself.
       (princ (format "E:[FATAL] %S\n" (format "%S" err)))
       (signal (car err) (cdr err))))))

(defun concur-async-stream-invoke ()
  "The entry-point for a streaming worker (`concur:async-stream`).
It reads a task payload and evaluates the user's form. The form
is then responsible for printing S-expressions to stdout."
  (let ((coding-system-for-write 'utf-8-emacs-unix)
        (print-escape-nonascii t))
    (condition-case err
        (let* ((task-lisp (read))
               (form (plist-get task-lisp :form))
               (vars (plist-get task-lisp :vars)))
          (concur-async--prepare-worker-env task-lisp)
          (eval `(let ,vars ,form) t)) ; User's code streams data.
      (error
       (princ (format "E:[FATAL] %S\n" (format "%S" err)))
       (signal (car err) (cdr err))))))

(defun concur-async--emacs-program-args (entry-function)
  "Return a list of command-line arguments for invoking a child worker.

Arguments:
- `ENTRY-FUNCTION` (string): The name of the function to call after startup.

Returns:
- (list): A list of command-line arguments for `make-process`."
  (list "-Q"                         ; Start with a clean environment.
        "-l" (locate-library "concur-async")
        "-batch"                     ; Run in batch mode.
        "-f" entry-function))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Process Management (Filters & Sentinels)

(defun concur-async--process-filter (proc string)
  "Process filter for single-shot tasks (`concur:async-start`).
It parses the single S-expression response and resolves the promise.

Arguments:
- `PROC` (process): The worker process.
- `STRING` (string): The output received from the process."
  (let ((buffer (process-get proc 'filter-buffer)))
    (unless buffer
      (setq buffer (generate-new-buffer (format "*%s-filter*" (process-name proc))))
      (process-put proc 'filter-buffer buffer))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      (while (ignore-errors (read (current-buffer)))
        (let* ((response (eval (preceding-sexp)))
               (id (plist-get response :id))
               (task (gethash id concur-async--tasks)))
          (when task
            (let ((promise (concur-async-task-promise task)))
              (if-let ((err (plist-get response :error)))
                  (let ((deserialized-err (cl-deserialize-error err)))
                    (concur:reject
                     promise
                     (concur:make-error :type 'concur-async-worker-error
                                        :message (format "Worker error: %s"
                                                         (car deserialized-err))
                                        :data deserialized-err)))
                (concur:resolve promise (plist-get response :result)))
              (remhash id concur-async--tasks)))
          (delete-region (point-min) (point)))))))

(defun concur-async--process-sentinel (proc event)
  "Process sentinel for single-shot tasks (`concur:async-start`).
Handles unexpected termination and rejects the associated promise.

Arguments:
- `PROC` (process): The worker process that died.
- `EVENT` (string): A string describing the termination event."
  (dolist (task (ht-vals concur-async--tasks))
    (when (eq proc (concur-async-task-process task))
      (remhash (concur-async-task-id task) concur-async--tasks)
      (let* ((stderr-buffer (process-get proc 'stderr-buffer))
             (stderr-output (and stderr-buffer (buffer-string stderr-buffer))))
        (concur:reject
         (concur-async-task-promise task)
         (concur:make-error :type 'concur-async-worker-error
                            :message (format "Worker died unexpectedly: %s"
                                             event)
                            :stderr stderr-output))))))

(defun concur-async--stream-filter (proc string stream)
  "Process filter for streaming tasks (`concur:async-stream`).
It parses S-expressions from the worker's output and writes each
one as a chunk to the provided `STREAM`.

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
        (let ((chunk (eval (preceding-sexp))))
          (concur:stream-write stream chunk)
          (delete-region (point-min) (point)))))))

(defun concur-async--stream-sentinel (proc event stream)
  "Process sentinel for streaming tasks (`concur:async-stream`).
It closes the `STREAM` on a clean exit or puts it into an error
state if the worker terminates unexpectedly.

Arguments:
- `PROC` (process): The worker process that died.
- `EVENT` (string): A string describing the termination event.
- `STREAM` (concur-stream): The stream associated with the process."
  (let* ((stderr-buffer (process-get proc 'stderr-buffer))
         (stderr-output (and stderr-buffer (buffer-string stderr-buffer))))
    (if (or (s-contains? "finished" event) (s-contains? "killed" event))
        (concur:stream-close stream)
      (concur:stream-error
       stream
       (concur:make-error :type 'concur-async-worker-error
                          :message (format "Worker process died: %s" event)
                          :stderr stderr-output)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:async-launch (start-func &key name filter sentinel)
  "Launch a subordinate Emacs process. (Low-level)
This is the core primitive for creating workers. It takes a string
naming an entry-point function to be called in the new process.

Arguments:
- `START-FUNC` (string): The name of the function for the worker to execute.
- `:name` (string, optional): A descriptive name for the process.
- `:filter` (function, optional): The process filter for handling stdout.
- `:sentinel` (function, optional): The process sentinel for termination.

Returns:
- (process): The raw process object for the newly started worker."
  (let* ((emacs-path concur-async-emacs-executable)
         (emacs-args (concur-async--emacs-program-args start-func))
         (stderr-buffer (generate-new-buffer
                         (format "*%s-stderr*" (or name "worker")))))
    (unless (and emacs-path (executable-find emacs-path))
      (signal 'concur-async-exec-not-found
              (list (format "Executable not found: %s" emacs-path))))
    (let ((proc (make-process :name (or name "concur-worker")
                              :command (cons emacs-path emacs-args)
                              :connection-type 'pipe
                              :noquery t
                              :coding 'utf-8-emacs-unix
                              :stderr stderr-buffer
                              :filter filter
                              :sentinel sentinel)))
      (process-put proc 'stderr-buffer stderr-buffer)
      proc)))

;;;###autoload
(cl-defun concur:async-start (form &key vars cancel-token load-path require)
  "Execute FORM in a subordinate Emacs process, returning a promise.
This function is for a single-shot task. For high-throughput or
streaming work, use `concur-pool.el` or `concur:async-stream`.

Arguments:
- `FORM` (form): The Lisp form to execute in the background.
- `:vars` (alist, optional): An alist of `(symbol . value)` pairs to be
  `let`-bound around the `FORM` in the worker.
- `:cancel-token` (concur-cancel-token, optional): A token to cancel the process.
- `:load-path` (list of strings, optional): Paths to add to `load-path`.
- `:require` (list of symbols, optional): Features to `require`.

Returns:
- (concur-promise): A promise that resolves with the result of `FORM`."
  (let* ((id (format "async-task-%s" (make-temp-name "")))
         (proc (concur:async-launch "concur-async-batch-invoke"
                                    :name (format "concur-worker-batch-%s" id)
                                    :filter #'concur-async--process-filter
                                    :sentinel #'concur-async--process-sentinel))
         (promise (concur:make-promise :cancel-token cancel-token
                                       :proc proc)))
    (puthash id (make-concur-async-task :id id :promise promise :process proc)
             concur-async--tasks)
    ;; Setup cancellation.
    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (when (process-live-p proc)
           (delete-process proc)
           (remhash id concur-async--tasks)
           (concur:reject
            promise
            (concur:make-error :type 'concur-cancel-error
                               :message "Async task cancelled."))))))
    ;; Send payload to the worker.
    (let ((payload `(:id ,id :form ,form :vars ,vars
                         :load-path ,load-path :require ,require)))
      (process-send-string proc (format "%s\n" (prin1-to-string payload))))
    promise))

;;;###autoload
(cl-defun concur:async-stream (form &key vars cancel-token load-path require)
  "Execute FORM in a subordinate process, returning a stream of its output.
Each S-expression `prin1`'d to standard output by the worker becomes
an item in the returned stream.

Arguments:
- `FORM` (form): The Lisp form to execute in the background.
- `:vars` (alist, optional): An alist of `(symbol . value)` pairs to be
  `let`-bound around the `FORM` in the worker.
- `:cancel-token` (concur-cancel-token, optional): A token to cancel the process.
- `:load-path` (list of strings, optional): Paths to add to `load-path`.
- `:require` (list of symbols, optional): Features to `require`.

Returns:
- (concur-stream): A stream that emits items from the worker."
  (let* ((dest-stream (concur:stream-create))
         (proc-name (format "concur-worker-stream-%s"
                            (concur-stream-name dest-stream)))
         (proc (concur:async-launch
                "concur-async-stream-invoke"
                :name proc-name
                :filter (lambda (p s) (concur-async--stream-filter p s dest-stream))
                :sentinel (lambda (p e) (concur-async--stream-sentinel p e dest-stream)))))
    ;; Setup cancellation.
    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token (lambda () (when (process-live-p proc) (delete-process proc)))))
    ;; Send payload to the worker.
    (let ((payload `(:form ,form :vars ,vars
                     :load-path ,load-path :require ,require)))
      (process-send-string proc (format "%s\n" (prin1-to-string payload))))
    dest-stream))

(provide 'concur-async)
;;; concur-async.el ends here