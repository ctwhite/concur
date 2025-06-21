;;; concur-semaphore.el --- Semaphore Primitive for Concur -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This module provides the `concur-semaphore` primitive, a counting
;; semaphore for controlling access to a finite number of resources.
;; It supports both cooperative (`:deferred`, `:async`) and thread-blocking
;; (`:thread`) acquisition, integrating with the `concur-lock` and `concur-core`
;; modules for internal synchronization and asynchronous operation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'concur-core) ; For promises, executors, and errors
(require 'concur-lock) ; For concur-lock and concur:with-mutex!

;; Ensure native Emacs thread functions are loaded if available.
(when (fboundp 'make-thread) (require 'thread))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Semaphore Primitive

(eval-and-compile
  (cl-defstruct (concur-semaphore (:constructor %%make-semaphore))
    "A semaphore for controlling access to a finite number of resources.
Its behavior depends on the `mode` of its internal lock.

Fields:
- `count` (integer): The current number of available slots.
- `max-count` (integer): The maximum capacity of the semaphore.
- `lock` (concur-lock): The internal mutex protecting the semaphore's state.
- `wait-queue` (list): A queue of waiting `(resolve . reject)` functions for
  cooperative modes.
- `cond-var` (condition-variable or nil): The condition variable used for
  waiting/notifying in `:thread` mode."
    (count 0 :type integer)
    (max-count 0 :type integer)
    (lock nil :type (or null (satisfies concur-lock-p)))
    (wait-queue '() :type list)
    (cond-var nil :type (or null (if (fboundp 'condition-variable-p)
                                     (satisfies condition-variable-p)
                                   'any)))))

;;;###autoload
(cl-defun concur:make-semaphore (n &optional name &key (mode :deferred))
  "Create a semaphore with N available slots.
The semaphore's internal lock `mode` determines its blocking behavior.

Arguments:
- `N` (integer): The initial (and maximum) number of available slots.
- `NAME` (string, optional): A descriptive name for debugging.
- `:MODE` (symbol, optional): The semaphore's internal lock mode.
  Can be `:deferred`, `:async` (cooperative), or `:thread` (blocking).

Returns:
  (concur-semaphore) A new semaphore object."
  (unless (and (integerp n) (>= n 0))
    (error "Semaphore count must be a non-negative integer: %S" n))
  (let* ((sem-name (or name (format "sem-%s" (sxhash (current-time)))))
         (sem-lock (concur:make-lock (format "sem-lock-%s" sem-name) :mode mode)))
    (pcase mode
      (:thread
       (unless (fboundp 'make-thread)
         (error "Cannot create :thread mode semaphore without thread support."))
       (%%make-semaphore
        :count n :max-count n :name sem-name :lock sem-lock
        :cond-var (make-condition-variable (concur-lock-native-mutex sem-lock))))
      ((or :async :deferred)
       (%%make-semaphore
        :count n :max-count n :name sem-name :lock sem-lock)))))

;;;###autoload
(defun concur:semaphore-try-acquire (sem)
  "Try to acquire SEM without blocking.
If successful, decrements the semaphore count and returns `t`.

Arguments:
- `SEM` (concur-semaphore): The semaphore to acquire.

Returns:
  (boolean) `t` if a slot was acquired, `nil` otherwise."
  (unless (concur-semaphore-p sem) (error "Not a valid semaphore: %S" sem))
  (let ((acquired-p nil))
    (concur:with-mutex! (concur-semaphore-lock sem)
      (when (> (concur-semaphore-count sem) 0)
        (cl-decf (concur-semaphore-count sem))
        (setq acquired-p t)))
    (when (and acquired-p (fboundp 'concur-resource-tracking-function)
               concur-resource-tracking-function)
      (funcall concur-resource-tracking-function :acquire sem))
    acquired-p))

;;;###autoload
(defun concur:semaphore-release (sem)
  "Release one slot in SEM.
Increments the semaphore count and notifies a waiting acquirer if any exists.

Arguments:
- `SEM` (concur-semaphore): The semaphore to release.

Returns:
  nil."
  (unless (concur-semaphore-p sem) (error "Not a valid semaphore: %S" sem))
  (when (and (fboundp 'concur-resource-tracking-function)
             concur-resource-tracking-function)
    (funcall concur-resource-tracking-function :release sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
    (if (>= (concur-semaphore-count sem) (concur-semaphore-max-count sem))
        (error "Cannot release semaphore '%s': already at max capacity (%d)"
               (concur-semaphore-name sem) (concur-semaphore-max-count sem))
      (cl-incf (concur-semaphore-count sem))
      ;; After incrementing, check if anyone is waiting.
      (pcase (concur-lock-mode (concur-semaphore-lock sem))
        (:thread
         (condition-notify (concur-semaphore-cond-var sem)))
        (_ ; :deferred or :async
         (when-let ((waiter (pop (concur-semaphore-wait-queue sem))))
           ;; Asynchronously resolve the waiter's promise.
           (run-at-time 0 nil (car waiter))))))))

;;;###autoload
(cl-defun concur:semaphore-acquire (sem &key timeout)
  "Acquire a slot from SEM, returning a promise for the operation.
The returned promise resolves with `t` on successful acquisition or rejects
with a `concur:timeout-error` on timeout.

Arguments:
- `SEM` (concur-semaphore): The semaphore to acquire.
- `:TIMEOUT` (number, optional): Max seconds to wait for acquisition.

Returns:
  (concur-promise) A promise for the acquisition."
  (unless (concur-semaphore-p sem) (error "Not a valid semaphore: %S" sem))
  (let ((mode (concur-lock-mode (concur-semaphore-lock sem))))
    (concur:with-executor (lambda (resolve reject)
      (let ((acquired nil)
            (timer nil)
            (acquirer
             (lambda ()
               (when timer (cancel-timer timer))
               (funcall resolve t))))
        ;; Set up timeout if requested.
        (when timeout
          (setq timer
                (run-at-time
                 timeout nil
                 (lambda ()
                   (concur:with-mutex! (concur-semaphore-lock sem)
                     (setf (concur-semaphore-wait-queue sem)
                           (cl-delete (cons resolve reject)
                                      (concur-semaphore-wait-queue sem)
                                      :test #'equal)))
                   (funcall reject (concur:make-error :type :timeout))))))
        ;; Attempt to acquire immediately.
        (concur:with-mutex! (concur-semaphore-lock sem)
          (if (> (concur-semaphore-count sem) 0)
              (progn (cl-decf (concur-semaphore-count sem)) (setq acquired t))
            ;; If not available, queue the acquirer.
            (pcase mode
              (:thread
               ;; For thread mode, we must wait outside the initial lock.
               ;; The `acquirer` will be called after the wait.
               (setf (concur-semaphore-wait-queue sem)
                     (append (concur-semaphore-wait-queue sem)
                             (list (cons resolve reject)))))
              (_
               (setf (concur-semaphore-wait-queue sem)
                     (append (concur-semaphore-wait-queue sem)
                             (list acquirer)))))))
        (cond
         (acquired (funcall acquirer))
         ((eq mode :thread)
          ;; Wait on the condition variable.
          (concur:with-mutex! (concur-semaphore-lock sem)
            (while (zerop (concur-semaphore-count sem))
              (condition-wait (concur-semaphore-cond-var sem)))
            (cl-decf (concur-semaphore-count sem))
            (funcall acquirer)))))))
     :mode mode)))

;;;###autoload
(defmacro concur:with-semaphore! (sem-obj &rest body)
  "Execute BODY after acquiring a slot from SEM-OBJ.
Ensures the acquired slot is released upon successful completion of BODY
or if an error occurs within BODY.

Arguments:
- `SEM-OBJ`: The semaphore object.
- `BODY`: The forms to execute after acquiring the semaphore. The first
  form can optionally be an `:else` clause `(:else <fallback-forms...>)`
  to execute on timeout.

Returns:
  (concur-promise) A promise that resolves with the result of the body
  or rejects with the timeout error or any error from the body."
  (declare (indent 1) (debug t))
  (let* ((fallback-forms '((concur:rejected!
                            (concur:make-error
                             :type :timeout
                             :message "Semaphore acquisition timed out."))))
         (main-body body))
    (when (and (consp (car body)) (eq (caar body) :else))
      (setq fallback-forms (cdar body))
      (setq main-body (cdr body)))
    `(concur:chain (concur:semaphore-acquire ,sem-obj)
       (:then (lambda (_)
                (unwind-protect (progn ,@main-body)
                  (concur:semaphore-release ,sem-obj))))
       (:catch (lambda (err)
                 ,@fallback-forms)))))

(provide 'concur-semaphore)
;;; concur-semaphore.el ends here