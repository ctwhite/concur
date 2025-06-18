;;; concur-chain.el --- Chaining and flow-control for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the primary user-facing API for composing and chaining
;; promises. It contains the fundamental `concur:then` macro for attaching
;; success and failure handlers, as well as higher-level convenience macros like
;; `concur:catch`, `concur:finally`, `concur:tap`, and the powerful `concur:chain`
;; for expressing complex asynchronous workflows in a clear, sequential manner.
;;
;; Enhancements in this version significantly boost the expressiveness and
;; robustness of `concur:chain`, including:
;;
;; - `:await-all` and `:await-race` steps for parallel/racing sub-operations.
;; - `:if-then` for conditional branching within the chain based on a value.
;; - `:timeout` for applying a time limit to a specific section of the chain.
;;
;; This module depends on `concur-ast.el` to correctly "lift" variables from
;; lexical closures, making them available across asynchronous boundaries. This
;; allows handlers to seamlessly use variables from their surrounding scope
;; without manual capturing.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-core)
(require 'concur-hooks)
(require 'concur-ast)

;; Forward declarations for byte-compiler
(declare-function concur:all "concur-combinators" (promise-list))
(declare-function concur:race "concur-combinators" (promise-list))

;; These helpers are needed by the macros at compile-time.
(eval-and-compile
  (require 'concur-ast)

  (defun concur--prepare-then-macro-data (on-resolved-form on-rejected-form env)
    "Prepare data for `concur:then` using the AST analyzer.
This helper function analyzes the success and failure handler forms to
identify all free variables that need to be captured from the lexical
environment (`env`). It returns a plist containing the processed lambda
forms and the necessary context for variable lifting.

Arguments:
- ON-RESOLVED-FORM (form): The Lisp form for the success handler.
- ON-REJECTED-FORM (form): The Lisp form for the failure handler.
- ENV (environment): The lexical environment at the macro call site.

Returns:
- (plist): A property list containing analyzed data for the macro expansion."
    (-let* ((resolved-analysis
             (concur-ast-analysis (or on-resolved-form '(lambda (val) val)) env))
            (rejected-analysis
             (concur-ast-analysis (or on-rejected-form
                                      '(lambda (err) (concur:rejected! err)))
                                  env))
            (all-vars
             (cl-delete-duplicates
              (append (concur-ast-analysis-result-free-vars-list resolved-analysis)
                      (concur-ast-analysis-result-free-vars-list rejected-analysis))))
            (captured-vars-form (concur-ast-make-captured-vars-form all-vars)))
      `(:original-resolved-lambda
        ,(concur-ast-analysis-result-expanded-callable-form resolved-analysis)
        :resolved-vars
        ,(concur-ast-analysis-result-free-vars-list resolved-analysis)
        :original-rejected-lambda
        ,(concur-ast-analysis-result-expanded-callable-form rejected-analysis)
        :rejected-vars
        ,(concur-ast-analysis-result-free-vars-list rejected-analysis)
        :captured-vars-form ,captured-vars-form)))

  (defun concur--anaphoric-lambda (body)
      "Wrap BODY in a lambda that binds its first argument to the anaphoric var `<>`.
This is a utility for `concur:chain` to handle implicit steps.

Arguments:
- BODY (form): The body of the lambda.

Returns:
- (form): A lambda form `(lambda (<>) ...)`."
      `(lambda (<>) ,body))

  (defun concur--expand-sugar (steps)
    "Transform sugar keywords in `concur:chain` into canonical clauses.
This function acts as a pre-processor for `concur:chain`, turning high-level,
declarative steps like `:await-all` or `:sleep` into standard `:then` clauses
that the main chain expander can process.

Arguments:
- STEPS (list): A list of steps from a `concur:chain` macro call.

Returns:
- (list): A new list of steps with syntactic sugar expanded."
    (let (processed remaining)
      (setq remaining steps)
      (while remaining
        (let ((key (pop remaining)) arg1 arg2)
          (pcase key
            (:await-all
             (setq arg1 (pop remaining))
             (push `(:then ,(concur--anaphoric-lambda `(concur:all ,arg1))) processed))
            (:await-race
             (setq arg1 (pop remaining))
             (push `(:then ,(concur--anaphoric-lambda `(concur:race ,arg1))) processed))
            (:if-then
             (setq arg1 (pop remaining)) (setq arg2 (pop remaining))
             (let ((else-arg (when (and remaining (not (keywordp (car remaining))))
                               (pop remaining))))
               (push `(:then (lambda (<>) (if ,arg1 ,arg2 ,(or else-arg '<>))))
                     processed)))
            (:timeout
             (setq arg1 (pop remaining)) (setq arg2 (pop remaining))
             (push `(:then (lambda (<>)
                             (concur:timeout
                              (concur--chain-process-single-step-form
                               (concur:resolved! <>) arg2 nil "")
                              ,arg1)))
                   processed))
            (:map
             (setq arg1 (pop remaining))
             (push `(:then (lambda (list-val) (--map ,arg1 list-val))) processed))
            (:filter
             (setq arg1 (pop remaining))
             (push `(:then (lambda (list-val) (--filter ,arg1 list-val)))
                   processed))
            (:each
             (setq arg1 (pop remaining))
             (push `(:then (lambda (list-val)
                             (prog1 list-val (--each ,arg1 list-val))))
                   processed))
            (:sleep
             (setq arg1 (pop remaining))
             (push `(:then (lambda (val)
                             (concur:then (concur:delay (/ ,arg1 1000.0))
                                          (lambda (_) val))))
                   processed))
            (:log
             (let ((fmt (if (and remaining (stringp (car remaining)))
                            (pop remaining) "%S")))
               (push `(:tap (lambda (val err) (message ,fmt (or val err))))
                     processed)))
            (:retry
             (setq arg1 (pop remaining)) (setq arg2 (pop remaining))
             (push `(:then ,(concur--anaphoric-lambda
                             `(concur:retry (lambda () ,arg2) :retries ,arg1)))
                   processed))
            (_ (push key processed)
               (when remaining (push (pop remaining) processed))))))
      (nreverse processed)))

  (defun concur--chain-process-single-step-form (current-form step when-p prefix)
    "Helper to expand a single step in a `concur:chain`.
This function takes the promise from the previous step (`CURRENT-FORM`) and
wraps it in the appropriate macro call (`concur:then`, `concur:catch`, etc.)
for the given `STEP`.

Arguments:
- CURRENT-FORM (form): The form representing the promise from the prior step.
- STEP (form): The current step clause to process (e.g., `(:then ...)`).
- WHEN-P (boolean): If non-nil, wrap the step's logic in a `(when <>)`.
- PREFIX (string): A prefix for error messages.

Returns:
- (form): The expanded form for the current step, chained to the prior one."
    (let ((anaphoric-wrapper
           (lambda (body) `(lambda (<>) ,(if when-p `(when <> ,body) body)))))
      (pcase step
        (`(:then ,handler)    `(concur:then ,current-form ,handler))
        (`(:catch ,handler)   `(concur:catch ,current-form ,handler))
        (`(:finally ,handler) `(concur:finally ,current-form ,handler))
        (`(:tap ,handler)     `(concur:tap ,current-form ,handler))
        (`(:all ,promises)    `(concur:all ,promises))
        (`(:race ,promises)   `(concur:race ,promises))
        ;; Handle implicit `:then` for raw forms.
        (_ (if (listp step)
               `(concur:then ,current-form ,(funcall anaphoric-wrapper step))
             (error "%sInvalid concur:chain step: %S" prefix step))))))
) ; End of eval-and-compile

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Promise Chaining and Flow Control

(cl-defmacro concur:then (source-promise-form
                             &optional on-resolved-form on-rejected-form
                             &environment env)
  "Chain a new promise from `SOURCE-PROMISE-FORM`, transforming its result.
This is the fundamental promise chaining primitive, analogous to `.then()`
in JavaScript. It allows attaching success (`ON-RESOLVED-FORM`) and
failure (`ON-REJECTED-FORM`) handlers that execute asynchronously when the
source promise settles.

Lexical variables from the surrounding scope are automatically captured and
made available to the handlers via AST analysis and transformation.

Arguments:
- `SOURCE-PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
- `ON-RESOLVED-FORM` (form, optional): A lambda `(lambda (value) ...)` or a
  function symbol to handle the success case. The value it returns determines
  the resolution of the new promise. Defaults to an identity function
  `(lambda (val) val)`.
- `ON-REJECTED-FORM` (form, optional): A lambda `(lambda (error) ...)` or a
  function symbol to handle the failure case. It can recover from an error
  by returning a normal value, or propagate the error by re-rejecting.
  Defaults to re-rejecting the original error.
- `env` (environment, implicit): The lexical environment at the macro call site,
  used for variable capture.

Returns:
- (`concur-promise`): A new promise that resolves or rejects based on the
  outcome of the executed handler."
  (declare (indent 1) (debug t))
  (-let* (((&plist :original-resolved-lambda resolved-lambda
                   :resolved-vars resolved-vars
                   :original-rejected-lambda rejected-lambda
                   :rejected-vars rejected-vars
                   :captured-vars-form captured-vars-form)
           (concur--prepare-then-macro-data
            on-resolved-form on-rejected-form env))
          (new-promise (gensym "new-promise"))
          (err (gensym "err")))

    `(let ((,new-promise (concur:make-promise)))
       ;; Attach the handlers to the source promise.
       (concur--on-resolve
        ,source-promise-form
        ;; Create the success callback.
        (concur--make-resolved-callback
         (lambda (value context)
           ;; Catch synchronous errors within the handler itself.
           (condition-case ,err
               (concur--resolve-with-maybe-promise
                ,new-promise
                (let ,(cl-loop for var in resolved-vars
                               collect `(,var (concur-safe-ht-get context ',var)))
                  (funcall ,resolved-lambda value)))
             (error (concur:reject ,new-promise
                                   `(executor-error :original-error ,,err)))))
         ,new-promise :captured-vars ,captured-vars-form)
        ;; Create the failure callback.
        (concur--make-rejected-callback
         (lambda (error context)
           (condition-case ,err
               (concur--resolve-with-maybe-promise
                ,new-promise
                (let ,(cl-loop for var in rejected-vars
                               collect `(,var (concur-safe-ht-get context ',var)))
                  (funcall ,rejected-lambda error)))
             (error (concur:reject ,new-promise
                                   `(executor-error :original-error ,,err)))))
         ,new-promise  :captured-vars ,captured-vars-form))
       ,new-promise)))

;;;###autoload
(defmacro concur:catch (caught-promise-form handler-form)
  "Attach an error `HANDLER-FORM` to `CAUGHT-PROMISE-FORM`.
This is a convenience alias for `(concur:then promise nil handler)`. It is
useful for handling failures without needing to provide a success case.
The `HANDLER-FORM` can recover from the error by returning a regular value.

Arguments:
- `CAUGHT-PROMISE-FORM` (form): A form that evaluates to a promise.
- `HANDLER-FORM` (form): A lambda `(lambda (error) ...)` or function symbol
  that will be executed if the promise is rejected.

Returns:
- (`concur-promise`): A new promise."
  (declare (indent 1) (debug t))
  `(concur:then ,caught-promise-form nil ,handler-form))

;;;###autoload
(defmacro concur:finally (final-promise-form callback-form)
  "Attach `CALLBACK-FORM` to run after `FINAL-PROMISE-FORM` settles.
The callback executes regardless of whether the source promise resolved or
rejected, making it ideal for cleanup operations (e.g., closing files,
releasing locks).

The returned promise adopts the state of the original promise, unless the
`CALLBACK-FORM` itself errors, in which case the returned promise will
be rejected with that new error.

Arguments:
- `FINAL-PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A nullary lambda `(lambda () ...)` or function
  symbol to execute upon settlement.

Returns:
- (`concur-promise`): A new promise."
  (declare (indent 1) (debug t))
  `(concur:then
    ,final-promise-form
    ;; on-resolved: Wait for callback to complete, then pass through the original value.
    (lambda (val)
      (concur:then (concur:resolved! (funcall ,callback-form))
                   (lambda (_) val)))
    ;; on-rejected: Wait for callback, then re-reject with the original error.
    (lambda (err)
      (concur:then (concur:resolved! (funcall ,callback-form))
                   (lambda (_) (concur:rejected! err))))))

;;;###autoload
(defmacro concur:tap (tapped-promise-form callback-form)
  "Attach `CALLBACK-FORM` for side effects, without altering the promise chain.
This is useful for inspecting a promise's value or error at a certain
point in a chain without modifying it (e.g., for logging). The return
value of `CALLBACK-FORM` is ignored.

Arguments:
- `TAPPED-PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A lambda `(lambda (value error) ...)` or function
  symbol. It will be called with `(value, nil)` on success or `(nil, error)`
  on failure.

Returns:
- (`concur-promise`): A new promise that resolves or rejects with the
  exact same value or error as the original promise."
  (declare (indent 1) (debug t))
  `(concur:then
    ,tapped-promise-form
    (lambda (val)
      ;; Run the callback but ignore its result.
      (funcall ,callback-form val nil)
      ;; Always pass through the original value.
      val)
    (lambda (err)
      ;; Run the callback but ignore its result.
      (funcall ,callback-form nil err)
      ;; Always re-reject with the original error.
      (concur:rejected! err))))

;;;###autoload
(defmacro concur:chain (initial-promise-expr &rest steps)
  "Thread `INITIAL-PROMISE-EXPR` through a series of asynchronous steps.
This macro provides a readable, linear syntax for composing promises,
avoiding deeply nested `concur:then` calls.

The anaphoric variable `<>` is available in most steps and is bound to
the resolved value of the previous step.

Arguments:
- `INITIAL-PROMISE-EXPR` (form): The promise or value to start the chain.
- `STEPS` (list): A list of step clauses. Supported clauses are:
  - `:then (lambda (<>) ...)`: The standard `then` handler.
  - `:catch (lambda (err) ...)`: The standard rejection handler.
  - `:finally (lambda () ...)`: A cleanup handler.
  - `:tap (lambda (val err) ...)`: An inspection handler.
  - `:await-all <form>`: Awaits a list of promises in parallel.
  - `:await-race <form>`: Races a list of promises.
  - `:if-then <cond> <then-form> [<else-form>]`: Conditional branching.
  - `:map <form>`: Equivalent to `(--map <form> <>)`.
  - `:filter <form>`: Equivalent to `(--filter <form> <>)`.
  - `:each <form>`: Equivalent to `(--each <form> <>)`.
  - `:sleep <ms>`: Delays the chain for <ms> milliseconds.
  - `:log [\"format\"]`: Logs the current value or error.
  - `:timeout <sec> <steps...>`: Applies a timeout to a sub-chain.
  - `:retry <n> <form>`: Retries a promise-returning form `n` times.
  - Any other form is treated as an implicit `:then` step.

Returns:
- (`concur-promise`): A promise representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  (let* ((sugared-steps (concur--expand-sugar steps))
         (result-form `(concur:resolved! ,initial-promise-expr))
         (remaining-steps sugared-steps))
    (while remaining-steps
      (let* ((step (pop remaining-steps))
             (temp-result result-form))
        (cond
         ;; Handle `:let` as a special case for introducing lexical bindings.
         ((eq (car step) :let)
          (let ((bindings (cadr step)) (inner-steps remaining-steps))
            (setq result-form
                  `(let* ,bindings
                     ,(macroexpand
                       `(concur:chain ,temp-result ,@inner-steps))))
            (setq remaining-steps nil)))
         (t
          (setq result-form
                (concur--chain-process-single-step-form
                 temp-result step nil ""))))))
    result-form))

;;;###autoload
(defmacro concur:chain-when (initial-promise-expr &rest steps)
  "Like `concur:chain` but short-circuits on `nil` resolved values.
If any promise in the chain resolves with a `nil` or `false` value,
subsequent `:then` and other value-transforming steps are skipped.
Error and cleanup handlers (`:catch`, `:finally`, `:tap`) will still execute.
This is useful for workflows where a failure to produce a value should
halt the main processing path without being a formal error.

Arguments:
- See `concur:chain`.

Returns:
- (`concur-promise`): A promise representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  (let* ((sugared-steps (concur--expand-sugar steps))
         (result-form `(concur:resolved! ,initial-promise-expr))
         (remaining-steps sugared-steps))
    (while remaining-steps
      (let* ((step (pop remaining-steps))
             (temp-result result-form))
        (cond
         ((eq (car step) :let)
          (let ((bindings (cadr step)) (inner-steps remaining-steps))
            (setq result-form
                  `(let* ,bindings
                     ,(macroexpand
                       `(concur:chain-when ,temp-result ,@inner-steps))))
            (setq remaining-steps nil)))
         (t
          ;; The `t` for `when-p` tells the helper to wrap steps in `(when <> ...)`.
          (setq result-form
                (concur--chain-process-single-step-form
                 temp-result step t ""))))))
    result-form))

(provide 'concur-chain)
;;; concur-chain.el ends here