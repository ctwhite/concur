;;; concur-scheduler.el --- Generalized Task Scheduler for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a generalized, prioritized, and optionally adaptive
;; scheduler for executing asynchronous tasks in batches. It uses Emacs's
;; idle timer to prevent UI blocking while performing background work.
;;
;; The scheduler is designed for robustness. It uses a `:running-p` state
;; flag to ensure processing ticks are discrete. When a timer fires, it sets
;; this flag, processes a batch, unsets the flag, and only then re-checks if
;; new work has arrived to schedule the next tick. This prevents race
;; conditions and re-entrancy issues.

;;; Code:

(require 'cl-lib)
(require 'concur-log)
(require 'concur-lock)
(require 'concur-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:make-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
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


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-scheduler (:constructor %%make-scheduler) (:copier nil))
  "A generalized, prioritized task scheduler.

Fields:
- `id` (symbol): A unique identifier for the scheduler.
- `queue` (concur-priority-queue): The internal priority queue for tasks.
- `lock` (concur-lock): A mutex protecting the queue and timer state.
- `timer` (timer): The Emacs idle timer driving the scheduler.
- `running-p` (boolean): `t` if the scheduler is in a processing tick.
- `batch-size` (integer): Maximum number of tasks to process per cycle.
- `adaptive-delay-p` (boolean): Whether to use an adaptive timer delay.
- `min-delay` (float): Minimum delay for adaptive scheduling (seconds).
- `max-delay` (float): Maximum delay for adaptive scheduling (seconds).
- `process-fn` (function): The function `(lambda (batch))` invoked to process
  a batch of tasks.
- `delay-strategy-fn` (function): A function `(lambda (scheduler))` that
  computes the next timer delay."
  id queue lock timer (running-p nil)
  (batch-size concur-scheduler-default-batch-size)
  (adaptive-delay-p concur-scheduler-default-adaptive-delay)
  (min-delay concur-scheduler-default-min-delay)
  (max-delay concur-scheduler-default-max-delay)
  process-fn
  (delay-strategy-fn #'concur--scheduler-default-delay-strategy))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Logic

(defun concur--validate-scheduler (scheduler function-name)
  "Signal an error if SCHEDULER is not a `concur-scheduler`."
  (unless (concur-scheduler-p scheduler)
    (signal 'concur-invalid-scheduler-error
            (list (format "%s: Invalid scheduler object" function-name)
                  scheduler))))

(defun concur--scheduler-default-delay-strategy (scheduler)
  "Default strategy to compute the ideal idle timer delay."
  (if (not (concur-scheduler-adaptive-delay-p scheduler))
      (concur-scheduler-min-delay scheduler)
    (let* ((n (concur:priority-queue-length (concur-scheduler-queue scheduler)))
           (min-d (concur-scheduler-min-delay scheduler))
           (max-d (concur-scheduler-max-delay scheduler))
           (computed-delay (/ 0.1 (max 0.1 (/ (log (1+ n)) (log 2))))))
      (max min-d (min max-d computed-delay)))))

(defun concur--scheduler-start-timer-if-needed (scheduler)
  "Start the idle timer for SCHEDULER if it is not already running.
This function must be called from within the scheduler's lock."
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
  "The main timer callback. It pops a batch and processes it."
  (let (batch-to-process)
    ;; Phase 1: Set running flag and get work (LOCK HELD).
    (concur:with-mutex! (concur-scheduler-lock scheduler)
      (setf (concur-scheduler-timer scheduler) nil)
      (setf (concur-scheduler-running-p scheduler) t)
      (setq batch-to-process
            (concur:priority-queue-pop-n
             (concur-scheduler-queue scheduler)
             (concur-scheduler-batch-size scheduler))))
    ;; Phase 2: Process the batch (LOCK RELEASED).
    (when batch-to-process
      (funcall (concur-scheduler-process-fn scheduler) batch-to-process))
    ;; Phase 3: Finish cycle and check for more work (LOCK HELD).
    (concur:with-mutex! (concur-scheduler-lock scheduler)
      (setf (concur-scheduler-running-p scheduler) nil)
      (unless (concur:priority-queue-empty-p
               (concur-scheduler-queue scheduler))
        (concur--scheduler-start-timer-if-needed scheduler)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur-scheduler-create (&key name process-fn
                                   (priority-fn #'identity)
                                   (batch-size
                                    concur-scheduler-default-batch-size)
                                   adaptive-delay-p min-delay max-delay
                                   delay-strategy-fn)
  "Create and return a new `concur-scheduler` instance.

Arguments:
- `:NAME` (string): A descriptive name for the scheduler.
- `:PROCESS-FN` (function): A mandatory function `(lambda (batch))`
  that defines how to process a batch of tasks.
- `:PRIORITY-FN` (function): A function `(lambda (task))` that returns
  a number representing the task's priority (lower is higher).
- `:BATCH-SIZE` (integer): Max tasks per cycle.
- `:ADAPTIVE-DELAY-P` (boolean): Use adaptive idle timer delay.
- `:MIN-DELAY` (float): Min adaptive delay (seconds).
- `:MAX-DELAY` (float): Max adaptive delay (seconds).
- `:DELAY-STRATEGY-FN` (function): Optional function `(lambda (scheduler))`
  to compute the next timer delay.

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
  "Add a `TASK` to the `SCHEDULER`'s queue and start it if needed."
  (concur--validate-scheduler scheduler 'concur:scheduler-enqueue)
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    (concur:priority-queue-insert (concur-scheduler-queue scheduler) task)
    (concur--scheduler-start-timer-if-needed scheduler)))

;;;###autoload
(defun concur:scheduler-stop (scheduler)
  "Stop the `SCHEDULER`'s timer, preventing further processing."
  (concur--validate-scheduler scheduler 'concur:scheduler-stop)
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    (when-let ((timer (concur-scheduler-timer scheduler)))
      (cancel-timer timer)
      (setf (concur-scheduler-timer scheduler) nil)
      (concur-log :info (concur-scheduler-id scheduler) "Scheduler stopped."))))

;;;###autoload
(defun concur:scheduler-status (scheduler)
  "Return a snapshot of the `SCHEDULER`'s current status."
  (concur--validate-scheduler scheduler 'concur:scheduler-status)
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    `(:id ,(concur-scheduler-id scheduler)
      :queue-length ,(concur:priority-queue-length
                      (concur-scheduler-queue scheduler))
      :is-running-p ,(concur-scheduler-running-p scheduler)
      :has-timer-p ,(timerp (concur-scheduler-timer scheduler)))))

(provide 'concur-scheduler)
;;; concur-scheduler.el ends here