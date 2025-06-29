;;; concur-nursery.el --- Structured Concurrency with Nurseries -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides primitives for "structured concurrency" using a
;; "nursery" metaphor. It ensures that the lifecycle of concurrent tasks
;; is tied to a specific lexical scope, preventing orphaned background operations.
;;
;; The core construct is the `concur:with-nursery` macro. Any asynchronous
;; task started within this macro's scope is managed by the nursery. The
;; `with-nursery` block is guaranteed to not exit until all of its child
;; tasks have completed, one way or another.
;;
;; Key Features:
;; - **Lifecycle Scoping**: Automatically waits for all child tasks to finish.
;; - **Error Propagation**: If any child task fails, all other tasks in the
;;   nursery are cancelled, and the original error is propagated.
;; - **Concurrency Limiting**: By providing a `:concurrency N` argument, the
;;   nursery will use an internal semaphore to ensure that no more than N
;;   tasks run simultaneously, which is essential for managing resources.

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-cancel)
(require 'concur-pool)
(require 'concur-semaphore)
(require 'concur-combinators)
(require 'concur-registry)
(require 'concur-lock)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Data Structures

(define-error 'concur-nursery-error
  "A generic error occurred within a concurrency nursery."
  'concur-error)

(define-error 'concur-invalid-nursery-error
  "An operation was attempted on an invalid nursery object."
  'concur-nursery-error)

(cl-defstruct (concur-nursery (:constructor %%make-nursery))
  "Represents a nursery for managing a group of concurrent tasks.
Do not create this struct directly; use `concur:with-nursery`.

Fields:
- `name` (string): A descriptive name for debugging.
- `lock` (concur-lock): A mutex protecting the list of child promises.
- `child-promises` (list): A list of promises for tasks in this nursery.
- `cancel-token` (concur-cancel-token): A token linked to all child tasks.
- `master-promise` (concur-promise): A promise that settles only when the
  entire nursery has completed.
- `semaphore` (concur-semaphore): Optional semaphore for concurrency limiting."
  name lock child-promises cancel-token master-promise semaphore)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-nursery (nursery function-name)
  "Signal an error if NURSERY is not a `concur-nursery`.

Arguments:
- `NURSERY` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
  (unless (concur-nursery-p nursery)
    (signal 'concur-invalid-nursery-error
            (list (format "%s: Invalid nursery object" function-name) nursery))))

(defun concur--nursery-await-completion (nursery body-result)
  "Wait for all nursery children to settle and finalize the master promise.

Arguments:
- `NURSERY` (concur-nursery): The nursery to finalize.
- `BODY-RESULT` (any): The result of the `with-nursery` body.

Returns:
- The `BODY-RESULT` if successful.

Signals:
- An error from the first failing child task."
  (let ((master-promise (concur-nursery-master-promise nursery)))
    (concur:then
     (concur:all-settled (concur-nursery-child-promises nursery))
     (lambda (results)
       (concur--log :debug (concur-promise-id master-promise)
                    "All nursery children settled. Checking outcomes.")
       (if-let ((failure (-find-if (lambda (r) (eq (plist-get r :status) 'rejected))
                                  results)))
           (concur:reject master-promise (plist-get failure :reason))
         (concur:resolve master-promise body-result))))
    (concur--log :debug (concur-promise-id master-promise)
                 "Nursery '%S' blocking until all children complete."
                 (concur-nursery-name nursery))
    (concur:await master-promise)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro concur:with-nursery ((nursery-var &key concurrency) &rest body)
  "Create a nursery and execute BODY within its supervised scope.
This macro creates a nursery, binds it to `NURSERY-VAR`, and executes
the `BODY` forms. The macro will cooperatively block and not exit
until all tasks started within it (`concur:nursery-start-soon`) have
completed. This provides a guarantee against orphaned background tasks.

If `CONCURRENCY` (a positive integer) is provided, the nursery will
ensure that no more than that many tasks run simultaneously.

If any supervised task fails, all other tasks in the nursery will be
cancelled, and the error will be propagated from this macro.

Arguments:
- `NURSERY-VAR` (symbol): A variable bound to the nursery object.
- `:CONCURRENCY` (integer, optional): The maximum number of concurrent tasks.
- `BODY` (forms): The Lisp forms to execute.

Returns:
- The result of the last form in `BODY` if all tasks succeed.

Signals:
- An error if any task in the nursery fails."
  (declare (indent 1) (debug t))
  (let ((nursery-obj (gensym "nursery-"))
        (body-result (gensym "body-result-")))
    `(let* ((nursery-name (format "nursery-%S" (gensym)))
            (,nursery-obj
             (%%make-nursery
              :name nursery-name
              :master-promise (concur:make-promise :name "nursery-master")
              :cancel-token (concur:make-cancel-token)
              :lock (concur:make-lock (format "nursery-lock-%S" nursery-name))
              :semaphore (when ,concurrency
                           (concur:make-semaphore
                            ,concurrency
                            (format "nursery-sem-%S" nursery-name))))))
       (concur--log :info (concur-nursery-name ,nursery-obj)
                    "Nursery created (concurrency: %s)."
                    (or ,concurrency "unlimited"))
       ;; Use unwind-protect to guarantee we wait for children, even if the
       ;; body throws a synchronous error.
       (unwind-protect
           (let ((,nursery-var ,nursery-obj))
             (setq ,body-result (progn ,@body)))
         (concur--nursery-await-completion ,nursery-obj ,body-result)))))

;;;###autoload
(cl-defun concur:nursery-start-soon (nursery fn &rest keys)
  "Start a new asynchronous task `FN` within a `NURSERY`.
This function must be called from within a `concur:with-nursery` block.
The task is executed on the default worker pool via `concur:pool-eval`.
If the nursery has a concurrency limit, this task may wait for a
free slot before executing.

Arguments:
- `NURSERY` (concur-nursery): The nursery object from `with-nursery`.
- `FN` (function): A nullary function `(lambda () ...)` to execute as a task.
- `KEYS` (plist): Keyword arguments passed to `concur:pool-eval`, such as
  `:vars` or `:priority`.

Returns:
- (concur-promise): The promise for the newly started task."
  (concur--validate-nursery nursery 'concur:nursery-start-soon)
  (unless (functionp fn) (error "FN must be a function: %S" fn))

  (let* ((master-promise (concur-nursery-master-promise nursery))
         (semaphore (concur-nursery-semaphore nursery))
         (task-fn (if semaphore
                      (lambda ()
                        (concur:with-semaphore! semaphore (funcall fn)))
                    fn))
         (task-promise
          (apply #'concur:pool-eval `(funcall ,task-fn)
                 :cancel-token (concur-nursery-cancel-token nursery)
                 keys)))

    (concur--log :debug (concur-promise-id task-promise)
                 "Task started in nursery '%S'." (concur-nursery-name nursery))

    ;; If this task fails, it triggers cancellation for the entire nursery.
    (concur:catch
     task-promise
     (lambda (err)
       (concur--log :warn (concur-promise-id task-promise)
                    "Task in nursery '%S' failed. Cancelling nursery. Error: %S"
                    (concur-nursery-name nursery) err)
       (concur:cancel-token-cancel (concur-nursery-cancel-token nursery))))

    (concur:with-mutex! (concur-nursery-lock nursery)
      (push task-promise (concur-nursery-child-promises nursery)))
    task-promise))

;;;###autoload
(defun concur:nursery-start-and-await (nursery fn &rest keys)
  "Start a new task `FN` within a `NURSERY` and await its result.
This is a convenience wrapper around `nursery-start-soon` and `concur:await`.

Arguments:
- `NURSERY` (concur-nursery): The nursery object.
- `FN` (function): The nullary function to execute as a task.
- `KEYS` (plist): Keyword arguments passed to `concur:nursery-start-soon`.

Returns:
- The resolved value of `FN`'s promise.

Signals:
- An error if the task or nursery fails."
  (concur--validate-nursery nursery 'concur:nursery-start-and-await)
  (concur:await (apply #'concur:nursery-start-soon nursery fn keys)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration

;; Nurseries are self-contained and don't need to hook into the core,
;; as they are a user-facing macro that builds upon other primitives.

(provide 'concur-nursery)
;;; concur-nursery.el ends here