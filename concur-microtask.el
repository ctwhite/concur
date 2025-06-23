;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-microtask.el --- Microtask queue for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:

;; This file provides a self-scheduling microtask queue for the Concur
;; asynchronous library, designed for Promise/A+ compliance. It manages a
;; FIFO queue of microtasks, processes them in batches, and automatically
;; reschedules draining to ensure Emacs remains responsive.
;;
;; Microtasks are high-priority, short-lived tasks (like promise callbacks)
;; that must execute as soon as possible after the current Emacs Lisp
;; operation completes, but *before* returning control to the main event loop
;; or processing macrotasks (scheduled by idle timers). This ensures
;; predictable execution order and responsiveness.
;;
;; This module internally uses `concur-queue.el` for its queue implementation,
;; providing efficient (O(1)) enqueue and dequeue operations.

;;; Code:

(require 'cl-lib)        ; For cl-loop, cl-subseq
(require 'dash)          ; For --each, -filter

(require 'concur-lock)   ; For mutexes
(require 'concur-log)    ; For `concur--log`
(require 'concur-queue)  ; For `concur-queue` data structure and API

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward Declarations

(declare-function concur:make-error "concur-core")
(declare-function concur-promise-p "concur-core")
(declare-function concur-execute-callback "concur-core")
(declare-function concur:reject "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Errors & Customization

(define-error 'concur-microtask-queue-overflow
  "The microtask queue has exceeded its capacity."
  'concur-error)

(defcustom concur-microtask-queue-capacity 1024
  "Maximum number of microtasks allowed in the queue.
Setting to 0 or less disables capacity limits. This is not
recommended as it can lead to memory exhaustion under load in
case of runaway microtask scheduling."
  :type '(integer :min 0) 
  :group 'concur)

(defcustom concur-microtask-max-batch-size 128
  "Maximum number of microtasks to process in a single drain tick.
If the queue has more tasks than this, another drain tick will be
scheduled immediately (via `run-with-timer 0`). This prevents any
single microtask drain cycle from blocking Emacs for too long."
  :type '(integer :min 1) 
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct and Global Instance

(cl-defstruct (concur-microtask-queue (:constructor %%make-microtask-queue))
  "Internal structure representing a microtask queue.

  Arguments:
  - `queue` (concur-queue): The underlying `concur-queue` instance
    serving as a FIFO queue of `concur-callback` objects.
  - `lock` (concur-lock): A mutex to synchronize access to the queue.
    Defaults to `nil` (initialized in constructor).
  - `drain-scheduled-p` (boolean): `t` if a drain operation has already
    been scheduled for the next Emacs tick. Prevents redundant scheduling.
    Defaults to `nil`.
  - `current-tick` (integer): A counter incremented for each drain cycle.
    Used for debugging and internal tracking. Defaults to 0."
  (queue nil :type (satisfies concur-queue-p))
  (lock nil :type (or null (satisfies concur-lock-p)))
  (drain-scheduled-p nil :type boolean)
  (current-tick 0 :type integer))

(defvar concur--global-microtask-queue
  (%%make-microtask-queue
   :queue (concur-queue-create)
   :lock (concur:make-lock "microtask-queue-lock")
   :drain-scheduled-p nil
   :current-tick 0)
  "Singleton instance of the global microtask queue.
All microtasks are added to and processed from this queue.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Queue Manipulation Functions

(defun concur-microtask-queue-add (callbacks)
  "Add CALLBACKS to the global microtask queue.
Promises/A+ 2.2.4: Callbacks must be invoked asynchronously. This function
enqueues callbacks and ensures a drain operation is scheduled for the next
available moment in the Emacs event loop (via `run-with-timer 0`).

  Arguments:
  - `CALLBACKS` (list): A list of `concur-callback` structs to add.

  Returns:
  - `nil` (side-effect: enqueues callbacks, schedules drain).
    If the queue exceeds `concur-microtask-queue-capacity`, callbacks
    causing the overflow are rejected (if associated with a promise)."
  (unless (listp callbacks)
    (user-error "concur-microtask-queue-add: CALLBACKS must be a list: %S"
                callbacks))
  (concur:with-mutex! (concur-microtask-queue-lock
                       concur--global-microtask-queue)
    (let* ((capacity concur-microtask-queue-capacity)
           (queue-instance (concur-microtask-queue-queue
                            concur--global-microtask-queue))
           (overflowed-callbacks '()))
      ;; Add callbacks one-by-one, checking capacity for each.
      (dolist (cb callbacks)
        (if (and (> capacity 0)
                 (>= (concur-queue-length queue-instance)
                     capacity))
            (push cb overflowed-callbacks) ; Collect overflowed
          (concur-queue-enqueue queue-instance cb)))
      ;; Reject any promises associated with overflowed callbacks.
      (when overflowed-callbacks
        (let ((msg (format "Microtask queue overflow (capacity: %d)" capacity)))
          (concur--log :warn nil "Microtask queue overflow: %d callbacks dropped."
                       (length overflowed-callbacks))
          (dolist (cb overflowed-callbacks)
            (when-let (p (concur-callback-promise cb))
              (concur:reject p (concur:make-error
                                :type :microtask-queue-overflow
                                :message msg))))))))

  ;; Schedule a drain operation if one is not already pending. This check
  ;; prevents multiple redundant timers from being created.
  (unless (concur-microtask-queue-drain-scheduled-p
           concur--global-microtask-queue)
    (setf (concur-microtask-queue-drain-scheduled-p
           concur--global-microtask-queue) t)
    ;; `run-with-timer 0 nil ...` schedules for the next available CPU cycle.
    (run-with-timer 0 nil #'concur-microtask-queue-drain)))

(defun concur-microtask-queue-drain ()
  "Process a batch of microtasks from the global queue.
This function is designed to avoid deadlocks: it acquires the queue's
lock only to pop a batch of tasks, then releases the lock *before*
executing them. This ensures that a microtask can safely schedule
more microtasks without deadlocking.

  Returns:
  - `nil` (side-effect: executes microtasks, reschedules if needed)."
  ;; Reset scheduling flag. A new drain can now be scheduled by new tasks.
  (setf (concur-microtask-queue-drain-scheduled-p
         concur--global-microtask-queue) nil)
  (cl-incf (concur-microtask-queue-current-tick
            concur--global-microtask-queue))
  (concur--log :debug nil "Microtask queue drain tick %d started."
               (concur-microtask-queue-current-tick
                concur--global-microtask-queue))

  (let (batch)
    ;; Step 1: Acquire lock ONLY to pop tasks off the queue.
    (concur:with-mutex! (concur-microtask-queue-lock
                         concur--global-microtask-queue)
      (let* ((queue-instance (concur-microtask-queue-queue
                              concur--global-microtask-queue))
             (batch-size (min (concur-queue-length queue-instance)
                              concur-microtask-max-batch-size)))
        (cl-loop for i from 1 to batch-size do
                 (push (concur-queue-dequeue queue-instance) batch))
        (setq batch (nreverse batch))))

    ;; Step 2: Execute the callbacks outside the critical section (lock released).
    (when batch
      (concur--log :debug nil "Processing %d microtasks in tick %d."
                   (length batch)
                   (concur-microtask-queue-current-tick
                    concur--global-microtask-queue))
      (dolist (cb batch)
        (condition-case err
            ;; `concur--execute-callback` is defined in `concur-core.el`
            (concur-execute-callback cb)
          (error
           (concur--log :error nil "Unhandled error in microtask callback: %S"
                        err)))))

    ;; Step 3: Reschedule if more tasks remain.
    (let ((remaining-queue-p nil))
      (concur:with-mutex! (concur-microtask-queue-lock
                           concur--global-microtask-queue)
        (setq remaining-queue-p
              (not (concur-queue-empty-p
                    (concur-microtask-queue-queue
                     concur--global-microtask-queue)))))
      (when (and remaining-queue-p
                 (not (concur-microtask-queue-drain-scheduled-p
                       concur--global-microtask-queue)))
        (setf (concur-microtask-queue-drain-scheduled-p
               concur--global-microtask-queue) t)
        (concur--log :debug nil "Rescheduling microtask drain for next tick.")
        (run-with-timer 0 nil #'concur-microtask-queue-drain)))))

(provide 'concur-microtask)
;;; concur-microtask.el ends here