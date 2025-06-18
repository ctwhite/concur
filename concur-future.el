;;; concur-future.el --- Concurrency primitives for lazy async tasks -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This file provides primitives for working with "futures" in Emacs Lisp.
;; Futures represent a deferred computation evaluated lazily when needed.
;;
;; Key Concepts:
;; - Future: A `concur-future` object, holding a thunk (zero-arg fn).
;; - Lazy Evaluation: Thunk runs only when future is "forced".
;; - Promises: Futures use promises internally to manage async result.
;;
;; Enhancements in this module include:
;; - `concur:future-resolved!` and `concur:future-rejected!` for pre-settled futures.
;; - `concur:future-delay` for futures that resolve after a delay.
;; - `concur:future-race` and `concur:future-all` for compositing futures.
;; - `concur:future-then` and `concur:future-catch` as semantic aliases.
;; - Integration with `concur-normalize-awaitable-hook` for extensibility.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-ast)
(require 'concur-promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Future Creation & Forcing

;;;###autoload
(cl-defmacro concur:make-future (thunk-form &environment env)
  "Create a `concur-future` from THUNK-FORM.
The returned future represents a computation that is performed lazily when
`concur:force` is called. Lexical variables are captured correctly.

Arguments:
- `thunk-form`: (lambda-form) A zero-argument lambda `(lambda () ...)`
  that performs the computation.

Returns:
- (`concur-future`) A new `concur-future` object."
  (declare (indent 1) (debug t))
  (let* ((analysis (concur-ast-analysis thunk-form env))
         (thunk (concur-ast-analysis-result-expanded-callable-form analysis))
         (free-vars (concur-ast-analysis-result-free-vars-list analysis))
         (context-form (concur-ast-make-captured-vars-form free-vars)))
    ;; The outer `let` captures the `context` hash table when the future is
    ;; created, preserving the values of the free variables.
    `(let ((context ,context-form))
       (%%make-future
        :thunk (lambda ()
                 ;; When the thunk finally executes, it unpacks the captured
                 ;; variable values into its own lexical environment.
                 (let ,(cl-loop for var in free-vars
                                collect `(,var (concur-safe-ht-get context ',var)))
                   (funcall ,thunk)))))))

;;;###autoload
(defun concur:force (future)
  "Force FUTURE's thunk to run if not already evaluated.
This function is idempotent. It correctly handles thunks that may themselves
return a `concur-promise`.

Arguments:
- `future`: (`concur-future`) The future object to force.

Returns:
- (`concur-promise`) The promise associated with the future."
  (unless (concur-future-p future)
    (error "Invalid future object to concur:force: %S" future))

  (when (concur-future-evaluated? future)
    (cl-return-from concur:force (concur-future-promise future)))

  ;; Mark as evaluated immediately to prevent re-entrancy.
  (setf (concur-future-evaluated? future) t)

  ;; Create and store the promise that will hold the future's result.
  (setf (concur-future-promise future) (concur:make-promise))

  (let ((promise (concur-future-promise future)))
    (concur--log :debug "[FUTURE:force] Forcing future, created promise %S."
                 (concur:format-promise promise))
    (condition-case err
        (let ((thunk-result (funcall (concur-future-thunk future))))
          (if (concur-promise-p thunk-result)
              ;; If thunk returns a promise, chain our promise to it.
              (concur:then thunk-result
                           (lambda (val) (concur:resolve promise val))
                           (lambda (e) (concur:reject promise e)))
            ;; Otherwise, resolve our promise directly.
            (concur:resolve promise thunk-result)))
      (error
       ;; If thunk signals an error, reject our promise.
       (concur--log :error "[FUTURE:force] Thunk failed with error: %S." err)
       (concur:reject promise err))))
  (concur-future-promise future))

