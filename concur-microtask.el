;;; concur-microtask.el --- Microtask queue for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This module provides a microtask queue, a critical component for
;; implementing Promise/A+ compliant behavior. Microtasks are callbacks
;; that run synchronously after a promise settles, but before any
;; macrotasks (like timer-scheduled events) or UI updates. This ensures
;; immediate promise reactions complete predictably.
;;
;; This implementation encapsulates the queue's state within a dedicated
;; struct (`concur-microtask-queue`) and uses Emacs's built-in `ring`
;; library for an efficient, bounded circular buffer. It also includes
;; a 'tick' counter for improved observability.
;;
;; To handle potential infinite loops of promise resolutions (which would
;; otherwise freeze Emacs), the queue has a fixed capacity. If this
;; capacity is exceeded, it is treated as a critical error. Instead of
;; silently dropping the task, the promise that the task was intended to
;; settle is explicitly rejected with a `concur-microtask-queue-overflow`
;; error, ensuring that the failure is propagated and can be handled.

;;; Code:

(require 'cl-lib)   ; For cl-defstruct, cl-incf, etc.
(require 'dash)     ; For -each, -some, etc.
(require 'ring)     ; For ring-insert, ring-pop-front, make-ring
(require 'concur-primitives) ; For concur:make-lock, concur:with-mutex!
(require 'concur-hooks)      ; For concur--log

;; Forward declarations for byte-compiler (from concur-core)
(declare-function concur-process-scheduled-callbacks-batch "concur-core" (promise callbacks))
(declare-function concur:reject "concur-core" (promise error))
(declare-function concur:format-promise "concur-core" (promise))
(declare-function concur-callback-promise "concur-core" (callback))
(declare-function concur-callback-type "concur-core" (callback))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-microtask-queue-overflow
  "The microtask queue has exceeded its capacity." 'concur-error)

(defcustom concur-microtask-queue-capacity 1024
  "Maximum number of microtasks allowed in the queue at once.
This acts as a safety limit to prevent runaway microtask creation from
exhausting memory or freezing Emacs. When the queue is full, new microtasks
will be rejected with a `concur-microtask-queue-overflow` error.
A value of `nil` or 0 means no capacity limit (unbounded queue)."
  :type '(choice (integer :tag "Bounded (tasks)" :min 0)
                 (const :tag "Unbounded" nil))
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (concur-microtask-queue (:constructor concur-microtask-queue-create))
  "Represents a microtask queue.

Fields:
- `ring`: (ring) The underlying Emacs `ring` buffer storing `concur-callback`s.
- `lock`: (`concur-lock`) A mutex to protect queue access during concurrent
  modifications (e.g., from multiple promise settlements).
- `current-tick`: (integer) A counter incremented each time the queue is
  drained, useful for debugging execution order across ticks."
  (ring (make-ring (or concur-microtask-queue-capacity 1024)) :type ring)
  (lock (concur:make-lock "microtask-queue-lock") :type concur-lock)
  (current-tick 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Queue Instance

(defvar concur--global-microtask-queue nil
  "The global microtask queue instance. Lazily initialized on first use.")

(cl-defun concur--init-global-microtask-queue ()
  "Initializes the global microtask queue if it hasn't been already.
This ensures `concur--global-microtask-queue` is always a valid struct
before operations begin. It uses `concur-microtask-queue-capacity`
to determine the initial size of the underlying ring buffer.

Arguments:
- None.

Returns:
- `nil`."
  (unless concur--global-microtask-queue
    (setq concur--global-microtask-queue
          (concur-microtask-queue-create
           :ring (make-ring (or concur-microtask-queue-capacity 1024)))))
  nil)

;; Ensure the global queue is initialized when the file is loaded.
(concur--init-global-microtask-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Internal to Concur Library)

(cl-defun concur-microtask-queue-add (originating-promise callbacks-list)
  "Adds a list of callbacks to the global microtask queue.

This function is called by the core promise logic when a promise settles.
If `concur-microtask-queue-capacity` is set, this function will check
for overflow. If the queue is full, the promise that a callback was
meant to settle will be rejected with a `concur-microtask-queue-overflow`
error. This prevents runaway resource consumption and ensures the error
is propagated through the promise chain.

Arguments:
- `originating-promise` (`concur-promise`): The promise that just settled,
  triggering these callbacks.
- `callbacks-list` (list of `concur-callback`): Callbacks to add.

Returns:
- `nil`."
  (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
    (--each callbacks-list
            (lambda (cb)
              (let* ((queue-ring (concur-microtask-queue-ring concur--global-microtask-queue))
                     (capacity (ring-capacity queue-ring)))
                ;; Check if the queue is at capacity.
                (if (and capacity (> capacity 0) (= (ring-length queue-ring) capacity))
                    ;; --- Overflow Case ---
                    ;; Instead of dropping the task, reject the promise it was
                    ;; supposed to settle. This is a critical safety valve.
                    (let* ((target-promise (concur-callback-promise cb))
                           (error-msg (format "Microtask queue overflow (capacity: %d)." \
                                              "Potential infinite loop detected originating from promise: %s" \
                                              capacity
                                              (concur:format-promise originating-promise))))
                      (concur--log :error "[MICROTASK] %s" error-msg)
                      (when target-promise
                        (concur:reject target-promise `(concur-microtask-queue-overflow ,error-msg))))
                  ;; --- Normal Case ---
                  ;; Add the callback to the tail of the ring buffer.
                  (ring-insert queue-ring cb)))))
    (concur--log :debug "[MICROTASK] %d callbacks added. Length: %d."
                 (length callbacks-list)
                 (ring-length (concur-microtask-queue-ring concur--global-microtask-queue)))))

(cl-defun concur-microtask-queue-drain ()
  "Processes all callbacks currently in the global microtask queue synchronously.
This function should be called right after a promise settles, to ensure
all microtasks (promise reactions) are completed before control yields
to the main event loop for macrotasks or UI rendering. It increments
the queue's `current-tick` counter for observability.

The implementation is careful to drain all tasks present at the start of
the call, without processing new tasks that might be added during the
drain itself. This prevents a single `drain` call from looping infinitely.

Arguments:
- None.

Returns:
- `nil`."
  (concur:with-mutex! (concur-microtask-queue-lock concur--global-microtask-queue)
    (let* ((queue-ring (concur-microtask-queue-ring concur--global-microtask-queue))
           (tasks-in-tick (ring-length queue-ring))
           (tasks-to-drain '())) ; Use a list to collect popped items

      ;; Only proceed if there are tasks to process.
      (when (> tasks-in-tick 0)
        ;; First, remove all current tasks from the queue. This is crucial.
        ;; It ensures that any new microtasks queued by the tasks we are
        ;; about to run will be processed in the *next* tick, not this one.
        (dotimes (_ tasks-in-tick)
          (push (ring-pop-front queue-ring) tasks-to-drain))
        (setq tasks-to-drain (nreverse tasks-to-drain)) ; Restore FIFO order

        ;; Increment tick counter *before* processing, as per spec.
        (cl-incf (concur-microtask-queue-current-tick concur--global-microtask-queue))
        (concur--log :debug "[MICROTASK] Draining %d microtasks for tick %d."
                     (length tasks-to-drain)
                     (concur-microtask-queue-current-tick concur--global-microtask-queue))

        ;; Process the collected tasks.
        (--each tasks-to-drain
                (lambda (cb)
                  ;; `concur-process-scheduled-callbacks-batch` is the shared
                  ;; function that knows how to execute a callback by `eval`ing
                  ;; its context and calling its handler.
                  (concur-process-scheduled-callbacks-batch
                   (concur-callback-promise cb) (list cb))))))))

(provide 'concur-microtask)
;;; concur-microtask.el ends here