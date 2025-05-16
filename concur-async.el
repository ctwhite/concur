;;; concur-async.el --- Cooperative async primitives for Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides cooperative asynchronous primitives for managing async tasks
;; within Emacs, using promises and futures. The functions in this module integrate
;; with the concur scheduler, enabling async tasks to yield control and work cooperatively
;; without blocking the Emacs event loop. The primary focus is on async task management,
;; result resolution, and efficient scheduling.
;;
;; Key components:
;; - `concur-await!`: A macro to await the result of a task (promise or future).
;; - `concur-async-run`: A function to run tasks asynchronously, supporting different execution modes.
;; - `concur-promise-resolve` / `concur-promise-reject`: Functions for resolving and rejecting promises.
;; - `concur-future`: Helper functions for managing futures, which represent values that
;;   may not yet be available but will eventually be computed.
;; - `concur-primitives`: Contains low-level scheduling and task management primitives.
;;
;; The module supports cooperative multitasking, meaning tasks can yield control back to the
;; scheduler at well-defined points, allowing other tasks to run in between. This is useful
;; for long-running tasks that need to run without blocking the UI or other operations.
;; It provides hooks to track the progress of async tasks and to handle timeouts.
;;
;; Usage example:
;; (concur-await! (concur-task! (some-task)) :timeout 2.5)
;; This will await the result of `some-task`, with a 2.5-second timeout. If the task is not
;; completed within the timeout, an error will be triggered.
;;
;;; Code:

