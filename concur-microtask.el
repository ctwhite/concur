;;; concur-microtask.el --- Microtask queue for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; A self-scheduling microtask queue for Concur, designed for Promise/A+
;; compliance. It manages a FIFO queue of microtasks, processes them
;; in batches, and automatically reschedules draining to ensure responsiveness.
;;
;; Microtasks are high-priority, short-lived tasks (like promise callbacks)
;; that must execute as soon as possible after the current operation completes,
;; but before returning control to the main event loop.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-core)
(require 'concur-lock)
(require 'concur-hooks)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-microtask-queue-overflow
  "The microtask queue has exceeded its capacity." 'concur-error)

(defcustom concur-microtask-queue-capacity 1024
  "Maximum number of microtasks allowed in the queue.
Setting to 0 or less disables capacity limits. This is not
recommended as it can lead to memory exhaustion under load."
  :type 'integer
  :group 'concur)

(defcustom concur-microtask-max-batch-size 128
  "Maximum number of microtasks to process in a single tick.
If the queue has more tasks than this, another drain tick will be
scheduled immediately (via `run-with-timer 0`). This prevents
any single microtask drain cycle from blocking Emacs for too long."
  :type 'integer
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct and Global Instance

(cl-defstruct (concur-microtask-queue (:constructor %%make-microtask-queue))
  "Internal structure representing a microtask queue.

Fields:
- `queue` (list): A standard Emacs Lisp list serving as a FIFO queue of
  `concur-callback` objects. New tasks are appended at the end.
- `lock` (concur-lock): A mutex to synchronize access to the `queue` list.
- `drain-scheduled-p` (boolean): `t` if a drain operation has already
  been scheduled for the next Emacs tick. Prevents redundant scheduling.
- `current-tick` (integer): A counter incremented for each drain cycle."
  (queue '() :type list)
  (lock nil :type (or null concur-lock))
  (drain-scheduled-p nil :type boolean)
  (current-tick 0 :type integer))

(defvar concur--global-microtask-queue
  (%%make-microtask-queue
   :queue '()
   :lock (concur:make-lock "microtask-queue-lock")
   :drain-scheduled-p nil
   :current-tick 0)
  "Singleton instance of the global microtask queue.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Queue Manipulation Functions

(defun concur-microtask-queue-add (callbacks)
  "Add CALLBACKS to the global microtask queue.
Promises/A+ 2.2.4: Callbacks must be invoked asynchronously. This function
enqueues callbacks and ensures a drain operation is scheduled for the next
available moment in the Emacs event loop.

Arguments:
- `CALLBACKS` (list): A list of `concur-callback` structs to add.

Returns:
  nil. If the queue exceeds `concur-microtask-queue-capacity`, callbacks
  causing the overflow are rejected."
  (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
    (let* ((capacity concur-microtask-queue-capacity)
           (overflowed-callbacks '()))
      ;; Add callbacks one-by-one to check capacity.
      (dolist (cb callbacks)
        (if (and (> capacity 0)
                 (>= (length (concur-microtask-queue-queue
                              concur--global-microtask-queue))
                     capacity))
            (push cb overflowed-callbacks)
          (setf (concur-microtask-queue-queue concur--global-microtask-queue)
                (append (concur-microtask-queue-queue
                         concur--global-microtask-queue)
                        (list cb)))))
      ;; Reject any promises associated with overflowed callbacks.
      (when overflowed-callbacks
        (let ((msg (format "Microtask queue overflow (capacity: %d)" capacity)))
          (dolist (cb overflowed-callbacks)
            (when-let (p (concur-callback-promise cb))
              (concur:reject p (concur:make-error
                                :type :microtask-queue-overflow
                                :message msg))))))))

  ;; Schedule a drain operation if one is not already pending. This
  ;; check prevents multiple redundant timers from being created.
  (unless (concur-microtask-queue-drain-scheduled-p
           concur--global-microtask-queue)
    (setf (concur-microtask-queue-drain-scheduled-p
           concur--global-microtask-queue) t)
    ;; `run-with-timer 0 nil ...` schedules for the next idle CPU cycle.
    (run-with-timer 0 nil #'concur-microtask-queue-drain)))

(defun concur-microtask-queue-drain ()
  "Process a batch of microtasks from the global queue.
This function is designed to avoid deadlocks: it acquires the queue's
lock only to pop a batch of tasks, then releases the lock *before*
executing them. This ensures that a microtask can safely schedule
more microtasks without deadlocking.

Returns:
  nil. Automatically reschedules another tick if tasks remain."
  ;; Reset scheduling flag. A new drain can now be scheduled by new tasks.
  (setf (concur-microtask-queue-drain-scheduled-p concur--global-microtask-queue) nil)
  (cl-incf (concur-microtask-queue-current-tick concur--global-microtask-queue))

  (let (batch)
    ;; Step 1: Acquire lock ONLY to pop tasks off the queue.
    (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
      (let* ((queue (concur-microtask-queue-queue concur--global-microtask-queue))
             (batch-size (min (length queue) concur-microtask-max-batch-size)))
        (setq batch (cl-subseq queue 0 batch-size))
        ;; Update the queue with the remaining tasks.
        (setf (concur-microtask-queue-queue concur--global-microtask-queue)
              (cl-subseq queue batch-size))))

    ;; Step 2: Execute the callbacks outside the critical section (lock released).
    (when batch
      (dolist (cb batch)
        (condition-case err
            (concur--execute-callback cb)
          (error
           (message "Concur: Unhandled error in microtask callback: %s" err)))))

    ;; Step 3: Reschedule if more tasks remain.
    (let ((remaining-queue-p nil))
      (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
        (setq remaining-queue-p
              (concur-microtask-queue-queue concur--global-microtask-queue)))
      (when (and remaining-queue-p
                 (not (concur-microtask-queue-drain-scheduled-p
                       concur--global-microtask-queue)))
        (setf (concur-microtask-queue-drain-scheduled-p
               concur--global-microtask-queue) t)
        (run-with-timer 0 nil #'concur-microtask-queue-drain)))))

(provide 'concur-microtask)
;;; concur-microtask.el ends here