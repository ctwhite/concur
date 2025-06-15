;;; concur-future.el --- Concurrency primitives for lazy asynchronous tasks -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides primitives for working with "futures" in Emacs Lisp.
;;
;; Futures represent the result of a computation that may not have completed
;; yet. They are a key concept in asynchronous programming, allowing you to
;; define a long-running task and defer its execution until the result is
;; actually needed.
;;
;; Key Concepts:
;;
;; - Future: A `concur-future` object represents a deferred computation.
;;   It holds a "thunk" (a zero-argument function) that is evaluated only
;;   when the future's value is requested.
;;
;; - Lazy Evaluation: Futures are evaluated lazily. The computation is not
;;   performed when `concur:make-future` is called, but only when the future
;;   is "forced" via `concur:force` or `concur:future-get`.
;;
;; - Promises: Futures use promises (`concur-promise`) internally to manage the
;;   asynchronous result. Forcing a future returns its underlying promise.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-promise)
(require 'concur-hooks)

;; Forward declarations to satisfy the byte-compiler.
(declare-function yield--internal-throw-form "" '(value tag))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (concur-future (:constructor %%make-future))
  "A lazy future represents a deferred computation.
Do not construct directly; use `concur:make-future`.

Fields:
- `promise` (`concur-promise`): The cached promise, created on demand when
  the future is first forced.
- `thunk` (function): A zero-argument function that performs the computation.
- `evaluated?` (boolean): `t` if the thunk has already been executed."
  promise
  thunk
  evaluated?)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-future (thunk)
  "Create a `concur-future` from a zero-argument function THUNK.
The returned future represents a computation that is performed lazily when
`concur:force` is called. When forced, THUNK is executed. If it returns a
value, the future's internal promise resolves with it. If it signals an
error, the promise rejects.

Arguments:
- THUNK (function): A zero-argument function that performs the computation.

Returns:
A new `concur-future` object."
  (unless (functionp thunk)
    (error "Argument THUNK must be a function"))
  (%%make-future :thunk thunk))

;;;###autoload
(defun concur:force (future)
  "Force FUTURE's thunk to run if not already evaluated.
This function is idempotent; calling it multiple times on the same future will
only run the thunk once. It correctly handles thunks that may themselves
return a `concur-promise`.

Arguments:
- FUTURE (`concur-future`): The future object to force.

Returns:
The `concur-promise` associated with the future."
  (when (concur-future-p future)
    (unless (concur-future-evaluated? future)
      (setf (concur-future-evaluated? future) t)
      (let ((outer-promise (concur:make-promise)))
        (setf (concur-future-promise future) outer-promise)
        ;; Run the thunk inside a condition-case to catch immediate errors.
        (condition-case err
            (let ((thunk-result (funcall (concur-future-thunk future))))
              (if (concur-promise-p thunk-result)
                  ;; If the thunk returned a promise, chain our outer promise to it.
                  (concur:then thunk-result
                               (lambda (val) (concur:resolve outer-promise val))
                               (lambda (e) (concur:reject outer-promise e)))
                ;; If it returned a plain value, resolve immediately.
                (concur:resolve outer-promise thunk-result)))
          ;; If calling the thunk itself throws a sync error, reject the promise.
          (error
           (concur:reject outer-promise err)))))
    (concur-future-promise future)))

;;;###autoload
(defun concur:future-get (future &optional timeout)
  "Force FUTURE and get its result, blocking cooperatively until available.
This function is synchronous and will block the Emacs UI until the future's
promise settles or the `TIMEOUT` is reached. It behaves identically to
`concur:await`. **Use with caution in interactive code.**

Arguments:
- FUTURE (`concur-future`): The future to get the result from.
- TIMEOUT (float, optional): Maximum seconds to wait.

Returns:
The resolved value of the future's promise.

Errors:
- Signals a `concur:timeout-error` if the timeout is reached.
- Signals the error from the promise if the future rejects."
  (let ((promise (concur:force future)))
    (unless (concur-promise-p promise)
      (error "Invalid future object provided to future-get: %S" future))
    ;; Delegate all blocking, waiting, and error-handling logic to the
    ;; core `concur:await` for consistency.
    (concur:await promise timeout)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Future Chaining & Composition

;;;###autoload
(defun concur:map-future (future transform-fn)
  "Apply TRANSFORM-FN to the result of a future, creating a new future.
This is the `then` equivalent for futures. When the new future is forced, it
first forces the original `FUTURE`. Once the original future resolves,
`TRANSFORM-FN` is applied to its result.

Arguments:
- FUTURE (`concur-future`): The original future object.
- TRANSFORM-FN (function): A function `(lambda (value))` that receives the
  resolved value of `FUTURE`. It can return a regular value or a promise.

Returns:
A new `concur-future` representing the transformed computation."
  (concur:make-future
   (lambda ()
     (concur:then (concur:force future) transform-fn))))

;;;###autoload
(defun concur:then-future (future callback-fn)
  "Alias for `concur:map-future`.
Provided for semantic clarity, aligning with `concur:then`.

Arguments:
- FUTURE (`concur-future`): The original future object.
- CALLBACK-FN (function): The function to apply to the future's result.

Returns:
A new `concur-future`."
  (concur:map-future future callback-fn))

;;;###autoload
(defun concur:catch-future (future error-handler-fn)
  "Attach an error handler to a future.
Creates a new future that, when forced, will execute the original `FUTURE`.
If the original future rejects, `ERROR-HANDLER-FN` is called with the error.
The return value of the handler can resolve the new future, allowing for
error recovery in a chain.

Arguments:
- FUTURE (`concur-future`): The original future object.
- ERROR-HANDLER-FN (function): A function `(lambda (error))` to call
  if the original future rejects.

Returns:
A new `concur-future` with error handling."
  (concur:make-future
   (lambda ()
     (concur:catch (concur:force future) error-handler-fn))))

;;;###autoload
(defun concur:all-futures (futures)
  "Run a list of FUTURES concurrently and collect their results.
This function forces all futures in the `FUTURES` list and returns a new
promise that resolves when all of them have resolved. If any future rejects,
the returned promise immediately rejects.

Arguments:
- FUTURES (list): A list of `concur-future` objects or thunks. Thunks will
  be automatically wrapped in futures.

Returns:
A `concur-promise` that resolves with a list of all results in order, or
rejects with the first error."
  ;; The `concur:all` combinator expects a list of promises, so we force
  ;; each future to get its underlying promise.
  (concur:all (--map (if (concur-future-p it)
                         (concur:force it)
                       (concur:force (concur:make-future it)))
                     futures)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Functions

;;;###autoload
(defun concur:future-from-promise (promise)
  "Create a `concur-future` from an existing PROMISE.
This is useful for integrating an existing promise into a future-based
workflow. The created future is immediately considered 'evaluated' and simply
wraps the provided promise.

Arguments:
- PROMISE (`concur-promise`): The promise object to wrap.

Returns:
A new, evaluated `concur-future`."
  (unless (concur-promise-p promise)
    (error "Argument must be a concur-promise object, got %S" promise))
  (%%make-future :promise promise :evaluated? t))

(provide 'concur-future)
;;; concur-future.el ends here