(require 'async)
(require 'cl-lib)
(require 'concur-promise)
(require 'concur-future)
(require 'concur-primitives)
(require 'scribe)

(defcustom concur-async-enable-tracing t
  "Whether to record and log async stack traces for `concur-async!` tasks."
  :type 'boolean
  :group 'concur)

(defcustom concur-task-await-poll-interval 0.01
  "Polling interval in seconds used by `concur-await!` when blocking outside the scheduler.
A small value (e.g. 0.005 = 5ms) gives more responsiveness, but may use more CPU."
  :type 'number
  :group 'concur)

(defvar concur-async-hooks nil
  "Hook run during `concur-async!`.

Each function receives (EVENT LABEL FUTURE), where EVENT is one of:
  :started     — before task is scheduled
  :succeeded   — when resolved successfully
  :error       — if an error is caught during async execution
  :cancelled   — if the task is cancelled before completion")

(defvar concur-await-hooks nil
  "Hook run for await lifecycle events.

Each hook function receives:
  (EVENT LABEL TASK &optional ERR)

Where:
  - EVENT is one of :started, :yield, :timeout, :succeeded
  - LABEL is a string identifier for this await instance
  - TASK is the original awaitable (usually a concur-future or concur-promise)
  - ERR is only passed for error-related events such as :timeout.")

(defvar concur--active-threads (ht)
  "Hash table tracking active threads keyed by thread object.")

(defvar-local concur-async--stack nil
  "Dynamic stack of async task labels used for instrumentation and tracing.")

(defun concur-async--push-stack-frame (label)
  "Push LABEL onto the async task stack."
  (push label concur-async--stack))

(defun concur-async--label (fn)
  "Generate a human-readable label for an async task."
  (let ((s (prin1-to-string fn)))
    (if (> (length s) 40)
        (concat (substring s 0 37) "...")
      s)))
      
(defun concur-async--format-async-trace ()
  "Return a formatted trace of the current async stack."
  (mapconcat (lambda (frame)
               (format "↳ %s" frame))
             (reverse concur-async--stack)
             "\n"))

(defun concur-async--log-trace (label)
  "Log the current async stack trace for LABEL."
  (log! :trace "[%s] Async trace:\n%s" label (concur-async--format-async-trace)))

(defun concur-async--maybe-log-trace (label)
  "Log the async stack trace for LABEL if tracing is enabled."
  (when concur-async-enable-tracing
    (concur-async--log-trace label)))

(defun concur-async--run-hooks (event label future &optional err)
  "Run `concur-async-hooks` for EVENT, LABEL, and FUTURE.
ERR is included for :failed events."
  (log! "[%s] Running async hooks: %s" label event)
  (run-hook-with-args 'concur-async-hooks event label future err))

(defun concur-await--run-hooks (event label task &optional err)
  "Run `concur-await-hooks` for EVENT, LABEL, and TASK (a future or promise).
ERR is only passed for error-related events like :timeout."
  (log! "[%s] Running await hooks: %s" label event)
  (run-hook-with-args 'concur-await-hooks event label task err))

(defun concur-async--thread-run-future (future &optional name cancel-token)
  "Run FUTURE in a background thread. Optionally name the task and associate a CANCEL-TOKEN.

This function:
- Creates a named thread to force the resolution of FUTURE.
- Tracks the thread in `concur--active-threads`.
- Registers cancellation cleanup with CANCEL-TOKEN (if provided).
- Triggers appropriate lifecycle hooks: `:start`, `:done`, `:error`, or `:cancel`."
  (log! "Spawning thread for future %s." future)
  (let ((label (format "thread[%s]" (or name "<unnamed>"))))
    ;; Skip execution if cancel token is already inactive
    (if (and cancel-token (not (concur-cancel-token-active? cancel-token)))
        (progn
          (log! :level 'warn "[%s] Not started: token %s already canceled"
                label (concur-cancel-token-name cancel-token))
          (concur-async--run-hooks :cancelled label future)
          nil)

      ;; Otherwise, create and start the thread
      (let* ((thread
              (make-thread
               (lambda ()
                 ;; Signal start
                 (concur-async--run-hooks :started label future)

                 ;; Attempt to force the future, catch errors
                 (condition-case err
                     (progn
                       (concur-future-force future)

                       ;; Schedule completion cleanup on main thread
                       (run-at-time
                        0 nil
                        (lambda ()
                          (ht-remove! concur--active-threads thread)
                          (log! :info "[%s] Completed." label)
                          (concur-async--run-hooks :succeeded label future))))
                   (error
                    ;; Schedule error handling on main thread
                    (run-at-time
                     0 nil
                     (lambda ()
                       (ht-remove! concur--active-threads thread)
                       (log! :error "[%s] Failed: %s" label err)
                       (concur-async--run-hooks :error label future err))))))))
             ;; Thread metadata entry for tracking
             (entry `(:thread ,thread
                      :future ,future
                      :name ,name
                      :cancel-token ,cancel-token)))

        ;; Register thread in global active-thread map
        (ht-set! concur--active-threads thread entry)

        ;; Register cancellation observer if token is provided
        (when cancel-token
          (concur-cancel-token-on-cancel
           cancel-token
           (lambda ()
             (when (ht-contains? concur--active-threads thread)
               (ht-remove! concur--active-threads thread)
               (log! :warn "[%s] Cancelled by token %s"
                     label (concur-cancel-token-name cancel-token))
               (concur-async--run-hooks :cancelled label future)))))

        ;; Log creation
        (log! :info "[%s] Thread started." label)
        thread))))

;;;###autoload
(defun concur-async! (fn &optional mode)
  "Run FN asynchronously according to MODE and return a `concur-promise`.

FN should be a zero-arg function (thunk) to execute.

MODE determines how the function is scheduled:
- nil or 'async: run in a background Emacs process via `async-start`.
- 'deferred: schedule immediately using `run-at-time 0`.
- number: delay execution by that many seconds using `run-at-time`.
- 'thread: spawn a native thread via `make-thread`, wrapping FN in a future.

If MODE is 'thread, the TASK argument is optional. If supplied, it is passed to
`concur-task-run-thread`. Otherwise, the thread will run FN directly via
`concur-async-thread-run-future`.

Hooks:
- `concur-async-started-hook`
- `concur-async-succeeded-hook`
- `concur-async-failed-hook`"
  (log! "Running async task: %s (mode: %s)" fn mode)
  (let* ((label (concur-async--label fn))
         (future (concur-future-new fn))
         (promise (concur-future-promise future))
         ;; Push label onto the dynamic async stack
         (concur-async--stack (cons label concur-async--stack)))

    (cl-labels
        ((on-success ()
           (log! "Task succeeded: %s" label)
           (concur-async--maybe-log-trace label)
           (concur-async--run-hooks :succeeded label future)
           (concur-promise-resolve promise (concur-future-result future)))

         (on-error (err)
           (log! "Task failed: %s (%s)" label err :level 'error)
           (concur-async--maybe-log-trace label)
           (concur-async--run-hooks :failed label future err)
           (concur-promise-reject promise err)))

      ;; Run the started hook before scheduling
      (log! "Starting async task: %s (mode: %s)" label mode)
      (concur-async--run-hooks :started label future)

      ;; Dispatch based on mode
      (pcase mode
        ;; Immediate/deferred execution
        ((or 'deferred t)
         (log! "Scheduling deferred task via `run-at-time 0`.")
         (run-at-time 0 nil
                      (lambda ()
                        (condition-case err
                            (progn
                              (log! "Deferred task started: %s" label)
                              (concur-future-force future)
                              (on-success))
                          (error (on-error err))))))

        ;; Delayed execution (seconds)
        ((pred numberp)
         (log! "Scheduling delayed task (%ss) via `run-at-time`." mode)
         (run-at-time mode nil
                      (lambda ()
                        (condition-case err
                            (progn
                              (log! "Delayed task started after %s seconds: %s" mode label)
                              (concur-future-force future)
                              (on-success))
                          (error (on-error err))))))

        ;; Background async process
        ('async
         (log! "Scheduling async task via `async-start`.")
         (async-start
          `(lambda ()
             (require 'scribe)
             (require 'concur-future)
             (require 'concur-promise)
             (condition-case err
                 (progn
                   (log! "Async task started.")
                   (concur-future-force ,future))
               (error err)))
          (lambda (result)
            (if (concur-async--error? result)
                (on-error result)
              (on-success)))))

        ;; Native thread
        ('thread
         (log! "Scheduling thread-backed task.")
         (run-at-time 0 nil
                      (lambda ()
                        (concur-async--thread-run-future future))))

        ;; Unknown mode
        (_
         (let ((err (format "Unknown async run mode: %S" mode)))
           (on-error (error err))))))

    promise))

;;;###autoload
(defmacro concur-await! (form &rest args)
  "Await the result of FORM, which must return a concur-future or concur-promise.

This macro blocks execution until the future or promise returned by FORM is resolved,
or a timeout (in seconds) elapses.

Supported keyword arguments:
  :timeout — Maximum time (in seconds) to wait before signaling `concur-timeout`.

This macro integrates with the `concur` scheduler. If inside a running scheduler,
it yields and re-enqueues the awaiting task cooperatively. Outside the scheduler,
it polls using `sleep-for`.

Lifecycle hook events:
  - `concur-await-hooks` is run with events:
    :start   — when awaiting begins
    :yield   — each yield or polling iteration
    :timeout — when the await times out
    :done    — when the await completes

Example usage:
  (concur-await! (concur-task! (some-async-call)) :timeout 2.5)"
  (declare (indent defun) (debug (form &rest (sexp args))))
  (let ((task    (gensym "task"))
        (promise (gensym "promise"))
        (timeout (gensym "timeout"))
        (start   (gensym "start"))
        (label   (gensym "label")))
    `(let* ((,task ,form)
            (,timeout (plist-get (list ,@args) :timeout))
            (,start (and ,timeout (float-time)))
            (,label
             (format "await[%s]"
                     (or (and (symbolp ',form) (symbol-name ',form))
                         (let ((s (prin1-to-string ',form)))
                           (if (> (length s) 40)
                               (concat (substring s 0 37) "...")
                             s)))))
            (,promise
             (cond
              ((concur-future-p ,task)
               (log! :trace "[%s] Normalizing future → promise" ,label)
               (concur-future-force ,task)
               (concur-future-promise ,task))
              ((concur-promise-p ,task)
               ,task)
              (t (error "[%s] Invalid awaitable: %S" ,label ,task)))))

       (concur-async--push-stack-frame ,label)
       (concur-await--run-hooks :started ,label ,task)

       (log! :trace "[%s] Awaiting%s"
             ,label (if ,timeout (format " (timeout: %.2fs)" ,timeout) ""))

       ;; Scheduler mode
       (if concur-scheduler--running
           (progn
            (log! "[%s] Awaiting inside scheduler..." ,label)
            (cl-labels
                ((self ()
                    (cond
                    ((and ,timeout (> (- (float-time) ,start) ,timeout))
                      (log! :error "[%s] Timeout after %.2fs (in scheduler)"
                            ,label ,timeout)
                      (concur-await--run-hooks :timeout ,label ,task)
                      (concur-async--log-trace ,label)
                      (signal 'concur-timeout (list ,task)))
                    ((not (concur-promise-resolved? ,promise))
                      (concur-await--run-hooks :yield ,label ,task)
                      (log! :trace "[%s] Yielding control..." ,label)
                      (concur-scheduler-enqueue-task #'self)))))

              ;; Cooperative blocking
              (concur-block-until
                (lambda ()
                  (or (concur-promise-resolved? ,promise)
                      (and ,timeout
                          (> (- (float-time) ,start) ,timeout))))
                #'self)))

          (progn
            ;; Polling mode (outside scheduler)
            (log! "[%s] Awaiting outside scheduler..." ,label)
            (while (and (not (concur-promise-resolved? ,promise))
                        (or (not ,timeout)
                            (< (- (float-time) ,start) ,timeout)))
              (concur-await--run-hooks :yield ,label ,task)
              (sleep-for concur-task-await-poll-interval))))

       ;; Final timeout check
       (unless (concur-promise-resolved? ,promise)
         (log! :error "[%s] Timeout after %.2fs" ,label ,timeout)
         (concur-await--run-hooks :timeout ,label ,task)
         (concur-async--log-trace ,label)
         (signal 'concur-timeout (list ,task)))

       ;; Finalization
       (concur-await--run-hooks :succeeded ,label ,task)
       (log! :trace "[%s] Promise resolved — extracting result" ,label)
       (concur-promise-await ,promise ,timeout))))

(defun concur-async--error? (value)
  "Return non-nil if VALUE is an `error` object.

This checks whether VALUE is a list of the form (error SYMBOL &rest DATA),
as returned by `condition-case` when catching errors."
  (and (consp value)
       (eq (car value) 'error)
       (symbolp (cadr value))))

(defun concur-async-list-active-threads ()
  "Log all active concur threads and associated tasks."
  (ht-map (lambda (thread task)
            (message "Thread: %s — Task: %s (created %s)"
                     thread
                     (or (concur-task-name task) "<unnamed>")
                     (concur-task-created-at task)))
          concur--active-threads))

(provide 'concur-async)
;;; concur-async.el ends here