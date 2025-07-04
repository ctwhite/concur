;;; concur-scheduler.el --- Generalized Task Scheduler for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides a generalized, prioritized, and optionally adaptive
;; scheduler for executing asynchronous tasks in batches. It primarily serves
;; as the **macrotask scheduler** for the `Concur` promise library, using
;; Emacs's idle timer to defer execution and prevent UI blocking while
;; performing background work.
;;
;; The scheduler is designed for robustness. It uses an internal `:running-p`
;; state flag to ensure processing ticks are discrete and to prevent
;; re-entrancy issues. It efficiently manages its internal timer, ensuring
;; it is active only when there is actual work to do in the queue.
;;
;; Key functionalities:
;; - **Prioritized Queue:** Tasks can be enqueued with a priority, ensuring
;;   higher-priority tasks are processed first.
;; - **Adaptive Delay:** Can dynamically adjust the delay between processing
;;   cycles based on the queue size, optimizing responsiveness versus CPU usage.
;; - **Non-Blocking Execution:** Leverages Emacs's idle timer
;;   (`run-with-idle-timer`) to ensure processing happens cooperatively when
;;   Emacs is idle, preserving UI responsiveness during long-running tasks.

;;; Code:

(require 'cl-lib)
(require 'subr-x) ; Provides `timerp`.
(require 'concur-log)
(require 'concur-lock)
(require 'concur-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:make-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-scheduler-error
  "A generic error related to a `concur-scheduler`."
  'concur-error)

(define-error 'concur-invalid-scheduler-error
  "An operation was attempted on an invalid scheduler object."
  'concur-scheduler-error)

(defcustom concur-scheduler-default-batch-size 10
  "Default maximum number of tasks to process in one scheduler cycle."
  :type '(integer :min 1)
  :group 'concur)

(defcustom concur-scheduler-default-adaptive-delay t
  "If non-nil, use an adaptive delay for scheduler timers by default."
  :type 'boolean
  :group 'concur)

(defcustom concur-scheduler-default-min-delay 0.001
  "Default minimum delay (in seconds) for the adaptive scheduler."
  :type '(float :min 0.0)
  :group 'concur)

(defcustom concur-scheduler-default-max-delay 0.2
  "Default maximum delay (in seconds) for the adaptive scheduler."
  :type '(float :min 0.0)
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-scheduler (:constructor %%make-scheduler) (:copier nil))
  "A generalized, prioritized task scheduler for deferred execution (macrotasks).

Fields:
- `id` (symbol): Unique identifier for the scheduler instance.
- `queue` (concur-priority-queue): Internal priority queue holding tasks.
- `lock` (concur-lock): Mutex protecting the queue and scheduler state.
- `timer` (timer or nil): The Emacs `idle-timer` object. `nil` if not running.
- `running-p` (boolean): `t` if scheduler is processing a batch.
- `batch-size` (integer): Max tasks to process in one cycle.
- `adaptive-delay-p` (boolean): `t` for adaptive timer delay.
- `min-delay` (float): Minimum delay (seconds) for adaptive scheduling.
- `max-delay` (float): Maximum delay (seconds) for adaptive scheduling.
- `process-fn` (function): `(lambda (batch))` invoked to process tasks.
- `delay-strategy-fn` (function): `(lambda (scheduler))` computes next delay."
  id
  (queue nil :type concur-priority-queue)
  (lock nil :type concur-lock)
  (timer nil :type (or timer null))
  (running-p nil :type boolean)
  (batch-size concur-scheduler-default-batch-size :type integer)
  (adaptive-delay-p concur-scheduler-default-adaptive-delay :type boolean)
  (min-delay concur-scheduler-default-min-delay :type float)
  (max-delay concur-scheduler-default-max-delay :type float)
  (process-fn nil :type function)
  (delay-strategy-fn #'concur--scheduler-default-delay-strategy :type function))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Logic

(defun concur--validate-scheduler (scheduler function-name)
  "Signal an error if SCHEDULER is not a `concur-scheduler`.

Arguments:
- `SCHEDULER` (any): Object to validate.
- `FUNCTION-NAME` (symbol): Calling function's name for error reporting.

Signals:
- `concur-invalid-scheduler-error` if `SCHEDULER` is not a `concur-scheduler`."
  (unless (concur-scheduler-p scheduler)
    (signal 'concur-invalid-scheduler-error
            (list (format "%s: Invalid scheduler object" function-name)
                  scheduler))))

(defun concur--scheduler-default-delay-strategy (scheduler)
  "Default strategy to compute the ideal idle timer delay.
Determines how long to wait before the next batch is processed.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance.

Returns:
- (float): The computed delay in seconds for the next timer tick."
  (if (not (concur-scheduler-adaptive-delay-p scheduler))
      (concur-scheduler-min-delay scheduler)
    ;; Adaptive logic: Delay decreases as queue size (n) increases.
    (let* ((n (concur:priority-queue-length (concur-scheduler-queue scheduler)))
           (min-d (concur-scheduler-min-delay scheduler))
           (max-d (concur-scheduler-max-delay scheduler))
           (computed-delay (/ 0.1 (max 0.1 (/ (log (1+ n)) (log 2))))))
      (max min-d (min max-d computed-delay)))))

(defun concur--scheduler-start-timer-if-needed (scheduler)
  "Start the idle timer for SCHEDULER if not already running.
Ensures the scheduler's timer is active if tasks exist and not processing.
Must be called from within the scheduler's lock.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance.

Side Effects:
- Starts or re-schedules the `scheduler`'s internal timer.
- Updates `scheduler-timer` field."
  (unless (or (timerp (concur-scheduler-timer scheduler))
              (concur-scheduler-running-p scheduler))
    (let ((delay (funcall (concur-scheduler-delay-strategy-fn scheduler)
                          scheduler)))
      (setf (concur-scheduler-timer scheduler)
            (run-with-idle-timer delay nil #'concur--scheduler-timer-callback
                                 scheduler))
      (concur-log :debug (concur-scheduler-id scheduler)
                   "Scheduler timer started with delay %.3fs." delay))))

(defun concur--scheduler-timer-callback (scheduler)
  "The main timer callback that processes batches of macrotasks.
Pops a batch, processes it, and reschedules if more work exists.
Ensures non-blocking processing to the UI.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance whose timer fired.

Side Effects:
- Processes tasks. Modifies `scheduler`'s `running-p` and `timer`.
- May call `process-fn`."
  (concur-log :info nil ">>> MACROTASK SCHEDULER TIMER FIRED for %S <<<"
               (concur-scheduler-id scheduler))

  (let (batch-to-process)
    (concur:with-mutex! (concur-scheduler-lock scheduler)
      (setf (concur-scheduler-running-p scheduler) t)
      (setq batch-to-process
            (concur:priority-queue-pop-n
             (concur-scheduler-queue scheduler)
             (concur-scheduler-batch-size scheduler))))

    (when batch-to-process
      (funcall (concur-scheduler-process-fn scheduler) batch-to-process))

    (concur:with-mutex! (concur-scheduler-lock scheduler)
      (setf (concur-scheduler-running-p scheduler) nil)
      (when (concur:priority-queue-empty-p (concur-scheduler-queue scheduler))
        (when-let ((timer (concur-scheduler-timer scheduler)))
          (cancel-timer timer)
          (setf (concur-scheduler-timer scheduler) nil)
          (concur-log :debug (concur-scheduler-id scheduler)
                       "Scheduler timer cancelled (queue empty).")))
      (unless (concur:priority-queue-empty-p (concur-scheduler-queue scheduler))
        (concur--scheduler-start-timer-if-needed scheduler)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur-scheduler-create (&key name process-fn
                                   (priority-fn #'identity)
                                   (batch-size
                                    concur-scheduler-default-batch-size)
                                   adaptive-delay-p min-delay max-delay
                                   delay-strategy-fn)
  "Create and return a new `concur-scheduler` instance (for macrotasks).

Arguments:
- `:NAME` (string): Descriptive name.
- `:PROCESS-FN` (function): Mandatory `(lambda (batch))` to process tasks.
- `:PRIORITY-FN` (function): `(lambda (task))` returns priority (lower is higher).
- `:BATCH-SIZE` (integer): Max tasks per cycle.
- `:ADAPTIVE-DELAY-P` (boolean): `t` for adaptive idle timer delay.
- `:MIN-DELAY` (float): Minimum delay (seconds) for adaptive scheduler.
- `:MAX-DELAY` (float): Maximum delay (seconds) for adaptive scheduler.
- `:DELAY-STRATEGY-FN` (function): Optional `(lambda (scheduler))` to compute
  next delay. If `nil`, default strategy is used.

Returns:
- `(concur-scheduler)`: A newly created scheduler instance."
  (unless (functionp process-fn) (error ":process-fn must be a function"))
  (unless (functionp priority-fn) (error ":priority-fn must be a function"))
  (let* ((id (gensym (or name "scheduler-")))
         (scheduler
          (%%make-scheduler
           :id id :batch-size batch-size
           :process-fn process-fn
           :adaptive-delay-p (or adaptive-delay-p
                                 concur-scheduler-default-adaptive-delay)
           :min-delay (or min-delay concur-scheduler-default-min-delay)
           :max-delay (or max-delay concur-scheduler-default-max-delay)
           :delay-strategy-fn (or delay-strategy-fn
                                  #'concur--scheduler-default-delay-strategy)
           :lock (concur:make-lock (format "%S-lock" id)))))
    (setf (concur-scheduler-queue scheduler)
          (concur-priority-queue-create
           :comparator (lambda (a b) (< (funcall priority-fn a)
                                        (funcall priority-fn b)))))
    (concur-log :info (concur-scheduler-id scheduler) "Scheduler created.")
    scheduler))

;;;###autoload
(defun concur:scheduler-enqueue (scheduler task)
  "Add a `TASK` to the `SCHEDULER`'s queue and start it if needed.
Typically used to enqueue **macrotasks**.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance.
- `TASK` (any): The task to add (e.g., a `concur-callback` object).

Signals:
- `concur-invalid-scheduler-error` if `SCHEDULER` is invalid.

Side Effects:
- Modifies the `scheduler`'s internal queue.
- May start the `scheduler`'s timer."
  (concur--validate-scheduler scheduler 'concur:scheduler-enqueue)
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    (concur:priority-queue-insert (concur-scheduler-queue scheduler) task)
    (concur--scheduler-start-timer-if-needed scheduler)))

;;;###autoload
(defun concur:scheduler-stop (scheduler)
  "Stop the `SCHEDULER`'s timer, preventing further processing.
Remaining tasks will not be processed unless restarted.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance to stop.

Side Effects:
- Cancels the `scheduler`'s internal timer.
- Clears the `scheduler`'s `timer` field."
  (concur--validate-scheduler scheduler 'concur:scheduler-stop)
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    (when-let ((timer (concur-scheduler-timer scheduler)))
      (cancel-timer timer)
      (setf (concur-scheduler-timer scheduler) nil)
      (concur-log :info (concur-scheduler-id scheduler) "Scheduler stopped."))))

;;;###autoload
(defun concur:scheduler-status (scheduler)
  "Return a snapshot of the `SCHEDULER`'s current status.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler to inspect.

Returns:
- (plist): Metrics including `:id`, `:queue-length`, `:is-running-p`,
  and `:has-timer-p`.

Signals:
- `concur-invalid-scheduler-error` if `SCHEDULER` is invalid."
  (concur--validate-scheduler scheduler 'concur:scheduler-status)
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    `(:id ,(concur-scheduler-id scheduler)
      :queue-length ,(concur:priority-queue-length
                      (concur-scheduler-queue scheduler))
      :is-running-p ,(concur-scheduler-running-p scheduler)
      :has-timer-p ,(timerp (concur-scheduler-timer scheduler)))))

(provide 'concur-scheduler)
;;; concur-scheduler.el ends here