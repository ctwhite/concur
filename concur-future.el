;;; concur-future.el --- Lazy Asynchronous Computations -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides primitives for working with "futures". A future
;; represents a deferred computation that is evaluated lazily, only when its
;; result is actually requested. This is useful for defining expensive or
;; asynchronous operations without paying the execution cost upfront.
;;
;; Futures are built on top of promises. When a future is "forced" (i.e., its
;; value is requested for the first time), it executes its deferred computation
;; and stores the result in an internal promise for all subsequent requests.
;;
;; Key Features:
;; - Lazy Evaluation: A future's computation is only run once, the first
;;   time its result is requested via `concur:force`.
;; - Thread-Safety: Forcing a future is an atomic, thread-safe operation.
;; - Seamless Integration: Futures are "thenable" and integrate transparently
;;   with the entire `concur` promise ecosystem.

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-future-error
  "A generic error related to a `concur-future`."
  'concur-error)

(define-error 'concur-invalid-future-error
  "An operation was attempted on an invalid future object."
  'concur-future-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-future (:constructor %%make-future))
  "A lazy future representing a deferred computation.

Fields:
- `promise` (concur-promise or nil): The cached promise, created on the first
  call to `concur:force`.
- `thunk` (function): A zero-argument closure that performs the computation.
- `evaluated-p` (boolean): A flag to ensure the thunk is only run once.
- `mode` (symbol): The concurrency mode for the promise created by this future.
- `lock` (concur-lock): A mutex ensuring that forcing is thread-safe."
  (promise nil :type (or null concur-promise-p))
  (thunk (lambda () (error "Empty future thunk")) :type function)
  (evaluated-p nil :type boolean)
  (mode :deferred :type (member :deferred :thread))
  (lock nil :type (or null concur-lock-p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-future (future function-name)
  "Signal an error if FUTURE is not a `concur-future`.

Arguments:
- `FUTURE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
  (unless (concur-future-p future)
    (signal 'concur-invalid-future-error
            (list (format "%s: Invalid future object" function-name) future))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Creation & Forcing

;;;###autoload
(cl-defmacro concur:make-future (thunk-form &key (mode :deferred))
  "Create a `concur-future` from a `THUNK-FORM`.
The returned future represents a computation that is performed lazily
when `concur:force` is called. The `THUNK-FORM` is captured as a
lexical closure, automatically preserving access to variables in its
surrounding scope.

Arguments:
- `THUNK-FORM` (form): A Lisp form that evaluates to a zero-argument function
  (typically a lambda) that performs the computation. Its return value can
  be a normal value or another awaitable (like a promise or future).
- `:MODE` (symbol, optional): The concurrency mode for the promise created
  when this future is forced. Defaults to `:deferred`.

Returns:
- (concur-future): A new `concur-future` object."
  (declare (indent 1) (debug t))
  `(let ((id (gensym "future-")))
     (concur--log :debug nil "Creating future %S in mode %S." id ,mode)
     (%%make-future
      :lock (concur:make-lock (format "future-lock-%S" id) :mode ,mode)
      :mode ,mode
      :thunk ,thunk-form)))

;;;###autoload
(defun concur:force (future)
  "Force `FUTURE`'s thunk to run if not already evaluated.
This function is idempotent and thread-safe. The first time it is called,
it executes the future's deferred computation. Subsequent calls return
the same cached promise without re-running the computation.

Arguments:
- `FUTURE` (concur-future): The future object to force.

Returns:
- (concur-promise): The promise associated with the future's result."
  (concur--validate-future future 'concur:force)
  ;; Fast path: If already evaluated, just return the cached promise.
  (when (concur-future-evaluated-p future)
    (return-from concur:force (concur-future-promise future)))

  (let (promise-to-return thunk-to-run)
    ;; The critical section is minimized to only handle the state transition.
    (concur:with-mutex! (concur-future-lock future)
      (if (concur-future-evaluated-p future)
          ;; Another thread evaluated it while we waited for the lock.
          (setq promise-to-return (concur-future-promise future))
        ;; We are the first to force this future.
        (setf (concur-future-evaluated-p future) t)
        (setq thunk-to-run (concur-future-thunk future))
        (setq promise-to-return
              (concur:make-promise :mode (concur-future-mode future)
                                   :name "future-promise"))
        (setf (concur-future-promise future) promise-to-return)))

    ;; If we got a thunk, we are responsible for running it outside the lock.
    (when thunk-to-run
      (concur--log :info nil "Forcing future - executing thunk for first time.")
      (condition-case err
          (let ((thunk-result (funcall thunk-to-run)))
            ;; The result can be another promise/future. `resolve` handles this.
            (concur:resolve promise-to-return thunk-result))
        (error
         (concur--log :error nil "Future thunk failed synchronously: %S" err)
         (concur:reject
          promise-to-return
          (concur:make-error :type :executor-error
                             :message (format "Future thunk failed: %S" err)
                             :cause err :promise promise-to-return)))))
    promise-to-return))

;;;###autoload
(defun concur:future-get (future &optional timeout)
  "Force `FUTURE` and get its result, blocking until available.
This function is synchronous and behaves identically to calling
`concur:await` on the future's underlying promise. Use with caution in
performance-sensitive or UI-related code.

Arguments:
- `FUTURE` (concur-future): The future whose result is needed.
- `TIMEOUT` (number, optional): Max seconds to wait before erroring.

Returns:
- (any): The resolved value of the future.

Signals:
- `concur-error` on rejection or timeout."
  (concur--validate-future future 'concur:future-get)
  (concur--log :info nil "Getting result for future (timeout: %S)." timeout)
  (concur:await (concur:force future) timeout))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Convenience Constructors

;;;###autoload
(cl-defun concur:future-resolved! (value &key (mode :deferred))
  "Return a new `concur-future` that is already resolved with `VALUE`.
This future is created in an 'already forced' state.

Arguments:
- `VALUE` (any): The value for the pre-resolved future.
- `:MODE` (symbol, optional): Concurrency mode for the future's promise.

Returns:
- (concur-future): A new, already-evaluated future."
  (let ((promise (concur:resolved! value :mode mode)))
    (concur--log :debug nil "Creating pre-resolved future with value %S." value)
    (%%make-future :promise promise :evaluated-p t :mode mode
                   :lock (concur:make-lock "future-resolved-lock" :mode mode))))

;;;###autoload
(cl-defun concur:future-rejected! (error &key (mode :deferred))
  "Return a new `concur-future` that is already rejected with `ERROR`.
This future is created in an 'already forced' state.

Arguments:
- `ERROR` (any): The error for the pre-rejected future.
- `:MODE` (symbol, optional): Concurrency mode for the future's promise.

Returns:
- (concur-future): A new, already-evaluated future."
  (let ((promise (concur:rejected! error :mode mode)))
    (concur--log :debug nil "Creating pre-rejected future with error %S." error)
    (%%make-future :promise promise :evaluated-p t :mode mode
                   :lock (concur:make-lock "future-rejected-lock" :mode mode))))

;;;###autoload
(cl-defun concur:future-delay (seconds &optional value &key (mode :deferred))
  "Create a `concur-future` that resolves with `VALUE` after `SECONDS`.
The timer starts only when the future is forced via `concur:force`.

Arguments:
- `SECONDS` (number): The non-negative delay duration.
- `VALUE` (any, optional): The value to resolve with. Defaults to `t`.
- `:MODE` (symbol, optional): The concurrency mode for the future's promise.

Returns:
- (concur-future): A new, lazy future."
  (unless (and (numberp seconds) (>= seconds 0))
    (error "SECONDS must be a non-negative number: %S" seconds))
  (concur:make-future (lambda () (concur:delay seconds value)) :mode mode))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Chaining & Composition

;;;###autoload
(defmacro concur:future-then (future transform-fn)
  "Apply `TRANSFORM-FN` to the result of a future, creating a new future.
The new future is also lazy. When it is forced, it will first force the
original `FUTURE`. Once the original future resolves, `TRANSFORM-FN` is
applied to its result.

Arguments:
- `FUTURE` (concur-future): The parent future.
- `TRANSFORM-FN` (form): A lambda `(lambda (value) ...)` or function symbol.

Returns:
- (concur-future): A new future representing the chained computation."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (concur--validate-future parent-future 'concur:future-then)
     (concur:make-future
      (lambda () (concur:then (concur:force parent-future) ,transform-fn))
      :mode (concur-future-mode parent-future))))

;;;###autoload
(defmacro concur:future-catch (future error-handler-fn)
  "Attach an error handler to a future, creating a new recoverable future.
The new future is lazy. When forced, it forces the original future and, if
it rejects, applies the `ERROR-HANDLER-FN`.

Arguments:
- `FUTURE` (concur-future): The parent future.
- `ERROR-HANDLER-FN` (form): A lambda `(lambda (error) ...)` or function symbol.

Returns:
- (concur-future): A new future that can handle the original's failure."
  (declare (indent 1) (debug t))
  `(let ((parent-future ,future))
     (concur--validate-future parent-future 'concur:future-catch)
     (concur:make-future
      (lambda () (concur:catch (concur:force parent-future) ,error-handler-fn))
      :mode (concur-future-mode parent-future))))

;;;###autoload
(defun concur:future-all (futures)
  "Create a future that, when forced, runs a list of `FUTURES` in parallel.

Arguments:
- `FUTURES` (list): A list of `concur-future` objects.

Returns:
- (concur-future): A new future that resolves with a list of all results."
  (unless (listp futures) (error "`FUTURES` must be a list: %S" futures))
  (concur:make-future
   (lambda ()
     (concur:all (mapcar #'concur:force futures)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun concur:future-status (future)
  "Return a snapshot of the `FUTURE`'s current status.

Arguments:
- `FUTURE` (concur-future): The future to inspect.

Returns:
- (plist): A property list with future metrics: `:evaluated-p`, `:mode`,
  `:promise-status`, `:promise-value`, and `:promise-error`.

Signals:
- `concur-invalid-future-error` if `FUTURE` is not a valid future."
  (concur--validate-future future 'concur:future-status)
  (let* ((promise (concur-future-promise future)))
    `(:evaluated-p ,(concur-future-evaluated-p future)
      :mode ,(concur-future-mode future)
      :promise-status ,(when promise (concur:status promise))
      :promise-value ,(when promise (concur:value promise))
      :promise-error ,(when promise (concur:error-value promise)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration

(defun concur--future-normalize-awaitable (awaitable)
  "Normalize an awaitable into a promise if it's a `concur-future`.
This function is added to `concur-normalize-awaitable-hook` to allow core
functions like `concur:await` to transparently accept futures."
  (if (concur-future-p awaitable) (concur:force awaitable) nil))

;; Plug the future into the core promise system, making them interchangeable.
(add-hook 'concur-normalize-awaitable-hook #'concur--future-normalize-awaitable)

(provide 'concur-future)
;;; concur-future.el ends here