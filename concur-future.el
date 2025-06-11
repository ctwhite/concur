;;; concur-future.el --- Concurrency primitives for asynchronous tasks -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides primitives for working with "futures" in Emacs Lisp.
;; Futures represent the result of a computation that may not have
;; completed yet. They are a key concept in asynchronous programming,
;; allowing you to start a long-running task and retrieve its result
;; later without blocking the main thread.
;;
;; Key Concepts:
;;
;; -   Future: A `concur-future` object represents a deferred computation.
;;     It holds a thunk (a zero-argument function) that is evaluated
;;     when the future's value is needed.
;;
;; -   Lazy Evaluation: Futures are evaluated lazily. The computation
;;     is not performed until the future is "forced" via `concur:force`.
;;
;; -   Promises: Futures use promises (`concur-promise`) internally to
;;     manage the asynchronous result. The promise is resolved when the
;;     computation completes successfully, or rejected if an error occurs.
;;
;; Core Functionality:
;;
;; -   `concur:make-future`: Creates a new future from a thunk.
;; -   `concur:force`: Forces the evaluation of a future and returns its promise.
;; -   `concur:future-get`: Forces the future and gets the result, blocking
;;      cooperatively until it's available.
;; -   `concur:map-future` / `concur:then-future`: Applies a transformation
;;      function to the result of a future, creating a new future.
;; -   `concur:catch-future`: Attaches an error handler to a future.
;; -   `concur:all-futures`: Runs multiple futures with controlled concurrency.
;; -   `concur:from-promise`: Wraps an existing promise in a future.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-promise)
(require 'concur-core)

;; Forward declarations to satisfy the byte-compiler.
(declare-function yield--internal-throw-form (value tag))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (concur-future (:constructor %%make-future))
  "A lazy future represents a deferred computation.
Do not construct directly; use `concur:make-future`.

Fields:
`promise`    (concur-promise): The cached promise, created on demand.
`thunk`      (function): A zero-argument function for the computation.
`evaluated?` (boolean): `t` if the thunk has been evaluated."
  promise
  thunk
  evaluated?)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-future (thunk)
  "Create a `concur-future` from a zero-argument function THUNK.

The returned future represents a computation that is performed
lazily when `concur:force` is called. When forced, `THUNK` is
executed. If it returns a value, the future's internal promise
resolves with it. If it signals an error, the promise rejects.

Arguments:
- `THUNK` (function): A zero-argument function that performs the computation.

Returns:
A new `concur-future` object."
  (unless (functionp thunk)
    (error "Argument THUNK must be a function"))
  (%%make-future :thunk thunk))

;;;###autoload
(defun concur:force (future)
  "Force FUTURE's thunk to run if not already evaluated.

This function is idempotent; calling it multiple times on the same
future will only run the thunk once.

Arguments:
- `FUTURE` (concur-future): The future object to force.

Returns:
The `concur-promise` associated with the future. If `FUTURE` is
invalid or `nil`, this function returns `nil`."
  (when (concur-future-p future)
    (unless (concur-future-evaluated? future)
      (setf (concur-future-evaluated? future) t)
      (setf (concur-future-promise future)
            (concur:with-executor
             (lambda (resolve reject)
               (condition-case err
                   (funcall (concur-future-thunk future))
                 (error (funcall reject err)))))))
    (concur-future-promise future)))

;;;###autoload
(defun concur:future-get (future &optional timeout)
  "Force FUTURE and get its result, blocking cooperatively.

This function is synchronous and will block the Emacs UI until
the future's promise settles or the `TIMEOUT` is reached.
**Use with extreme caution in interactive code.**

Arguments:
- `FUTURE` (concur-future): The future to get the result from.
- `TIMEOUT` (float, optional): Maximum seconds to wait.

Returns:
A cons cell `(RESULT . ERROR)`. `(value . nil)` on success,
`(nil . error-reason)` on failure.

Errors:
- Throws a `concur:timeout-error` if the timeout is reached."
  (let ((promise (concur:force future)))
    (unless (concur-promise-p promise)
      (error "Invalid future object provided to future-get: %S" future))
    (concur:await promise timeout)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Future Chaining & Composition

;;;###autoload
(defun concur:map-future (future transform-fn)
  "Apply TRANSFORM-FN to the result of a future, creating a new future.

When the new future is forced, it first forces the original
`FUTURE`. Once the original future resolves, `TRANSFORM-FN` is
applied to its result.

Arguments:
- `FUTURE` (concur-future): The original future object.
- `TRANSFORM-FN` (function): A function `(lambda (value))` that receives the
  resolved value of `FUTURE`. It can return a regular value or a promise.

Returns:
A new `concur-future` representing the transformed computation."
  (concur:make-future
   (lambda ()
     (concur:then (concur:force future) transform-fn))))

;;;###autoload
(defun concur:then-future (future callback-fn)
  "Alias for `concur:map-future`.
Provided for semantic clarity, aligning with `concur:then`."
  (concur:map-future future callback-fn))

;;;###autoload
(defun concur:catch-future (future error-handler-fn)
  "Attach an error handler to a future.

Creates a new future that, when forced, will execute the original
`FUTURE`. If the original future rejects, `ERROR-HANDLER-FN` is
called with the error. The return value of the handler resolves
the new future, allowing for recovery.

Arguments:
- `FUTURE` (concur-future): The original future object.
- `ERROR-HANDLER-FN` (function): A function `(lambda (error))` to call
  if the original future rejects.

Returns:
A new `concur-future` with error handling."
  (concur:make-future
   (lambda ()
     (concur:catch (concur:force future) error-handler-fn))))

;;;###autoload
(defun concur:all-futures (futures)
  "Run a list of FUTURES concurrently and collect their results.

This function forces all futures in the `FUTURES` list and returns
a new promise that resolves when all of them have resolved. If any
future rejects, the returned promise immediately rejects.

Arguments:
- `FUTURES` (list): A list of `concur-future` objects or thunks.

Returns:
A `concur-promise` that resolves with a list of all results in
order, or rejects with the first error."
  (concur:all (--map (if (concur-future-p it)
                         (concur:force it)
                       (concur:force (concur:make-future it)))
                     futures)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Functions

;;;###autoload
(defun concur:from-promise (promise)
  "Create a `concur-future` from an existing PROMISE.

This is useful for integrating an existing promise into a
future-based workflow. The created future is immediately considered
'evaluated' and wraps the provided promise.

Arguments:
- `PROMISE` (concur-promise): The promise object to wrap.

Returns:
A new, evaluated `concur-future`."
  (unless (concur-promise-p promise)
    (error "Argument must be a concur-promise object, got %S" promise))
  (%%make-future :promise promise :evaluated? t))

(provide 'concur-future)
;;; concur-future.el ends here