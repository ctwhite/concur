;;; concur-task!.el --- Cooperative task scheduling and management for Emacs -*- lexical-binding: t; -*-
;;
;; Commentary:
;;
;; This file provides functions and macros to define and manage asynchronous tasks
;; within the Concur framework. It integrates with cooperative multitasking to run
;; tasks asynchronously using Emacs' `async` package and the custom `concur-future`
;; and `concur-promise` abstractions. Tasks are managed within a cooperative scheduler
;; that yields control to other tasks periodically, allowing for efficient multitasking.
;;
;; Key features include:
;; - Task scheduling using `concur-task!` macro.
;; - Cooperative task management with support for yielding and timeouts.
;; - Integration with the Concur scheduler for managing task execution.
;; - Tracking and debugging of asynchronous tasks through logging and hooks.
;;
;; The framework supports different task execution modes and can be used both inside
;; and outside the scheduler to handle asynchronous operations efficiently.
;;
;;; Code:

(require 'cl-lib)
(require 'concur-async)
(require 'concur-future)
(require 'concur-primitives)
(require 'concur-promise)
(require 'concur-scheduler)
(require 'concur-coroutine)
(require 'dash)
(require 'scribe)
(require 'ts)

(cl-defstruct (concur-task
               (:constructor nil)
               (:constructor concur-make-task (&key id semaphore cancel-token future 
                                              schedule data name pending-at started-at succeeded-at 
                                              failed-at ended-at priority
                                              status trace-stack err result)))
  "A structure representing an asynchronous task to be scheduled and executed.

Fields:

`id:            Unique identifier for the task.
`semaphore`     A semaphore object used to control concurrent access to shared resources (optional).
`cancel-token`  A cancel token that can be used to cancel this task (optional).
`future`        The future object that represents the result of the asynchronous computation.
`schedule`      Specifies when the task should run.
`data`          Arbitrary user-defined metadata.
`name`          Human-readable task name.
`pending-at`    Timestamp when the task was created.
`started-at`    Timestamp when the task started.
`succeeded-at`  Timestamp when the task succeeded.
`failed-at`     Timestamp when the task failed.
`ended-at`      Timestamp when the task ended.
`status`        Current task status (:pending, :running, :success, :failed :ended).  
`priority`      Integer priority; higher means more urgent.
`trace-stack`   Trace data collected during task execution.
`err`           The task’s error, if any.
`result`        The task’s result or final error."

  id
  semaphore
  cancel-token
  future
  schedule 
  data
  name
  pending-at
  started-at
  succeeded-at
  failed-at
  ended-at
  status
  priority
  trace-stack
  err
  result)

(defcustom concur-task-max-retries most-positive-fixnum
  "Default maximum number of retries for a concur task.

This value is used when no explicit `:retries` argument is provided. Set this
to a high number to allow effectively infinite retries without looping forever."
  :type 'integer
  :group 'concur)

(defvar concur-task-current nil
  "Holds the current task being executed.")

(defvar concur-task-status-change-hook nil
  "Hook run when a task's status changes.

Each hook receives three arguments: the task object, the new status keyword,
and the previous status keyword. This can be used to observe all lifecycle
transitions in one place.")

(defvar concur-task--history (ht)
  "Ring buffer of the most recent tasks in any state.")

(defvar concur-task--error-info (ht)
  "Holds error information including step, form, error, and backtrace.")

;;;###autoload
(defun concur-task-new (&rest args)
  "Create a `concur-task` with the current timestamp set for `created-at`,
and a unique task ID generated with `gensym`."
  (apply #'concur-make-task
         :id (gensym "task-") ; Unique task ID
         :status :pending
         :started-at (ts-now)
         args))

(defmacro concur-task--define-marker! (name status &key timestamp?)
  "Define a task status transition function.

NAME is the suffix (e.g. 'started').
STATUS is the keyword status (e.g. :started).
If TIMESTAMP? is non-nil, also update the task's timestamp.

This macro expands into a function named `concur-task--mark-NAME`
which updates the task's status, sets a timestamp if required,
runs `concur-task-status-change-hook`, and records the status change
in the task history."
  (let* ((fn-name (intern (format "concur-task--mark-%s" name)))
         (timestamp-field (when timestamp?
                            (intern (format "concur-task-%s-at" name)))))
    `(defun ,fn-name (task &rest args)
       ,(format "Mark TASK as %s and run status-change hook." status)
       (let ((prev-status (concur-task-status task)))
         (setf (concur-task-status task) ,status)
         ,@(when timestamp?
             `((setf (,timestamp-field task) (ts-now))))
        
         (log! "Running async hooks, status: %s ==> %s" prev-status ,status)
         (run-hook-with-args 'concur-task-status-change-hook
                             task ,status prev-status)
         (concur-task--record-history task)))))

(concur-task--define-marker! pending :pending :timestamp? t)
(concur-task--define-marker! started :running :timestamp? t)
(concur-task--define-marker! succeeded :success :timestamp? t)
(concur-task--define-marker! failed :failed :timestamp? t)
(concur-task--define-marker! ended :ended :timestamp? t)

(defun concur-task--reschedule (task schedule)
  "Reschedule TASK based on SCHEDULE mode.
If SCHEDULE is 'thread, yield to thread scheduler.
Otherwise, enqueue the task for the next execution step."
  (log! "[%s] Rescheduling task" (concur-task-name task) :level 'info)
  (pcase schedule
    ('thread (thread-yield))
    (_       (concur-scheduler-enqueue task))))

(defun concur-task--make-thunk!
    (body step done result semaphore schedule cancel-token trace-label retries task)
  "Create a coroutine thunk that executes BODY with scheduling and retry logic.

Arguments:
  BODY         - List of forms as the task body.
  STEP         - Variable to track the current coroutine step.
  DONE         - Boolean tracking whether the task is finished.
  RESULT       - Variable to hold the final result.
  SEMAPHORE    - Optional semaphore to limit concurrency.
  SCHEDULE     - Mode of rescheduling ('thread or nil).
  CANCEL-TOKEN - Optional token to support external cancellation.
  TRACE-LABEL  - String label used in logs.
  RETRIES      - Maximum number of retry attempts.
  TASK         - The associated task object for status tracking.

Returns a thunk (zero-arg function) to step the coroutine once."
  (log! "[%s] Starting task" trace-label :level 'info)
  (setq retries (or retries concur-task-max-retries))
  (let ((attempt 0)
        (success nil))
    (cl-labels
        ((make-coroutine ()
           (log! "[%s] Creating coroutine" trace-label :level 'info)
           (defcoroutine! concur-task-coroutine ()
            :locals (step)

            ,@body

            ;; Hook before each step
            :before
            (lambda (step-idx _results ctx)
              (setq step step-idx)

              ;; Mark task as started only once
              (when (and (eq step 0) (= attempt 0))
                (setq attempt 1)
                (concur-task--mark-started task)
                (log! "[%s] Task started" trace-label :level 'info))

              ;; Cancel if requested
              (when (and cancel-token
                         (concur-cancel-token-active? cancel-token))
                (concur-task--mark-failed task 'canceled (list :step step))
                (concur-coroutine-throw! :cancel nil))

              ;; Semaphore check
              (when semaphore
                (with-semaphore! semaphore (lambda () (concur-task--reschedule task schedule))
                  :else
                  (progn
                    (log! "[%s] Waiting on semaphore at step %d" trace-label step :level 'debug)
                    (concur-coroutine-throw! :wait nil))))

              ;; In thread mode, yield immediately after step 0
              (when (and (eq schedule 'thread) (eq step 0))
                (thread-yield)))

            ;; Hook after each step
            :after
            (lambda (_step-idx _results ctx step-result)
              (when (>= step (1- (length body)))
                (setq done t)
                (setq success t)
                (concur-task--mark-succeeded task step-result (list :step step))
                (log! "[%s] Task succeeded" trace-label :level 'info))

              (unless done
                (concur-task--reschedule task schedule)))

            ;; Error handling hook
            :on-error
            (lambda (err ctx)
              (log! "[%s] Task error: %S (attempt %d/%d)"
                    trace-label err attempt retries :level 'warn)
              (if (< attempt retries)
                  (progn
                    (cl-incf attempt)
                    (setf (coroutine-ctx-state ctx) 0) ;; reset coroutine state
                    (log! "[%s] Retrying (attempt %d)" trace-label attempt :level 'info)
                    nil) ;; suppress error for retry
                (progn
                  (concur-task--mark-failed task err (list :step step))
                  (signal (car err) (cdr err))))))))
      (make-coroutine))))

;;;###autoload
(defmacro concur-task! (&rest args)
  "Run BODY as an asynchronous managed task with support for retries, timeouts, and scheduling.

Supported keyword arguments (trailing args in pairs):
  :schedule    How to schedule the task (e.g., 'thread).
  :cancel      A cancel token object to interrupt execution.
  :meta        A plist of metadata to associate with the task.
  :timeout     Timeout in seconds after which task is canceled.
  :retries     Number of retry attempts on failure.
  :tags        List of tags to label the task.
  :trace       String label for logs and debugging.
  :semaphore   Concurrency limiter to acquire before running.

Returns a promise representing the eventual result.

Example:
  (concur-task!
    (do-network-request)
    (process-response)
    :retries 2
    :timeout 5
    :tags '(network api)
    :trace \"request-task\")"
  (declare (indent defun) (debug (&rest form)))
  (let* ((args* args)
         (body nil)
         ;; Keyword argument holders
         (schedule nil) (cancel-token nil) (meta nil) (timeout nil)
         (retries nil) (tags nil) (trace nil) (semaphore nil))

    ;; Parse trailing keyword args
    (while (and args* (keywordp (car (last args*))))
      (let ((kw (car (last args*)))
            (val (car (last (butlast args*)))))
        (setq args* (butlast args* 2))
        (pcase kw
          (:schedule   (setq schedule val))
          (:cancel     (setq cancel-token val))
          (:meta       (setq meta val))
          (:timeout    (setq timeout val))
          (:retries    (setq retries val))
          (:tags       (setq tags val))
          (:trace      (setq trace val))
          (:semaphore  (setq semaphore val))
          (_ (error "Unknown keyword %S passed to concur-task!" kw)))))

    (setq body args*)
    (unless body
      (error "concur-task!: no body forms provided"))

    ;; Unique symbols for local vars
    (let* ((task (make-symbol "task"))
           (future (make-symbol "future"))
           (promise (make-symbol "promise"))
           (done (make-symbol "done"))
           (result (make-symbol "result"))
           (step (make-symbol "step"))
           (trace-label (or trace (format "task-%s" (gensym "id"))))
           (meta* `(-> (or ,meta '())
                       (plist-put :tags ,tags)
                       (plist-put :trace ,trace-label))))

      `(let* ((,done nil)
              (,result nil)
              (,step 0)
              (,task (concur-task-new
                      :future nil
                      :schedule ,schedule
                      :cancel-token ,cancel-token
                      :data ,meta*)))

         (log! "[%s] Creating async task..." ,trace-label :level 'info)

         ;; Wrap coroutine into a future
         (let* ((,future
                 (concur-future-new
                  (concur-task--make-thunk!
                   (progn ,@body)
                   ,step ,done ,result
                   ,semaphore ,schedule ,cancel-token
                   ,trace-label ,retries ,task)))
                (,promise (concur-future-promise ,future)))

           (setf (concur-task-future ,task) ,future)

           ;; Apply timeout if provided
           ,(when timeout
              `(progn
                 (log! "[%s] Attaching timeout (%ss)" ,trace-label ,timeout :level 'info)
                 (concur-promise-timeout ,promise ,timeout
                   (lambda ()
                     (log! "[%s] Task timed out" ,trace-label :level 'error)
                     (concur-task-cancel ,task :reason :timeout)))))

           ;; Enqueue to scheduler
           (concur-scheduler-enqueue-task ,task)

           ;; Return task result promise
           ,promise)))))

(defun concur-task--record-history (task status)
  "Record the status change of TASK in the history, ensuring no duplicates."
  (let ((task-id (concur-task-id task)))
    ;; Check if the task already exists in the history
    (unless (ht-get concur-task--history task-id)
      (ht-set! concur-task--history task-id (list :task task :status status :timestamp (ts-now))))))

;;;###autoload
(defun concur-task-history-clear ()
  "Clear the recorded task history."
  (setq concur-task--history (make-ring concur-task-history-size)))

;;;###autoload
(defun concur-task-history (&optional statuses)
  "Return tasks in history, optionally filtered by STATUSES (symbol or list)."
  (let ((all (ht-values concur-task-history)))  ; Get all the tasks in the hash table
    (when statuses
      (setq statuses (if (listp statuses) statuses (list statuses)))
      (setq all (--filter (member (concur-task-status it) statuses) all)))
    (--sort (ts< (or (concur-task-started-at it) (ts-now))
                (or (concur-task-started-at other) (ts-now)))
            all)))

(provide 'concur-task)
;;; concur-task.el ends here