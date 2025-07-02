;;; concur-event.el --- Event Synchronization Primitive for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `concur-event` primitive, a lightweight and
;; flexible tool for coordinating asynchronous tasks.
;;
;; An event is a synchronization flag that can be in one of two states:
;; "set" or "cleared". Tasks can wait for an event to become "set".
;; When a task calls `concur:event-set`, all current and future waiters
;; are woken up and their promises resolve with the value provided.
;;
;; This makes it useful for one-time signals, like "initialization is complete"
;; or "data is now available".

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-log)
(require 'concur-combinators) ; For concur:timeout

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-event-error
  "A generic error related to a `concur-event`."
  'concur-error)

(define-error 'concur-invalid-event-error
  "An operation was attempted on an invalid event object."
  'concur-event-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-event (:constructor %%make-event))
  "Represents a settable event for task coordination.

Fields:
- `name` (string): A descriptive name for debugging.
- `lock` (concur-lock): An internal mutex protecting the event's state.
- `is-set-p` (boolean): `t` if the event is currently in the 'set' state.
- `value` (any): The value to resolve waiting promises with when the event is set.
- `wait-queue` (concur-queue): A queue of promises for pending wait operations."
  (name "" :type string)
  (lock nil :type (or null concur-lock-p))
  (is-set-p nil :type boolean)
  (value t :type t)
  (wait-queue nil :type (or null concur-queue-p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-event (event function-name)
  "Signal an error if EVENT is not a `concur-event`.

Arguments:
- `EVENT` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
  (unless (concur-event-p event)
    (signal 'concur-invalid-event-error
            (list (format "%s: Invalid event object" function-name) event))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-event (&optional name)
  "Create a new event object, initially in the 'cleared' state.

Arguments:
- `NAME` (string, optional): A descriptive name for debugging.

Returns:
- `(concur-event)`: A new event object."
  (let* ((event-name (or name (format "event-%S" (gensym))))
         (lock (concur:make-lock (format "event-lock-%s" event-name)))
         (event (%%make-event :name event-name
                              :lock lock
                              :wait-queue (concur-queue-create))))
    (concur--log :debug event-name "Created event.")
    event))

;;;###autoload
(defun concur:event-is-set-p (event)
  "Return `t` if `EVENT` is currently in the 'set' state.

Arguments:
- `EVENT` (concur-event): The event to check.

Returns:
- (boolean): `t` if the event is set, `nil` otherwise."
  (concur--validate-event event 'concur:event-is-set-p)
  (concur-event-is-set-p event))

;;;###autoload
(defun concur:event-set (event &optional value)
  "Set `EVENT`, waking up all current and future waiters.
This operation is idempotent; setting an already-set event has no effect.
All waiting promises will resolve with `VALUE`.

Arguments:
- `EVENT` (concur-event): The event to set.
- `VALUE` (any, optional): The value to resolve waiters with. Defaults to `t`.

Returns:
- `nil`."
  (concur--validate-event event 'concur:event-set)
  (let (waiters-to-resolve resolve-value)
    (concur:with-mutex! (concur-event-lock event)
      (unless (concur-event-is-set-p event)
        (setf (concur-event-is-set-p event) t)
        (setf (concur-event-value event) (or value t))
        (setq waiters-to-resolve (concur-queue-drain (concur-event-wait-queue event)))
        (setq resolve-value (concur-event-value event))
        (concur--log :debug (concur-event-name event)
                     "Event set with value %S. Waking up %d waiters."
                     resolve-value (length waiters-to-resolve))))
    (dolist (promise waiters-to-resolve)
      (concur:resolve promise resolve-value))))

;;;###autoload
(defun concur:event-clear (event)
  "Clear `EVENT`, resetting it to the initial 'cleared' state.

Arguments:
- `EVENT` (concur-event): The event to clear.

Returns:
- `nil`."
  (concur--validate-event event 'concur:event-clear)
  (concur:with-mutex! (concur-event-lock event)
    (setf (concur-event-is-set-p event) nil)
    (setf (concur-event-value event) t) ; Reset value to default.
    (concur--log :debug (concur-event-name event) "Event cleared.")))

;;;###autoload
(cl-defun concur:event-wait (event &key timeout)
  "Return a promise that resolves when `EVENT` is set.
If the event is already set, the returned promise resolves immediately
with the event's stored value. Otherwise, the promise resolves when
`concur:event-set` is called.

Arguments:
- `EVENT` (concur-event): The event to wait for.
- `:TIMEOUT` (number, optional): Seconds to wait before rejecting with a
  `concur-timeout-error`.

Returns:
- `(concur-promise)`: A promise that resolves with the event's value."
  (concur--validate-event event 'concur:event-wait)
  (let (wait-promise)
    (concur:with-mutex! (concur-event-lock event)
      (if (concur-event-is-set-p event)
          (setq wait-promise (concur:resolved! (concur-event-value event)))
        (setq wait-promise (concur:make-promise :name "event-wait"))
        (concur--log :debug (concur-event-name event) "Task is waiting for event.")
        (concur:queue-enqueue (concur-event-wait-queue event) wait-promise)))
    (if timeout
        (concur:timeout wait-promise timeout)
      wait-promise)))

(provide 'concur-event)
;;; concur-event.el ends here