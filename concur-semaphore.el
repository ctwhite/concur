;;; concur-semaphore.el --- Semaphore Primitive for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the `concur-semaphore` primitive, a counting
;; semaphore for controlling access to a finite number of resources. It is a
;; fundamental tool for limiting concurrency, for example, to control the
;; number of simultaneous network requests or CPU-intensive tasks.
;;
;; This implementation is fully integrated with the Concur ecosystem,
;; supporting timeouts and cooperative cancellation via cancel tokens. It uses
;; a fair (FIFO) queue for tasks waiting to acquire a slot.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'concur-core)
(require 'concur-lock)
(require 'concur-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-semaphore-error
  "A generic error related to a `concur-semaphore`."
  'concur-error)

(define-error 'concur-invalid-semaphore-error
  "An operation was attempted on an invalid semaphore object."
  'concur-semaphore-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-semaphore (:constructor %%make-semaphore))
  "A semaphore for controlling access to a finite number of resources.

Fields:
- `name` (string): A descriptive name for debugging.
- `lock` (concur-lock): An internal mutex protecting the semaphore's state.
- `count` (integer): The current number of available slots.
- `max-count` (integer): The maximum capacity of the semaphore.
- `wait-queue` (concur-queue): A FIFO queue of promises for pending
  acquisition requests."
  (name "" :type string)
  (lock nil :type (or null concur-lock-p))
  (count 0 :type integer)
  (max-count 0 :type integer)
  (wait-queue nil :type (or null concur-queue-p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-semaphore (sem function-name)
  "Signal an error if SEM is not a `concur-semaphore`.

Arguments:
- `SEM` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
  (unless (eq (type-of sem) 'concur-semaphore)
    (signal 'concur-invalid-semaphore-error
            (list (format "%s: Invalid semaphore object" function-name) sem))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-semaphore (n &optional name)
  "Create a semaphore with N available slots.

Arguments:
- `N` (integer): The initial (and maximum) number of available slots. Must
  be a non-negative integer.
- `NAME` (string, optional): A descriptive name for debugging.

Returns:
- (concur-semaphore): A new semaphore object."
  (unless (and (integerp n) (>= n 0))
    (error "Semaphore count must be a non-negative integer: %S" n))
  (let* ((sem-name (or name (format "sem-%S" (gensym))))
         (sem-lock (concur:make-lock (format "sem-lock-%s" sem-name))))
    (concur--log :debug sem-name "Creating semaphore with %d slots." n)
    (%%make-semaphore :count n :max-count n :name sem-name
                      :lock sem-lock :wait-queue (concur-queue-create))))

;;;###autoload
(defun concur:semaphore-try-acquire (sem)
  "Attempt to acquire a slot from `SEM` without blocking.

Arguments:
- `SEM` (concur-semaphore): The semaphore to acquire from.

Returns:
- (boolean): `t` if a slot was acquired, `nil` otherwise.

Signals:
- `concur-invalid-semaphore-error` if `SEM` is not a valid semaphore."
  (concur--validate-semaphore sem 'concur:semaphore-try-acquire)
  (let (acquired-p)
    (concur:with-mutex! (concur-semaphore-lock sem)
      (when (> (concur-semaphore-count sem) 0)
        (cl-decf (concur-semaphore-count sem))
        (setq acquired-p t)))
    (when acquired-p
      (concur--log :debug (concur-semaphore-name sem)
                   "Acquired slot via try-acquire. Count: %d."
                   (concur-semaphore-count sem)))
    acquired-p))

;;;###autoload
(cl-defun concur:semaphore-acquire (sem &key timeout cancel-token)
  "Acquire a slot from `SEM`, returning a promise for the operation.
If a slot is not immediately available, this function returns a pending
promise that resolves when a slot is acquired.

Arguments:
- `SEM` (concur-semaphore): The semaphore to acquire from.
- `:TIMEOUT` (number, optional): Max seconds to wait for acquisition before
  the returned promise rejects with a `concur-timeout-error`.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel the
  pending acquisition.

Returns:
- (concur-promise): A promise that resolves to `t` on success.

Signals:
- `concur-invalid-semaphore-error` if `SEM` is not a valid semaphore."
  (concur--validate-semaphore sem 'concur:semaphore-acquire)
  (let (acquire-promise)
    (concur:with-mutex! (concur-semaphore-lock sem)
      (if (> (concur-semaphore-count sem) 0)
          ;; Slot is available immediately.
          (progn
            (cl-decf (concur-semaphore-count sem))
            (concur--log :debug (concur-semaphore-name sem)
                         "Acquired slot immediately. Count: %d."
                         (concur-semaphore-count sem))
            (setq acquire-promise (concur:resolved! t)))
        ;; Slot is not available, queue a waiter promise.
        (setq acquire-promise (concur:make-promise :cancel-token cancel-token))
        (concur-queue-enqueue (concur-semaphore-wait-queue sem) acquire-promise)
        (concur--log :debug (concur-semaphore-name sem)
                     "Queued for acquisition. Queue length: %d."
                     (concur-queue-length (concur-semaphore-wait-queue sem)))
        ;; If cancelled, remove promise from the wait queue.
        (when cancel-token
          (concur:cancel-token-add-callback
           cancel-token
           (lambda ()
             (concur:with-mutex! (concur-semaphore-lock sem)
               (concur-queue-remove (concur-semaphore-wait-queue sem)
                                    acquire-promise)))))))
    (if timeout (concur:timeout acquire-promise timeout) acquire-promise)))

;;;###autoload
(defun concur:semaphore-release (sem)
  "Release one slot in `SEM`.
Increments the semaphore count and notifies the next waiting task, if any.

Arguments:
- `SEM` (concur-semaphore): The semaphore to release.

Returns:
- `nil`.

Signals:
- `concur-invalid-semaphore-error` if `SEM` is not a valid semaphore.
- `error` if the semaphore is already at maximum capacity."
  (concur--validate-semaphore sem 'concur:semaphore-release)
  (let (waiter-promise)
    (concur:with-mutex! (concur-semaphore-lock sem)
      (if (>= (concur-semaphore-count sem) (concur-semaphore-max-count sem))
          (error "Cannot release semaphore '%s': at max capacity (%d)"
                 (concur-semaphore-name sem)
                 (concur-semaphore-max-count sem))
        (setq waiter-promise (concur-queue-dequeue
                              (concur-semaphore-wait-queue sem)))
        (unless waiter-promise
          (cl-incf (concur-semaphore-count sem)))
        (concur--log :debug (concur-semaphore-name sem)
                     "Released slot. Count: %d."
                     (concur-semaphore-count sem))))
    ;; Resolve the waiter's promise outside the lock.
    (when waiter-promise (concur:resolve waiter-promise t))))

;;;###autoload
(defmacro concur:with-semaphore! (sem-obj &rest body)
  "Execute BODY after acquiring a slot from `SEM-OBJ`.
This macro ensures the acquired slot is always released, even if an
error occurs within `BODY`.

Arguments:
- `SEM-OBJ` (concur-semaphore): The semaphore to acquire a slot from.
- `BODY` (forms): The forms to execute after acquiring the semaphore.

Returns:
- `(concur-promise)`: A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  `(concur:then (concur:semaphore-acquire ,sem-obj)
                (lambda (_)
                  (unwind-protect
                      (progn ,@body)
                    (concur:semaphore-release ,sem-obj)))))

;;;###autoload
(defun concur:semaphore-get-count (sem)
  "Return the current number of available slots in `SEM`. Non-blocking.

Arguments:
- `SEM` (concur-semaphore): The semaphore to inspect.

Returns:
- `(integer)`: The number of available slots.

Signals:
- `concur-invalid-semaphore-error` if `SEM` is not a valid semaphore."
  (concur--validate-semaphore sem 'concur:semaphore-get-count)
  (concur-semaphore-count sem))

;;;###autoload
(defun concur:semaphore-status (sem)
  "Return a snapshot of the `SEM`'s current status.

Arguments:
- `SEM` (concur-semaphore): The semaphore to inspect.

Returns:
- (plist): A property list with semaphore metrics.

Signals:
- `concur-invalid-semaphore-error` if `SEM` is not a valid semaphore."
  (interactive)
  (concur--validate-semaphore sem 'concur:semaphore-status)
  (concur:with-mutex! (concur-semaphore-lock sem)
    `(:name ,(concur-semaphore-name sem)
      :count ,(concur-semaphore-count sem)
      :max-count ,(concur-semaphore-max-count sem)
      :pending-acquirers ,(concur-queue-length
                           (concur-semaphore-wait-queue sem)))))

(provide 'concur-semaphore)
;;; concur-semaphore.el ends here