;;;###autoload
(defun concur:future-get (future &optional timeout)
  "Force FUTURE and get its result, blocking cooperatively until available.
This function is synchronous and behaves identically to `concur:await`.
**Use with caution in interactive code.**

Arguments:
- `future`: (`concur-future`) The future to get the result from.
- `timeout`: (float, optional) Maximum seconds to wait.

Returns:
- (any) The resolved value of the future's promise."
  (let ((promise (concur:force future)))
    (concur:await promise timeout)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Future Creation (Pre-settled & Delayed)

;;;###autoload
(cl-defun concur:future-resolved! (value)
  "Return a new `concur-future` that is already resolved with VALUE."
  (concur--log :debug "[FUTURE:resolved!] Creating pre-resolved future.")
  (let ((promise (concur:resolved! value)))
    (%%make-future :promise promise :evaluated? t :thunk (lambda () value))))

;;;###autoload
(cl-defun concur:future-rejected! (error)
  "Return a new `concur-future` that is already rejected with ERROR."
  (concur--log :debug "[FUTURE:rejected!] Creating pre-rejected future.")
  (let ((promise (concur:rejected! error)))
    (%%make-future :promise promise :evaluated? t :thunk (lambda () (error error)))))

;;;###autoload
(cl-defun concur:future-delay (seconds &optional value)
  "Create a `concur-future` that resolves with VALUE after SECONDS."
  (concur--log :debug "[FUTURE:delay] Creating delayed future for %s seconds." seconds)
  (concur:make-future (lambda () (concur:delay seconds value))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Future Chaining & Composition

;;;###autoload
(cl-defmacro concur:future-then (future transform-fn &environment env)
  "Apply TRANSFORM-FN to the result of a future, creating a new future.
When the new future is forced, it first forces the original `FUTURE`.
Once the original future resolves, `TRANSFORM-FN` is applied to its result.

Arguments:
- `future`: (`concur-future`) The original future object.
- `transform-fn`: (lambda-form) A lambda `(lambda (value) ...)` that receives
  the resolved value of `FUTURE`.

Returns:
- (`concur-future`) A new `concur-future` representing the transformed task."
  (declare (indent 1) (debug t))
  `(concur:make-future
    (lambda ()
      (concur:then (concur:force ,future) ,transform-fn))))

;;;###autoload
(cl-defmacro concur:future-catch (future error-handler-fn &environment env)
  "Attach an error handler to a future.
Creates a new future that can recover from a rejection in the original.

Arguments:
- `future`: (`concur-future`) The original future object.
- `error-handler-fn`: (lambda-form) A lambda `(lambda (error) ...)` to call
  if the original future rejects.

Returns:
- (`concur-future`) A new `concur-future` with error handling."
  (declare (indent 1) (debug t))
  `(concur:make-future
    (lambda ()
      (concur:catch (concur:force ,future) ,error-handler-fn))))

;;;###autoload
(cl-defun concur:future-all (futures)
  "Run a list of FUTURES concurrently and collect their results.
This function forces all futures in the `FUTURES` list and returns a promise
that resolves when all have resolved. If any future rejects, the returned
promise immediately rejects.

Arguments:
- `futures`: (list of `concur-future`) A list of `concur-future` objects.

Returns:
- (`concur-promise`) A promise that resolves with a list of all results."
  (concur:all (--map (concur:force it) futures)))

;;;###autoload
(cl-defun concur:future-race (futures)
  "Race a list of FUTURES concurrently.
This function forces all futures in the `FUTURES` list and returns a promise
that settles with the result of the first one to settle.

Arguments:
- `futures`: (list of `concur-future`) A list of `concur-future` objects.

Returns:
- (`concur-promise`) A promise that settles with the value or error
  of the first future to settle."
  (concur:race (--map (concur:force it) futures)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration

(defun concur-future-normalize-awaitable (awaitable)
  "Normalizes an AWAITABLE into a promise if it's a `concur-future`.
This function is added to `concur-normalize-awaitable-hook`.

Arguments:
- `awaitable`: (any) The object to potentially normalize.

Returns:
- (`concur-promise` or nil): The promise from forcing the future, or nil."
  (if (concur-future-p awaitable)
      (concur:force awaitable)
    nil))

;; Plug into the core promise system so that core functions like `concur:then`
;; can transparently accept futures.
(add-hook 'concur-normalize-awaitable-hook #'concur-future-normalize-awaitable)

(provide 'concur-future)
;;; concur-future.el ends here