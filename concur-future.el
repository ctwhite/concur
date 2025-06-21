;;; concur-future.el --- Concurrency primitives for lazy async tasks -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides primitives for working with "futures". A future
;; represents a deferred computation that is evaluated lazily only when its
;; result is needed. This is useful for defining expensive or asynchronous
;; operations without paying the cost until the result is actually requested.
;;
;; Futures use promises internally to manage the asynchronous result once the
;; computation is "forced" (i.e., executed).
;;
;; Key Features:
;; - Lazy Evaluation: A future's computation (its "thunk") is only run
;;   the first time its result is requested via `concur:force`.
;; - Thread-Safety: Forcing a future is an atomic, thread-safe operation.
;; - Concurrency Mode Propagation: Futures store a concurrency `mode` that is
;;   passed to their internal promise when forced, ensuring correct synchronization.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-ast)
(require 'concur-core)
(require 'concur-chain)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:all "concur-combinators" (promises-list &key mode))
(declare-function concur:race "concur-combinators" (promises-list &key mode))
(declare-function concur:delay "concur-combinators" (seconds &optional value))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (concur-future (:constructor %%make-future))
  "A lazy future represents a deferred computation.
Do not construct directly; use `concur:make-future`.

Fields:
- `promise` (concur-promise): The cached promise, created on demand when
  the future is first forced. It holds the result of the thunk.
- `thunk` (function): A zero-argument function that performs the computation.
- `evaluated-p` (boolean): A flag to ensure the thunk is only ever run once.
- `mode` (symbol): The concurrency mode for the promise created by this future.
- `lock` (concur-lock): A mutex to ensure that forcing the future is a
  thread-safe, atomic operation."
  (promise nil :type (or null (satisfies concur-promise-p)))
  (thunk (lambda () (error "Empty future thunk")) :type function)
  (evaluated-p nil :type boolean)
  (mode :deferred :type (member :deferred :thread :async))
  (lock (concur:make-lock "future-lock") :type (satisfies concur-lock-p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Future Creation & Forcing

;;;###autoload
(cl-defmacro concur:make-future (thunk-form &key (mode :deferred) &environment env)
  "Create a `concur-future` from THUNK-FORM.
The returned future represents a computation that is performed lazily when
`concur:force` is called. Lexical variables from the surrounding scope
are automatically captured via AST analysis.

Arguments:
- `THUNK-FORM` (form): A zero-argument lambda `(lambda () ...)`
  that performs the computation. Its return value can be a normal
  value or another awaitable (like a promise or another future).
- `:MODE` (symbol, optional): The concurrency mode for the promise created
  when this future is forced. Defaults to `:deferred`.

Returns:
  (concur-future) A new `concur-future` object."
  (declare (indent 1) (debug t))
  (let* ((analysis (concur-ast-analysis thunk-form env))
         (thunk (concur-ast-analysis-result-expanded-callable-form analysis))
         (free-vars (concur-ast-analysis-result-free-vars-list analysis))
         (context-form (concur-ast-make-captured-vars-form free-vars)))
    ;; The outer `let` captures the `context` when the future is created.
    `(let ((context ,context-form))
       (%%make-future
        :mode ,mode
        :lock (concur:make-lock "future-lock" :mode ,mode)
        :thunk (lambda ()
                 ;; When the thunk finally executes, it unpacks the captured
                 ;; variable values into its own lexical environment.
                 (let ,(cl-loop for var in free-vars
                                collect `(,var (gethash ',var context)))
                   (funcall ,thunk)))))))

;;;###autoload
(defun concur:force (future)
  "Force FUTURE's thunk to run if not already evaluated.
This function is idempotent and thread-safe. The first time it is called on
a future, it executes the future's deferred computation (`thunk`). Subsequent
calls will return the same cached promise without re-running the thunk.

Arguments:
- `FUTURE` (concur-future): The future object to force.

Returns:
  (concur-promise) The promise associated with the future's result."
  (unless (concur-future-p future)
    (error "Invalid future object to concur:force: %S" future))

  ;; The entire forcing operation is atomic to prevent race conditions
  ;; where two threads could try to evaluate the same future simultaneously.
  (concur:with-mutex! (concur-future-lock future)
    (if (concur-future-evaluated-p future)
        (concur-future-promise future)
      ;; Mark as evaluated immediately inside the lock to prevent re-entrancy.
      (setf (concur-future-evaluated-p future) t)
      ;; Create and store the promise that will hold the future's result.
      (let ((promise (concur:make-promise :mode (concur-future-mode future))))
        (setf (concur-future-promise future) promise)
        (condition-case err
            (let ((thunk-result (funcall (concur-future-thunk future))))
              ;; The result of the thunk might itself be a promise or another
              ;; future. `chain-or-settle` handles this correctly.
              (concur-chain-or-settle-promise promise thunk-result))
          (error
           ;; If the thunk signals a synchronous error, reject our promise.
           (concur:reject promise err)))
        promise))))

;;;###autoload
(defun concur:future-get (future &optional timeout)
  "Force FUTURE and get its result, blocking cooperatively until available.
This function is synchronous and behaves identically to `concur:await` on
the future's underlying promise. Use with caution in performance-sensitive
or UI-related code.

Arguments:
- `FUTURE` (concur-future): The future whose result is needed.
- `TIMEOUT` (number, optional): Max seconds to wait before erroring.

Returns:
  (any) The resolved value of the future. Signals an error on
  rejection or timeout."
  (concur:await (concur:force future) timeout))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Future Creation (Pre-settled & Delayed)

;;;###autoload
(cl-defun concur:future-resolved! (value &key (mode :deferred))
  "Return a new `concur-future` that is already resolved with VALUE.

Arguments:
- `VALUE` (any): The value for the pre-resolved future.
- `:MODE` (symbol, optional): Concurrency mode for the future's internal promise.

Returns:
  (concur-future) A new, already-evaluated future."
  (let ((promise (concur:resolved! value :mode mode)))
    (%%make-future :promise promise :evaluated-p t :mode mode)))

;;;###autoload
(cl-defun concur:future-rejected! (error &key (mode :deferred))
  "Return a new `concur-future` that is already rejected with ERROR.

Arguments:
- `ERROR` (any): The error for the pre-rejected future.
- `:MODE` (symbol, optional): Concurrency mode for the future's internal promise.

Returns:
  (concur-future) A new, already-evaluated future."
  (let ((promise (concur:rejected! error :mode mode)))
    (%%make-future :promise promise :evaluated-p t :mode mode)))

;;;###autoload
(cl-defun concur:future-delay (seconds &optional value &key (mode :deferred))
  "Create a `concur-future` that resolves with VALUE after SECONDS.
The timer starts only when the future is forced.

Arguments:
- `SECONDS` (number): The delay duration.
- `VALUE` (any, optional): The value to resolve with. Defaults to `t`.
- `:MODE` (symbol, optional): The concurrency mode for the future's promise.

Returns:
  (concur-future) A new, lazy future."
  (concur:make-future (lambda () (concur:delay seconds value)) :mode mode))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Future Chaining & Composition

;;;###autoload
(cl-defmacro concur:future-then (future transform-fn &environment env)
  "Apply `TRANSFORM-FN` to the result of a future, creating a new future.
The new future is also lazy. When it is forced, it will first force the
original `FUTURE`. Once the original future resolves, `TRANSFORM-FN` is
applied to its result to produce the new future's result.

Arguments:
- `FUTURE` (concur-future): The parent future.
- `TRANSFORM-FN` (form): A lambda `(lambda (value) ...)` or function symbol.

Returns:
  (concur-future) A new future representing the chained computation."
  (declare (indent 1) (debug t))
  `(concur:make-future
    (lambda ()
      (concur:then (concur:force ,future) ,transform-fn))
    :mode (concur-future-mode ,future)))

;;;###autoload
(cl-defmacro concur:future-catch (future error-handler-fn &environment env)
"Attach an error handler to a future, creating a new recoverable future.
The new future is lazy. When forced, it forces the original future and, if
it rejects, applies the `ERROR-HANDLER-FN`.

Arguments:
- `FUTURE` (concur-future): The parent future.
- `ERROR-HANDLER-FN` (form): A lambda `(lambda (error) ...)` or function symbol.

Returns:
- (concur-future) A new future that can handle the original's failure."
  (declare (indent 1) (debug t))
  `(concur:make-future
    (lambda ()
      (concur:catch (concur:force ,future) ,error-handler-fn))
    :mode (concur-future-mode ,future)))

;;;###autoload
(cl-defun concur:future-all (futures)
  "Create a future that, when forced, runs a list of FUTURES in parallel.
The resulting promise propagates the strongest concurrency mode from the
individual futures.

Arguments:
- `FUTURES` (list): A list of `concur-future` objects.

Returns:
  (concur-future) A new future that will resolve with a list of all results."
  (concur:make-future
   (lambda ()
     (let* ((promises (--map (concur:force it) futures))
            (strongest-mode (concur-determine-strongest-mode promises)))
       (concur:all promises :mode strongest-mode)))))

;;;###autoload
(cl-defun concur:future-race (futures)
  "Create a future that, when forced, races a list of FUTURES.
The resulting promise propagates the strongest concurrency mode from the
individual futures.

Arguments:
- `FUTURES` (list): A list of `concur-future` objects.

Returns:
  (concur-future) A new future that will settle with the first future to settle."
  (concur:make-future
   (lambda ()
     (let* ((promises (--map (concur:force it) futures))
            (strongest-mode (concur-determine-strongest-mode promises)))
       (concur:race promises :mode strongest-mode)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration

(defun concur--future-normalize-awaitable (awaitable)
  "Normalize an awaitable into a promise if it's a `concur-future`.
This function is added to `concur-normalize-awaitable-hook` to allow core
functions like `concur:then` to transparently accept futures."
  (if (concur-future-p awaitable)
      (concur:force awaitable)
    nil))

;; Plug into the core promise system.
(add-hook 'concur-normalize-awaitable-hook #'concur--future-normalize-awaitable)

(provide 'concur-future)
;;; concur-future.el ends here