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
(require 'concur-ast)

;; Forward declarations to satisfy the byte-compiler.
(declare-function yield--internal-throw-form "" '(value tag))
(declare-function concur-ast-lift-lambda-form "concur-ast")

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

;; Replace concur:make-future with this final version.
(cl-defmacro concur:make-future (thunk-form &environment env)
  "Create a `concur-future` from a zero-argument function THUNK-FORM."
  (declare (indent 1))
  (let* (;; Use the public API for AST analysis, which handles internal macro-expansion
         ;; and correctly identifies free variables based on lexical scope.
         (analysis-result (concur-ast-analysis thunk-form env)) ; NEW: Use the public analysis API
         ;; Extract the expanded callable form (the thunk itself) from the analysis result.
         (original-thunk (concur-ast-analysis-result-expanded-callable-form analysis-result)) ; NEW
         ;; Extract the list of identified free variables from the analysis result.
         (free-vars (concur-ast-analysis-result-free-vars-list analysis-result)) ; NEW
         ;; Generate the Lisp code that captures the values of the identified
         ;; free variables into a hash table. This uses the dedicated helper.
         (context-form (concur-ast-make-captured-vars-form free-vars))) ; NEW
    ;; The outer `let` captures the `context` hash table when `concur:make-future`
    ;; is expanded. This `context` will contain the values of the free variables
    ;; at the time the future is created.
    `(let ((context ,context-form))
       (%%make-future
        ;; The `:thunk` field of the `concur-future` struct becomes a new lambda.
        ;; This lambda forms a closure over the `context` hash table.
        :thunk (lambda ()
                 ;; When the thunk is finally executed (which might be later, asynchronously),
                 ;; it first unpacks the captured variable values from the `context` hash table
                 ;; into its own lexical environment via a `let` binding.
                 (let ,(cl-loop for var in free-vars
                                collect `(,var (concur--safe-ht-get context ',var))) ; Use assumed safe helper
                   ;; Finally, it calls the user's original thunk with the re-established
                   ;; lexical environment, allowing it to access the captured variables.
                   (funcall ,original-thunk)))))))
                   
;; ;; Replace concur:make-future with this final version.
;; (cl-defmacro concur:make-future (thunk-form &environment env)
;;   "Create a `concur-future` from a zero-argument function THUNK-FORM."
;;   (declare (indent 1))
;;   (let* ((expanded-thunk (macroexpand-all thunk-form env))
;;          (lift-info (concur-ast-lift-lambda-form expanded-thunk))
;;          (original-thunk (car lift-info))
;;          (free-vars (cdr lift-info))
;;          ;; Generate code that captures variable values into a hash table
;;          ;; at the moment `concur:make-future` is called.
;;          (context-form
;;           (if (null free-vars) 'nil
;;             (let ((ht-sym (gensym "context-ht-")))
;;               `(let ((,ht-sym (make-hash-table :test 'eq)))
;;                  ,@(mapcar (lambda (v) `(setf (ht-get ,ht-sym ',v) ,v))
;;                            free-vars)
;;                  ,ht-sym)))))
;;     ;; The outer `let` captures the context when `make-future` is called.
;;     `(let ((context ,context-form))
;;        (%%make-future
;;         ;; The :thunk becomes a closure over that `context` hash table.
;;         :thunk (lambda ()
;;                  ;; When the thunk is finally run, it unpacks the context...
;;                  (let ,(cl-loop for var in free-vars
;;                                 collect `(,var (ht-get context ',var)))
;;                    ;; ...and calls the user's original code.
;;                    (funcall ,original-thunk)))))))
                   
