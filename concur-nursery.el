;;; concur-nursery.el --- Structured Concurrency with Nurseries -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides primitives for "structured concurrency" using a
;; "nursery" metaphor. It ensures that the lifecycle of concurrent tasks
;; is tied to a specific lexical scope, preventing "leaked" or orphaned
;; background operations.
;;
;; The core construct is the `concur:with-nursery` macro. Any asynchronous
;; tasks started within this macro's scope are managed by the nursery.
;; The `with-nursery` block will not exit until all tasks started within
;; it have completed. If any supervised task fails, all other tasks in the
;; nursery are cancelled, and the error is propagated.
;;
;; This module integrates with the promise registry, allowing nurseries
;; and their child tasks to be visualized for debugging.

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-cancel)
(require 'concur-async)
(require 'concur-combinators)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures & Errors

(define-error 'concur-nursery-error "Error in a concurrency nursery." 'concur-error)

(cl-defstruct (concur-nursery (:constructor %%make-concur-nursery))
  "Represents a nursery for managing a group of concurrent tasks.
Do not create this struct directly; use `concur:with-nursery`.

Fields:
- `name` (string): A descriptive name for debugging.
- `lock` (concur-lock): A mutex protecting the list of child promises.
- `child-promises` (list): A list of all promises for tasks started
  within this nursery.
- `cancel-token` (concur-cancel-token): A token shared by all tasks in
  the nursery. Cancelling this token cancels all child tasks.
- `master-promise` (concur-promise): A promise that settles only when
  the entire nursery has completed."
  (name "" :type string)
  (lock (concur:make-lock "nursery-lock" :mode :thread))
  (child-promises '() :type list)
  (cancel-token nil :type (or null (satisfies concur-cancel-token-p)))
  (master-promise nil :type (or null (satisfies concur-promise-p))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro concur:with-nursery (nursery-var &rest body)
  "Create a nursery and execute BODY within its supervised scope.
This macro creates a new nursery, binds it to NURSERY-VAR, and
executes the BODY forms. Any tasks started within the BODY using
`concur:nursery-start-soon` will be supervised by the nursery.

This block will cooperatively block and not exit until all tasks
started within it have completed. If any task fails, all other
tasks in the nursery will be cancelled, and the error will be
re-signaled from this macro.

Arguments:
- `NURSERY-VAR` (symbol): A variable that will be bound to the
  newly created `concur-nursery` object within the BODY.
- `BODY` (forms): The Lisp forms to execute.

Returns:
  The result of the `BODY` if all tasks succeed, or signals an error if
  the nursery fails."
  (declare (indent 1) (debug t))
  (let ((nursery-obj (gensym "nursery-obj-"))
        (master-promise (gensym "master-promise-")))
    `(let* ((,master-promise (concur:make-promise :name "nursery-master"))
            (,nursery-obj (%%make-concur-nursery
                           :name (format "nursery-%s" (random))
                           :master-promise ,master-promise
                           :cancel-token (concur:make-cancel-token))))
       ;; Register the master promise for introspection.
       (when (fboundp 'concur-register-promise)
         (concur-register-promise ,master-promise "Nursery Master"))
       ;; Bind the nursery variable and execute the user's code.
       (let ((,nursery-var ,nursery-obj))
         ,@body)

       ;; After the body has run, wait for all child tasks to settle.
       (concur:then
        (concur:all-settled (concur-nursery-child-promises ,nursery-obj))
        (lambda (results)
          ;; Once all tasks are done, check their outcomes.
          (if-let ((failure (-find-if (lambda (r) (eq (plist-get r :status)
                                                      'rejected))
                                     results)))
              ;; If any task failed, reject the nursery's master promise.
              (concur:reject ,master-promise (plist-get failure :reason))
            ;; If all tasks succeeded, resolve the master promise.
            (concur:resolve ,master-promise t))))

       ;; Block until the master promise settles. This is the core of
       ;; structured concurrency: the scope does not exit until all work is done.
       (concur:await ,master-promise))))

;;;###autoload
(cl-defun concur:nursery-start-soon (nursery fn &rest keys &key name mode)
  "Start a new asynchronous task `FN` within the scope of a `NURSERY`.
This function must be called from within the `body` of a
`concur:with-nursery` block. It uses `concur:async!` to run the
task in the background worker pool.

Arguments:
- `NURSERY` (concur-nursery): The nursery object from `with-nursery`.
- `FN` (function): The nullary function to execute as a task.
- `KEYS` (plist): Keyword arguments to pass to `concur:start!`, such
  as `:mode`, `:name`, etc.

Returns:
  (concur-promise) The promise for the newly started task."
  (unless (concur-nursery-p nursery)
    (error "First argument must be a nursery object"))
  (let* ((master-promise (concur-nursery-master-promise nursery))
         (task-promise
          (apply #'concur:start! fn
                 ;; Inject the nursery's shared cancellation token.
                 :cancel-token (concur-nursery-cancel-token nursery)
                 ;; Register this task as a child of the nursery's master promise.
                 :parent-promise master-promise
                 keys)))
    ;; If this specific task fails, trigger cancellation for the entire nursery.
    (concur:catch task-promise
                  (lambda (_err)
                    (concur:cancel-token-cancel!
                     (concur-nursery-cancel-token nursery))))
    ;; Add the promise to the nursery's list of children to track.
    (concur:with-mutex! (concur-nursery-lock nursery)
      (push task-promise (concur-nursery-child-promises nursery)))
    task-promise))

(provide 'concur-nursery)
;;; concur-nursery.el ends here