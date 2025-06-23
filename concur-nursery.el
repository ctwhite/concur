;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-nursery.el --- Structured Concurrency with Nurseries -*- lexical-binding: t; -*-

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

(require 'cl-lib)           ; For cl-defstruct, cl-loop, cl-incf, cl-decf
(require 'concur-core)      ; For `concur-promise` types, `concur:make-promise`,
                            ; `concur:resolved!`, `concur:reject`, `concur:status`,
                            ; `concur:error-value`, `concur:pending-p`, `concur:rejected-p`,
                            ; `concur:make-error`, `concur:await`, `concur--log`
(require 'concur-chain)     ; For `concur:then`, `concur:catch`, `concur:all-settled`
(require 'concur-cancel)    ; For `concur-cancel-token`, `concur:make-cancel-token`,
                            ; `concur:cancel-token-cancel!`, `concur:cancel-token-cancelled-p`
(require 'concur-async)     ; For `concur:start!`
(require 'concur-combinators) ; For `concur:all-settled` (used here for child promises)
(require 'concur-registry)  ; For `concur-registry-register-promise` (for introspection)
(require 'concur-lock)      ; For `concur-lock`, `concur:make-lock`, `concur:with-mutex!`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures & Errors

(define-error 'concur-nursery-error
  "A generic error occurred within a concurrency nursery."
  'concur-error)

(cl-defstruct (concur-nursery (:constructor %%make-concur-nursery))
  "Represents a nursery for managing a group of concurrent tasks.
Do not create this struct directly; use `concur:with-nursery`.

  Arguments:
  - `name` (string): A descriptive name for debugging the nursery. Defaults
    to \"\".
  - `lock` (concur-lock): A mutex protecting the list of child promises.
    Defaults to `nil` (initialized in `concur:with-nursery`).
  - `child-promises` (list): A list of all `concur-promise` objects for
    tasks started within this nursery. These are the supervised tasks.
    Defaults to `nil`.
  - `cancel-token` (concur-cancel-token): A shared `concur-cancel-token`
    that is automatically linked to all tasks started within this nursery.
    Cancelling this token cancels all child tasks. Defaults to `nil`.
  - `master-promise` (concur-promise): A promise that settles only when
    the entire nursery (all its child tasks) has completed. Defaults to `nil`."
  (name "" :type string)
  (lock nil :type (or null (satisfies concur-lock-p)))
  (child-promises nil :type list)
  (cancel-token nil :type (or null (satisfies concur-cancel-token-p)))
  (master-promise nil :type (or null (satisfies concur-promise-p))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(defmacro concur:with-nursery (nursery-var &rest body)
  "Create a nursery and execute BODY within its supervised scope.
This macro creates a new nursery, binds it to `NURSERY-VAR`, and
executes the `BODY` forms. Any tasks started within the `BODY` using
`concur:nursery-start-soon` or `concur:nursery-start-and-await` will
be supervised by this nursery.

This block will cooperatively block and not exit until all tasks
started within it have completed. If any supervised task fails, all
other tasks in the nursery will be cancelled (via the shared cancel
token), and the error from the first failing task will be propagated
from this macro.

  Arguments:
  - `NURSERY-VAR` (symbol): A variable that will be bound to the
    newly created `concur-nursery` object within the `BODY`.
  - `BODY` (forms): The Lisp forms to execute.

  Returns:
  - (any): The result of the `BODY` if all tasks succeed, or signals
    an error if the nursery fails (i.e., if its `master-promise` rejects)."
  (declare (indent 1) (debug t))
  (let ((nursery-obj (gensym "nursery-obj-"))
        (master-promise (gensym "nursery-master-promise-")))
    `(let* ((,master-promise (concur:make-promise :name "nursery-master"))
            (,nursery-obj (%%make-concur-nursery
                           :name (format "nursery-%S" (gensym))
                           :master-promise ,master-promise
                           :cancel-token (concur:make-cancel-token
                                          (format "nursery-cancel-%S" (gensym)))
                           :lock (concur:make-lock
                                  (format "nursery-lock-%S" (gensym))))))
       ;; Register the master promise for introspection.
       (when (fboundp 'concur-registry-register-promise)
         (concur-registry-register-promise ,master-promise "Nursery Master"
                                           :tags '(nursery)))
       (concur--log :info (concur-promise-id ,master-promise)
                    "Nursery '%S' created."
                    (concur-nursery-name ,nursery-obj))

       ;; Bind the nursery variable and execute the user's code.
       (let ((,nursery-var ,nursery-obj))
         (unwind-protect
             (progn ,@body)
           ;; Ensure all child promises are added to nursery before leaving scope.
           ;; If `body` itself throws, child promises might not be in the list yet.
           ;; For robust tracking, this should be done by `start-soon`.
           nil)) ; No specific cleanup needed here from unwind-protect

       ;; After the body has run (or thrown), wait for all child tasks to settle.
       ;; `concur:all-settled` collects results without rejecting.
       (concur:then
        (concur:all-settled (concur-nursery-child-promises ,nursery-obj))
        (lambda (results)
          (concur--log :debug (concur-promise-id ,master-promise)
                       "All nursery children settled. Checking outcomes.")
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
       (concur--log :debug (concur-promise-id ,master-promise)
                    "Nursery '%S' blocking until all children complete."
                    (concur-nursery-name ,nursery-obj))
       (concur:await ,master-promise))))

;;;###autoload
(cl-defun concur:nursery-start-soon (nursery fn &rest keys &key name mode)
  "Start a new asynchronous task `FN` within the scope of a `NURSERY`.
This function must be called from within the `body` of a
`concur:with-nursery` block. It uses `concur:start!` to run the
task in the background worker pool or deferred.

  Arguments:
  - `NURSERY` (concur-nursery): The nursery object from `concur:with-nursery`.
  - `FN` (function): The nullary function to execute as a task.
  - `KEYS` (plist): Keyword arguments to pass to `concur:start!`, such
    as `:mode`, `:name`, etc. These will override defaults.

  Returns:
  - (concur-promise): The promise for the newly started task, which is
    also supervised by the nursery."
  (unless (concur-nursery-p nursery)
    (user-error "concur:nursery-start-soon: First argument must be a nursery \
                 object: %S" nursery))
  (unless (functionp fn)
    (user-error "concur:nursery-start-soon: FN must be a function: %S" fn))
  (let* ((master-promise (concur-nursery-master-promise nursery))
         (task-promise
          (apply #'concur:start! fn
                 ;; Inject the nursery's shared cancellation token.
                 :cancel-token (concur-nursery-cancel-token nursery)
                 ;; Register this task as a child of the nursery's master promise.
                 :parent-promise master-promise
                 keys)))
    (concur--log :debug (concur-promise-id task-promise)
                 "Task '%S' started in nursery '%S'."
                 (or name (concur-promise-id task-promise))
                 (concur-nursery-name nursery))
    ;; If this specific task fails, trigger cancellation for the entire nursery.
    (concur:catch task-promise
                  (lambda (err)
                    (concur--log :warn (concur-promise-id task-promise)
                                 "Task '%S' failed in nursery '%S'. Cancelling nursery. Error: %S"
                                 (or name (concur-promise-id task-promise))
                                 (concur-nursery-name nursery) err)
                    (concur:cancel-token-cancel!
                     (concur-nursery-cancel-token nursery)
                     (format "Child task %S failed"
                             (or name (concur-promise-id task-promise))))))
    ;; Add the promise to the nursery's list of children to track.
    (concur:with-mutex! (concur-nursery-lock nursery)
      (push task-promise (concur-nursery-child-promises nursery)))
    task-promise))

;;;###autoload
(cl-defun concur:nursery-start-and-await (nursery fn &rest keys)
  "Start a new asynchronous task `FN` within a `NURSERY` and await its result.
This is a convenience function combining `concur:nursery-start-soon` and
`concur:await`. If the task fails, it will still trigger cancellation
of other tasks in the nursery and propagate the error.

  Arguments:
  - `NURSERY` (concur-nursery): The nursery object.
  - `FN` (function): The nullary function to execute as a task.
  - `KEYS` (plist): Keyword arguments to pass to `concur:start!`.

  Returns:
  - (any): The resolved value of `FN`'s promise.

  Signals:
  - An error if the task or nursery fails."
  (unless (concur-nursery-p nursery)
    (user-error "concur:nursery-start-and-await: First argument must be a \
                 nursery object: %S" nursery))
  (unless (functionp fn)
    (user-error "concur:nursery-start-and-await: FN must be a function: %S" fn))
  (concur--log :debug nil "Starting and awaiting task for nursery %S."
               (concur-nursery-name nursery))
  (concur:await (apply #'concur:nursery-start-soon nursery fn keys)))

;;;###autoload
(defun concur:nursery-status (nursery)
  "Return a snapshot of the `NURSERY`'s current status.

  Arguments:
  - `NURSERY` (concur-nursery): The nursery to inspect.

  Returns:
  - (plist): A property list with nursery metrics:
    `:name`: Name of the nursery.
    `:total-children`: Total tasks started in the nursery.
    `:pending-children`: Number of children still pending.
    `:resolved-children`: Number of children that have resolved.
    `:rejected-children`: Number of children that have rejected.
    `:is-cancelled-p`: Whether the nursery's cancel token is cancelled.
    `:master-promise-status`: Status of the nursery's master promise."
  (interactive)
  (unless (concur-nursery-p nursery)
    (user-error "concur:nursery-status: Invalid nursery object: %S" nursery))
  (concur:with-mutex! (concur-nursery-lock nursery)
    (let ((pending 0) (resolved 0) (rejected 0))
      (cl-loop for p in (concur-nursery-child-promises nursery) do
               (pcase (concur:status p)
                 (:pending (cl-incf pending))
                 (:resolved (cl-incf resolved))
                 (:rejected (cl-incf rejected))))
      `(:name ,(concur-nursery-name nursery)
        :total-children ,(+ pending resolved rejected)
        :pending-children ,pending
        :resolved-children ,resolved
        :rejected-children ,rejected
        :is-cancelled-p ,(concur:cancel-token-cancelled-p
                          (concur-nursery-cancel-token nursery))
        :master-promise-status ,(concur:status
                                 (concur-nursery-master-promise nursery))))))

(provide 'concur-nursery)
;;; concur-nursery.el ends here