;; ;;;###autoload
;; (cl-defmacro concur:make-future (thunk-form &environment env)
;;   "Create a `concur-future` from a zero-argument function THUNK-FORM.
;; The returned future represents a computation that is performed lazily when
;; `concur:force` is called. When forced, THUNK-FORM is executed. If it returns a
;; value, the future's internal promise resolves with it. If it signals an
;; error, the promise rejects.

;; Arguments:
;; - THUNK-FORM (lambda-form): A zero-argument lambda form `(lambda () ...)`
;;   that performs the computation.

;; Returns:
;; A new `concur-future` object."
;;   (declare (indent 1))

;;   (unless (and (consp thunk-form) (eq (car thunk-form) 'lambda))
;;     (error "concur:make-future: THUNK-FORM must be a lambda form, got %S" thunk-form))

;;   (let* ((expanded-thunk (macroexpand-all thunk-form env))
;;          (unwrapped-thunk (concur--unwrap-handler-form expanded-thunk))
;;          (lifted-info (concur-ast-lift-lambda-form unwrapped-thunk))
;;          (lifted-thunk (car lifted-info))
;;          (free-vars-list (cdr lifted-info))
;;          (runtime-context-alist-form
;;           `(list ,@(cl-loop for var-sym in free-vars-list
;;                             collect `(cons ',var-sym ,var-sym)))))

;;     `(%%make-future
;;       :thunk (lambda ()
;;                (funcall ,lifted-thunk ,runtime-context-alist-form)))))

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
        (condition-case err
            (let ((thunk-result (funcall (concur-future-thunk future))))
              (if (concur-promise-p thunk-result)
                  (concur:then thunk-result
                               (lambda (val) (concur:resolve outer-promise val))
                               (lambda (e) (concur:reject outer-promise e)))
                (concur:resolve outer-promise thunk-result)))
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
    (concur:await promise timeout)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Future Chaining & Composition

;;;###autoload
(cl-defmacro concur:map-future (future transform-fn &environment env)
  "Apply TRANSFORM-FN to the result of a future, creating a new future.
When the new future is forced, it first forces the original `FUTURE`.
Once the original future resolves, `TRANSFORM-FN` is applied to its result.

Arguments:
- FUTURE (`concur-future`): The original future object.
- TRANSFORM-FN (lambda-form): A lambda form `(lambda (value))` that receives the
  resolved value of `FUTURE`. It can return a regular value or a promise.

Returns:
A new `concur-future` representing the transformed computation."
  (declare (indent 1))
  ;; By using `cl-defmacro` here, we ensure that the `concur:make-future`
  ;; call inside this expansion happens in the correct lexical context
  ;; captured from the user's call site.
  `(concur:make-future
    (lambda ()
      (concur:then (concur:force ,future)
                   ,transform-fn))))

;;;###autoload
(cl-defmacro concur:then-future (future callback-fn &environment env)
  "Alias for `concur:map-future`.
Provided for semantic clarity, aligning with `concur:then`.

Arguments:
- FUTURE (`concur-future`): The original future object.
- CALLBACK-FN (lambda-form): The lambda form to apply to the future's result.

Returns:
A new `concur-future`."
  (declare (indent 1))
  `(concur:map-future ,future ,callback-fn))

;;;###autoload
(cl-defmacro concur:catch-future (future error-handler-fn &environment env)
  "Attach an error handler to a future.

Creates a new future that, when forced, will execute the original
`FUTURE`. If the original future rejects, `ERROR-HANDLER-FN` is
called with the error. The return value of the handler resolves
the new future, allowing for recovery.

Arguments:
- `FUTURE` (concur-future): The original future object.
- `ERROR-HANDLER-FN` (lambda-form): A lambda form `(lambda (error))` to call
  if the original future rejects.

Returns:
A new `concur-future` with error handling."
  (declare (indent 1))
  `(concur:make-future
    (lambda ()
      (concur:catch (concur:force ,future)
                    ,error-handler-fn))))

;;;###autoload
(cl-defmacro concur:all-futures (futures &environment env)
  "Run a list of FUTURES concurrently and collect their results.
This function forces all futures in the `FUTURES` list and returns a new
promise that resolves when all of them have resolved. If any future rejects,
the returned promise immediately rejects.

Arguments:
- FUTURES (list-of-futures-or-lambda-forms): A list of `concur-future`
  objects or lambda forms. Lambda forms are automatically wrapped in futures.

Returns:
A `concur-promise` that resolves with a list of all results in order, or
rejects with the first error."
  (declare (indent 1))
  `(concur:all (--map (lambda (it)
                        (if (concur-future-p it)
                            (concur:force it)
                          (if (and (consp it) (eq (car it) 'lambda))
                              (concur:force (concur:make-future it))
                            (error "concur:all-futures: Invalid thunk or future: %S" it))))
                      ,futures)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Functions

;;;###autoload
(defun concur:future-from-promise (promise)
  "Create a `concur-future` from an existing PROMISE.
This is useful for integrating an existing promise into a future-based
workflow. The created future is immediately considered `evaluated` and simply
wraps the provided promise.

Arguments:
- PROMISE (`concur-promise`): The promise object to wrap.

Returns:
A new, evaluated `concur-future`."
  (unless (concur-promise-p promise)
    (error "Argument must be a concur-promise object, got %S" promise))
  (%%make-future :promise promise :evaluated? t))

;; --- Plug into the core promise system ---
;; Set the normalizer hook so that core functions like `concur:then`
;; can transparently accept futures.
(setq concur--normalize-awaitable-fn
      (lambda (awaitable)
        (if (concur-future-p awaitable)
            (concur:force awaitable)
          awaitable)))
              
(provide 'concur-future)
;;; concur-future.el ends here



