;;; concur-microtask.el --- Microtask Queue for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a self-scheduling microtask queue for the Concur library,
;; designed to meet the requirements of the Promise/A+ specification.
;;
;; What is a microtask?
;; A microtask is a small piece of work (like executing a promise callback)
;; that must run "as soon as possible" after the current operation finishes,
;; but *before* Emacs handles new user input or other timers.
;;
;; Why are microtasks necessary for promises?
;; The Promise/A+ specification (section 2.2.4) requires that promise
;; callbacks (`onFulfilled` or `onRejected`) are called asynchronously, never
;; in the same turn of the event loop that settled the promise. This prevents
;; "Zalgo" (unpredictable code that is sometimes sync, sometimes async) and
;; guarantees a consistent execution flow. This module fulfills that
;; requirement by using `(run-with-timer 0 nil ...)` to schedule work on the
;; very next tick of the Emacs event loop.

;;; Code:

(require 'cl-lib)
(require 'concur-lock)
(require 'concur-log)
(require 'concur-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur-error "concur-core")
(declare-function concur-execute-callback "concur-core")
(declare-function concur-callback-target-promise "concur-core")
(declare-function concur:make-error "concur-core")
(declare-function concur:reject "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-microtask-error
  "A generic error related to the microtask queue."
  'concur-error)

(define-error 'concur-microtask-queue-overflow
  "The microtask queue has exceeded its capacity."
  'concur-microtask-error)

(defcustom concur-microtask-queue-capacity 1024
  "Maximum number of microtasks allowed in the queue.
If the limit is reached, newly added tasks will be dropped and their
associated promises will be rejected."
  :type '(integer :min 0)
  :group 'concur)

(defcustom concur-microtask-max-batch-size 128
  "Maximum number of microtasks to process in a single drain tick."
  :type '(integer :min 1)
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State

(cl-defstruct (concur-microtask-queue (:constructor %%make-microtask-queue))
  "Internal structure representing the global microtask queue.

Fields:
- `queue` (concur-queue): The underlying FIFO queue of callbacks.
- `lock` (concur-lock): A mutex to synchronize access to the queue.
- `drain-scheduled-p` (boolean): `t` if a drain operation has already
  been scheduled, preventing redundant timers.
- `drain-tick-counter` (integer): A counter for drain cycles, for debugging."
  (queue nil :type (or null concur-queue-p))
  (lock nil :type (or null concur-lock-p))
  (drain-scheduled-p nil :type boolean)
  (drain-tick-counter 0 :type integer))

(defvar concur--global-microtask-queue
  (%%make-microtask-queue
   :queue (concur-queue-create)
   :lock (concur:make-lock "microtask-queue-lock")
   :drain-scheduled-p nil
   :drain-tick-counter 0)
  "The singleton instance of the global microtask queue.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Logic

(defun concur--reject-overflowed-callbacks (overflowed-callbacks)
  "Reject the promises associated with overflowed callbacks.

Arguments:
- `OVERFLOWED-CALLBACKS` (list): A list of `concur-callback` structs
  that were dropped from the queue."
  (let ((msg (format "Microtask queue overflow (capacity: %d)"
                     concur-microtask-queue-capacity)))
    (concur-log :warn nil "Microtask queue overflow: %d dropped."
                 (length overflowed-callbacks))
    (dolist (cb overflowed-callbacks)
      (when-let ((promise (concur-callback-target-promise cb)))
        (concur:reject
         promise
         (concur:make-error :type 'concur-microtask-queue-overflow
                            :message msg))))))

(defun concur--drain-microtask-queue ()
  "Process a batch of microtasks from the global queue.
This function is designed to avoid deadlocks by separating locking from
execution. It is intended to be called by a timer.

The logic proceeds in phases:
1.  Reset the scheduling flag under a lock.
2.  Grab a batch of tasks from the queue, also under a lock.
3.  Execute the batch *without* holding the lock. This is critical to
    allow callbacks to safely schedule more microtasks.
4.  Re-acquire the lock to check if more work was added during execution,
    and reschedule a new drain if necessary."
  ;; Phase 1: Reset scheduling flag.
  (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
    (setf (concur-microtask-queue-drain-scheduled-p
           concur--global-microtask-queue) nil))

  (cl-incf (concur-microtask-queue-drain-tick-counter
            concur--global-microtask-queue))
  (let ((tick (concur-microtask-queue-drain-tick-counter
               concur--global-microtask-queue)))
    (concur-log :debug nil "Microtask drain tick %d starting." tick)

    ;; Phase 2: Lock, grab a batch of tasks, and immediately unlock.
    (let ((batch)
          (queue (concur-microtask-queue-queue concur--global-microtask-queue)))
      (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
        (let ((batch-size (min (concur:queue-length queue)
                                concur-microtask-max-batch-size)))
          (setq batch (cl-loop repeat batch-size
                               collect (concur:queue-dequeue queue)))))

      ;; Phase 3: Execute the batch without holding the lock.
      (when batch
        (concur-log :debug nil "Processing %d microtasks in tick %d." (length batch) tick)
        (dolist (cb batch)
          (condition-case err (concur-execute-callback cb)
            (error (concur-log :error nil "Unhandled error in microtask: %S" err))))))

    ;; Phase 4: Lock again to check for more work and reschedule if needed.
    (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
      (let ((queue (concur-microtask-queue-queue concur--global-microtask-queue)))
        (when (and (not (concur:queue-empty-p queue))
                   (not (concur-microtask-queue-drain-scheduled-p
                         concur--global-microtask-queue)))
          (setf (concur-microtask-queue-drain-scheduled-p
                 concur--global-microtask-queue) t)
          (concur-log :debug nil "More microtasks remain; rescheduling drain.")
          (run-with-timer 0 nil #'concur--drain-microtask-queue))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:schedule-microtask (callback)
  "Add a single `CALLBACK` to the global microtask queue.
This is a convenience wrapper around `concur:schedule-microtasks`.

Arguments:
- `CALLBACK` (concur-callback): The callback struct to add.

Returns:
- `nil`."
  (concur:schedule-microtasks (list callback)))

;;;###autoload
(defun concur:schedule-microtasks (callbacks)
  "Add a list of `CALLBACKS` to the global microtask queue.
This function adds tasks and ensures a drain operation is scheduled
to process them on the next tick of the Emacs event loop.

Arguments:
- `CALLBACKS` (list): A list of `concur-callback` structs to add.

Returns:
- `nil`.

Signals:
- `error` if `CALLBACKS` is not a list. If the queue overflows,
  the promises associated with the dropped callbacks are rejected."
  (unless (listp callbacks)
    (error "Argument must be a list of callbacks: %S" callbacks))

  (let (overflowed)
    (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
      (let* ((capacity concur-microtask-queue-capacity)
             (queue (concur-microtask-queue-queue concur--global-microtask-queue)))
        (dolist (cb callbacks)
          (if (and (> capacity 0) (>= (concur:queue-length queue) capacity))
              (push cb overflowed)
            (concur:queue-enqueue queue cb)))))
    (when overflowed
      (concur--reject-overflowed-callbacks overflowed)))

  (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
    (unless (concur-microtask-queue-drain-scheduled-p
             concur--global-microtask-queue)
      (setf (concur-microtask-queue-drain-scheduled-p
             concur--global-microtask-queue) t)
      (run-with-timer 0 nil #'concur--drain-microtask-queue))))

(provide 'concur-microtask)
;;; concur-microtask.el ends here