;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-scheduler.el --- Generalized Task Scheduler for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;; This file provides a generalized, prioritized, and optionally adaptive
;; scheduler for executing asynchronous tasks in batches. It uses Emacs's
;; idle timer to prevent UI blocking while performing background work.
;; It's a foundational component for `concur`, offering flexible task management.

;;; Code:

(require 'cl-lib)                ; For cl-defstruct, cl-incf, cl-decf
(require 'dash)                  ; For -find-if, -count (though cl-lib is used for find-if)

(require 'concur-log)            ; For concur--log
(require 'concur-lock)           ; For mutexes
(require 'concur-priority-queue) ; For task prioritization

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customization Variables

(defcustom concur-scheduler-default-batch-size 10
  "Default maximum number of tasks to process in one scheduler cycle.
This controls how many tasks are popped from the queue and processed
in a single tick of the scheduler's idle timer."
  :type '(integer :min 1) ; Must be at least 1
  :group 'concur)

(defcustom concur-scheduler-default-adaptive-delay t
  "If non-nil, use an adaptive delay for scheduler timers by default.
An adaptive delay adjusts the polling interval based on the queue size
to balance responsiveness and CPU usage. If `nil`, a fixed delay of
`concur-scheduler-default-min-delay` is used."
  :type 'boolean
  :group 'concur)

(defcustom concur-scheduler-default-min-delay 0.001
  "Default minimum delay (in seconds) for the adaptive scheduler.
This is the shortest time the scheduler will wait between batches,
providing high responsiveness when tasks are abundant."
  :type '(float :min 0.0)
  :group 'concur)

(defcustom concur-scheduler-default-max-delay 0.2
  "Default maximum delay (in seconds) for the adaptive scheduler.
This is the longest time the scheduler will wait when the queue is
empty or small, reducing CPU usage during idle periods."
  :type '(float :min 0.0)
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct Definition

(eval-and-compile
  (cl-defstruct (concur-scheduler (:constructor %%make-concur-scheduler))
    "A generalized, prioritized task scheduler for Emacs.

  Arguments:
  - `id` (symbol): A unique identifier (`gensym`) for the scheduler instance.
  - `queue` (concur-priority-queue): The internal priority queue for tasks.
    Defaults to `nil` (initialized in constructor).
  - `lock` (concur-lock): A mutex protecting the queue and timer. Defaults
    to `nil` (initialized in constructor).
  - `timer` (timer or nil): The Emacs idle timer driving the scheduler's
    processing. Defaults to `nil`.
  - `batch-size` (integer): Maximum number of tasks to process per cycle.
    Defaults to `concur-scheduler-default-batch-size`.
  - `adaptive-delay-p` (boolean): Whether to use an adaptive timer delay.
    Defaults to `concur-scheduler-default-adaptive-delay`.
  - `min-delay` (float): Minimum delay for adaptive scheduling (seconds).
    Defaults to `concur-scheduler-default-min-delay`.
  - `max-delay` (float): Maximum delay for adaptive scheduling (seconds).
    Defaults to `concur-scheduler-default-max-delay`.
  - `process-fn` (function): The function `(lambda (scheduler))` invoked
    by the timer to process a batch of tasks. This is a mandatory argument.
  - `comparator` (function): A predicate `(lambda (task1 task2))` used by
    the priority queue to order tasks. This is a mandatory argument."
    (id nil :type symbol)
    (queue nil :type (or null (satisfies concur-priority-queue-p)))
    (lock nil :type (or null (satisfies concur-lock-p)))
    (timer nil :type (or timer null))
    (batch-size concur-scheduler-default-batch-size :type integer)
    (adaptive-delay-p concur-scheduler-default-adaptive-delay :type boolean)
    (min-delay concur-scheduler-default-min-delay :type float)
    (max-delay concur-scheduler-default-max-delay :type float)
    (process-fn nil :type function)
    (comparator nil :type function)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Scheduler Functions

;;;###autoload
(cl-defun concur-scheduler-create (&key name (batch-size concur-scheduler-default-batch-size)
                                   (adaptive-delay-p concur-scheduler-default-adaptive-delay)
                                   (min-delay concur-scheduler-default-min-delay)
                                   (max-delay concur-scheduler-default-max-delay)
                                   comparator process-fn)
  "Create and return a new `concur-scheduler` instance.

  Arguments:
  - `:NAME` (string, optional): A descriptive name for the scheduler instance.
    Defaults to a `gensym`-based name.
  - `:BATCH-SIZE` (integer, optional): Max tasks to process per cycle.
    Defaults to `concur-scheduler-default-batch-size`.
  - `:ADAPTIVE-DELAY-P` (boolean, optional): Use adaptive idle timer delay.
    Defaults to `concur-scheduler-default-adaptive-delay`.
  - `:MIN-DELAY` (float, optional): Minimum adaptive delay in seconds.
    Defaults to `concur-scheduler-default-min-delay`.
  - `:MAX-DELAY` (float, optional): Maximum adaptive delay in seconds.
    Defaults to `concur-scheduler-default-max-delay`.
  - `:COMPARATOR` (function): A mandatory predicate `(lambda (t1 t2))`
    for ordering tasks in the priority queue.
  - `:PROCESS-FN` (function): A mandatory function `(lambda (scheduler))`
    that defines how to process a batch of tasks.

  Returns:
  - (concur-scheduler): A newly created scheduler instance."
  (unless (functionp comparator)
    (user-error "concur-scheduler-create: :comparator must be a function: %S"
                comparator))
  (unless (functionp process-fn)
    (user-error "concur-scheduler-create: :process-fn must be a function: %S"
                process-fn))
  (let* ((id (gensym (or name "scheduler-")))
         (scheduler (%%make-concur-scheduler
                     :id id :batch-size batch-size
                     :adaptive-delay-p adaptive-delay-p
                     :min-delay min-delay :max-delay max-delay
                     :comparator comparator :process-fn process-fn
                     :lock (concur:make-lock (format "%S-lock" id)))))
    (setf (concur-scheduler-queue scheduler)
          (concur-priority-queue-create :comparator comparator))
    (concur--log :info (concur-scheduler-id scheduler) "Scheduler created.")
    scheduler))

(defun concur-scheduler--compute-delay (scheduler)
  "Compute the ideal idle timer delay based on queue size.
If adaptive delay is enabled, this function calculates a delay that is
shorter when the queue is large (to process tasks faster) and longer
when the queue is empty or small (to reduce CPU usage during idle).
The formula used attempts to balance responsiveness with resource use.

  Arguments:
  - `scheduler` (concur-scheduler): The scheduler instance.

  Returns:
  - (float): The computed delay in seconds."
  (if (not (concur-scheduler-adaptive-delay-p scheduler))
      (concur-scheduler-min-delay scheduler)
    (let* ((n (concur-priority-queue-length (concur-scheduler-queue scheduler)))
           (min-d (concur-scheduler-min-delay scheduler))
           (max-d (concur-scheduler-max-delay scheduler))
           ;; This formula makes the delay *shorter* as the queue grows
           ;; (as log(1+n) increases, the divisor increases, making the result smaller).
           ;; This results in more aggressive processing when many tasks are pending.
           (computed-delay (/ 0.1 (max 0.1 (/ (log (1+ n)) (log 2))))))
      (max min-d (min max-d computed-delay)))))

(defun concur-scheduler-stop (scheduler)
  "Stop the idle timer associated with SCHEDULER.
This function should typically be called from within the scheduler's lock.

  Arguments:
  - `scheduler` (concur-scheduler): The scheduler instance.

  Returns:
  - `nil` (side-effect: stops timer)."
  (when (timerp (concur-scheduler-timer scheduler))
    (concur--log :debug (concur-scheduler-id scheduler) "Scheduler timer stopped.")
    (cancel-timer (concur-scheduler-timer scheduler)))
  (setf (concur-scheduler-timer scheduler) nil))

(defun concur-scheduler-start (scheduler)
  "Start the idle timer for SCHEDULER if not running.
This function should typically be called from within the scheduler's lock.

  Arguments:
  - `scheduler` (concur-scheduler): The scheduler instance.

  Returns:
  - `nil` (side-effect: starts timer)."
  (unless (timerp (concur-scheduler-timer scheduler))
    (let ((delay (concur-scheduler--compute-delay scheduler)))
      (setf (concur-scheduler-timer scheduler)
            (run-with-idle-timer delay t
                                 (lambda ()
                                   (funcall (concur-scheduler-process-fn scheduler)
                                            scheduler))))
      (concur--log :debug (concur-scheduler-id scheduler)
                   "Scheduler timer started with delay %S." delay))))

;;;###autoload
(defun concur-scheduler-enqueue (scheduler task)
  "Add a TASK to the SCHEDULER's queue.
The scheduler's timer will be started automatically if it's not
already running. This function is thread-safe.

  Arguments:
  - `SCHEDULER` (concur-scheduler): The scheduler instance.
  - `TASK` (any): The task to add to the queue.

  Returns:
  - `nil` (side-effect: enqueues task, starts timer)."
  (unless (concur-scheduler-p scheduler)
    (user-error "concur-scheduler-enqueue: Invalid scheduler object: %S"
                scheduler))
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
  - (list): A list of tasks (up to `batch-size`). Returns `nil` if empty."
  (unless (concur-scheduler-p scheduler)
    (user-error "concur-scheduler-pop-batch: Invalid scheduler object: %S"
                scheduler))
  (let ((batch (concur-priority-queue-pop-n
                (concur-scheduler-queue scheduler)
                (concur-scheduler-batch-size scheduler))))
    ;; If the queue is now empty, stop the timer to conserve resources.
    (when (concur-priority-queue-empty-p (concur-scheduler-queue scheduler))
      (concur-scheduler-stop scheduler))
    batch))

;;;###autoload
(defun concur-scheduler-status (scheduler)
  "Return a snapshot of the SCHEDULER's current status.

  Arguments:
  - `SCHEDULER` (concur-scheduler): The scheduler instance to inspect.

  Returns:
  - (plist): A property list with scheduler metrics:
    `:name`: Name of the scheduler.
    `:queue-length`: Number of tasks currently in the queue.
    `:is-running`: Whether the scheduler's timer is active.
    `:batch-size`: Max tasks processed per cycle.
    `:adaptive-delay-p`: Whether adaptive delay is enabled.
    `:min-delay`: Minimum delay in seconds.
    `:max-delay`: Maximum delay in seconds."
  (interactive)
  (unless (concur-scheduler-p scheduler)
    (user-error "concur-scheduler-status: Invalid scheduler object: %S"
                scheduler))
  (concur:with-mutex! (concur-scheduler-lock scheduler)
    `(:name ,(concur-scheduler-id scheduler)
      :queue-length ,(concur-priority-queue-length
                      (concur-scheduler-queue scheduler))
      :is-running ,(timerp (concur-scheduler-timer scheduler))
      :batch-size ,(concur-scheduler-batch-size scheduler)
      :adaptive-delay-p ,(concur-scheduler-adaptive-delay-p scheduler)
      :min-delay ,(concur-scheduler-min-delay scheduler)
      :max-delay ,(concur-scheduler-max-delay scheduler))))

(provide 'concur-scheduler)
;;; concur-scheduler.el ends here