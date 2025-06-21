;;; concur-scheduler.el --- Generalized Task Scheduler for Concur -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This file provides a generalized, prioritized, and optionally adaptive
;; scheduler for executing asynchronous tasks in batches. It uses Emacs's
;; idle timer to prevent UI blocking while performing background work.
;; It's a foundational component for `concur`, offering flexible task management.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-core) ; For define-error
(require 'concur-lock)
(require 'concur-priority-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization Variables

(defgroup concur-scheduler nil "Customization for the Concur scheduler."
  :group 'concur)

(defcustom concur-scheduler-default-batch-size 10
  "Default maximum number of tasks to process in one scheduler cycle."
  :type 'integer
  :group 'concur-scheduler)

(defcustom concur-scheduler-default-adaptive-delay t
  "If non-nil, use an adaptive delay for scheduler timers by default."
  :type 'boolean
  :group 'concur-scheduler)

(defcustom concur-scheduler-default-min-delay 0.001
  "Default minimum delay (in seconds) for the adaptive scheduler."
  :type 'float
  :group 'concur-scheduler)

(defcustom concur-scheduler-default-max-delay 0.2
  "Default maximum delay (in seconds) for the adaptive scheduler."
  :type 'float
  :group 'concur-scheduler)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(eval-and-compile
  (cl-defstruct (concur-scheduler (:constructor %%make-concur-scheduler))
    "A generalized, prioritized task scheduler for Emacs.

Fields:
- `id` (symbol): A unique identifier (gensym) for the scheduler instance.
- `queue` (concur-priority-queue): The internal priority queue for tasks.
- `lock` (concur-lock): A mutex protecting the queue and timer.
- `timer` (timer): The Emacs idle timer driving the scheduler's processing.
- `batch-size` (integer): Maximum number of tasks to process per cycle.
- `adaptive-delay-p` (boolean): Whether to use an adaptive timer delay.
- `min-delay` (float): Minimum delay for adaptive scheduling (seconds).
- `max-delay` (float): Maximum delay for adaptive scheduling (seconds).
- `process-fn` (function): The function `(lambda (scheduler))` invoked
  by the timer to process a batch of tasks.
- `comparator` (function): A predicate `(lambda (task1 task2))` used by the
  priority queue to order tasks."
    (id (gensym "scheduler-") :type symbol)
    (queue nil :type (or null (satisfies concur-priority-queue-p)))
    (lock nil :type (or null (satisfies concur-lock-p)))
    (timer nil :type (or null (satisfies timerp)))
    (batch-size concur-scheduler-default-batch-size :type integer)
    (adaptive-delay-p concur-scheduler-default-adaptive-delay :type boolean)
    (min-delay concur-scheduler-default-min-delay :type float)
    (max-delay concur-scheduler-default-max-delay :type float)
    (process-fn nil :type (or null function))
    (comparator nil :type (or null function))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Scheduler Functions

;;;###autoload
(cl-defun concur-scheduler-create (&key name (batch-size 10)
                                   (adaptive-delay-p t) (min-delay 0.001)
                                   (max-delay 0.2) comparator process-fn)
  "Create and return a new `concur-scheduler` instance.

Arguments:
- `:NAME` (string, optional): A descriptive name for the scheduler instance.
- `:BATCH-SIZE` (integer, optional): Max tasks to process per cycle.
- `:ADAPTIVE-DELAY-P` (boolean, optional): Use adaptive idle timer delay.
- `:MIN-DELAY` (float, optional): Minimum adaptive delay in seconds.
- `:MAX-DELAY` (float, optional): Maximum adaptive delay in seconds.
- `:COMPARATOR` (function): A mandatory predicate `(lambda (t1 t2))`
  for ordering tasks in the priority queue.
- `:PROCESS-FN` (function): A mandatory function `(lambda (scheduler))`
  that defines how to process a batch of tasks.

Returns:
  (concur-scheduler) A newly created scheduler instance."
  (unless comparator (error "concur-scheduler-create: :comparator is required"))
  (unless process-fn (error "concur-scheduler-create: :process-fn is required"))

  (let* ((id (gensym (or name "scheduler-")))
         (scheduler (%%make-concur-scheduler
                     :id id :batch-size batch-size
                     :adaptive-delay-p adaptive-delay-p
                     :min-delay min-delay :max-delay max-delay
                     :comparator comparator :process-fn process-fn
                     :lock (concur:make-lock (format "%S-lock" id)))))
    (setf (concur-scheduler-queue scheduler)
          (concur-priority-queue-create :comparator comparator))
    scheduler))

(defun concur-scheduler--compute-delay (scheduler)
  "Compute the ideal idle timer delay based on queue size."
  (if (not (concur-scheduler-adaptive-delay-p scheduler))
      (concur-scheduler-min-delay scheduler)
    (let* ((n (concur-priority-queue-length (concur-scheduler-queue scheduler)))
           (min-d (concur-scheduler-min-delay scheduler))
           (max-d (concur-scheduler-max-delay scheduler)))
      (if (zerop n)
          max-d
        (max min-d (min max-d (/ 0.1 (/ (log (1+ n)) (log 2)))))))))

(defun concur-scheduler-stop (scheduler)
  "Stop the idle timer associated with SCHEDULER. Assumes lock is held."
  (when (timerp (concur-scheduler-timer scheduler))
    (cancel-timer (concur-scheduler-timer scheduler)))
  (setf (concur-scheduler-timer scheduler) nil))

(defun concur-scheduler-start (scheduler)
  "Start the idle timer for SCHEDULER if not running. Assumes lock is held."
  (unless (timerp (concur-scheduler-timer scheduler))
    (setf (concur-scheduler-timer scheduler)
          (run-with-idle-timer (concur-scheduler--compute-delay scheduler) t
                               (lambda ()
                                 (funcall (concur-scheduler-process-fn scheduler)
                                          scheduler))))))

;;;###autoload
(defun concur-scheduler-enqueue (scheduler task)
  "Add a TASK to the SCHEDULER's queue.
The scheduler's timer will be started automatically if it's not
already running. This function is thread-safe.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance.
- `TASK` (any): The task to add to the queue.

Returns:
  nil."
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    (concur-priority-queue-insert (concur-scheduler-queue scheduler) task)
    (concur-scheduler-start scheduler)))

;;;###autoload
(defun concur-scheduler-pop-batch (scheduler)
  "Pop a batch of tasks from the SCHEDULER's queue.
This is a low-level helper intended for use by a scheduler's `process-fn`.
It also handles stopping the timer if the queue becomes empty.

**CRITICAL: The caller MUST hold the `(concur-scheduler-lock SCHEDULER)`
before calling this function to prevent race conditions.**

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance.

Returns:
  (list) A list of tasks (up to `batch-size`). Returns `nil` if empty."
  (let ((batch (concur-priority-queue-pop-n
                (concur-scheduler-queue scheduler)
                (concur-scheduler-batch-size scheduler))))
    ;; If the queue is now empty, stop the timer to conserve resources.
    (when (concur-priority-queue-empty-p (concur-scheduler-queue scheduler))
      (concur-scheduler-stop scheduler))
    batch))

(provide 'concur-scheduler)
;;; concur-scheduler.el ends here