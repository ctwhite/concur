;;; concur-chain.el --- Chaining and flow-control for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the primary user-facing API for composing and chaining
;; promises. It contains the fundamental `concur:then` macro for attaching
;; success and failure handlers, as well as higher-level convenience macros
;; like `concur:catch`, `concur:finally`, and the powerful `concur:chain`
;; for expressing complex asynchronous workflows in a clear, sequential manner.
;;
;; REFACTORED Architectural Highlights:
;; - Native Closures: The library now fully relies on standard Emacs Lisp
;;   lexical closures. The runtime automatically captures the environment
;;   of handler functions, eliminating the need for AST analysis.
;; - Simplicity and Robustness: The `concur:then` macro is now implemented
;;   directly on top of `concur:with-executor`, providing a clear, explicit,
;;   and robust foundation for all chaining operations.
;; - Rich Syntactic Sugar: The `concur:chain` macro provides a powerful DSL
;;   for writing sequential-style async code, with built-in support for
;;   logging, delays, retries, and common collection operations.

;;; Code:

(require 'cl-lib)
(require 'dash)

(require 'concur-core)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward Declarations for Combinators (from concur-combinators.el)

(declare-function concur:all "concur-combinators")
(declare-function concur:race "concur-combinators")
(declare-function concur:timeout "concur-combinators")
(declare-function concur:delay "concur-combinators")
(declare-function concur:retry "concur-combinators")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Macro Helpers

(eval-and-compile
  (defun concur--expand-sugar (steps)
    "Transform syntactic sugar keywords in `concur:chain` into canonical clauses.
This function iterates through the `STEPS` provided to `concur:chain`
and replaces keywords like `:sleep`, `:log`, etc., with their
corresponding `(:then ...)` or `(:tap ...)` forms.

Arguments:
- `STEPS` (list): The list of forms from a `concur:chain` macro call.

Returns:
- `(list)`: A new list of steps with all sugar expanded."
    (let (processed)
      (while steps
        (let ((key (pop steps)) arg1 sub-chain)
          (pcase key
            (:timeout
             (setq arg1 (pop steps))
             (setq sub-chain
                   (cl-loop for form in steps
                            while (and form (not (keywordp form)))
                            collect form))
             (setq steps (nthcdr (length sub-chain) steps))
             (when (and (= 1 (length sub-chain))
                        (eq 'list (car-safe (car sub-chain))))
               (setq sub-chain (cdr (car sub-chain))))
             (push `(:then (lambda (<>)
                             (concur:timeout
                              (concur:chain <> ,@sub-chain) ,arg1)))
                   processed))
            ((or :await-all :await-race :if-then :map :filter :each :sleep :retry)
             (setq arg1 (pop steps))
             (pcase key
               (:await-all (push `(:then (lambda (<>) (concur:all ,arg1))) processed))
               (:await-race (push `(:then (lambda (<>) (concur:race ,arg1))) processed))
               (:if-then
                (let* ((then-form arg1)
                       (else-form (when (and steps (not (keywordp (car steps))))
                                    (pop steps))))
                  (push `(:then (lambda (<>) (if <> ,then-form ,(or else-form '<>))))
                        processed)))
               (:map (push `(:then (lambda (list) (--map ,arg1 list))) processed))
               (:filter (push `(:then (lambda (list) (--filter ,arg1 list))) processed))
               (:each (push `(:then (lambda (list) (prog1 list (--each ,arg1 list))))
                            processed))
               (:sleep (push `(:then (lambda (val)
                                       (concur:then (concur:delay (/ ,arg1 1000.0))
                                                    (lambda (_) val))))
                             processed))
               (:retry
                (let ((retry-form (pop steps)))
                  (push `(:then (lambda (<>)
                                  (concur:retry (lambda () ,retry-form)
                                                :retries ,arg1)))
                        processed)))))
            (:log
             (let ((fmt (if (and steps (stringp (car steps)))
                            (pop steps) "concur:chain log: %S")))
               (push `(:tap (lambda (val err)
                              (concur-log :info nil ,fmt (or val err))))
                     processed)))
            (_ (push key processed)
             (when steps (push (pop steps) processed))))))
      (nreverse processed)))

  (defun concur--chain-process-single-step (current-promise-form step
                                              short-circuit-on-nil-p)
      "Generate the code for a single step in a `concur:chain` expansion.
  This function takes the form representing the promise from the previous
  step and a new `STEP` clause, and wraps it in the appropriate
  `concur:then`, `concur:catch`, etc. macro call.

  Arguments:
  - `current-promise-form` (form): The Lisp form that evaluates to the
    promise being chained from.
  - `step` (form): The current clause from the `concur:chain` body.
  - `short-circuit-on-nil-p` (boolean): If `t`, wrap anaphoric steps in
    a `(when <> ...)` to skip execution if the incoming value is `nil`.

  Returns:
  - `(form)`: A new Lisp form representing the next state of the chain."
    (pcase step
      (`(:then ,handler)
      `(concur:then ,current-promise-form ,handler))

      (`(:catch ,handler)
      `(concur:catch ,current-promise-form ,handler))

      (`(:finally ,handler)
      `(concur:finally ,current-promise-form ,handler))

      (`(:tap ,handler)
      `(concur:tap ,current-promise-form ,handler))

      ;; This is the corrected fallback case for implicit :then steps
      (_ (if (listp step)
            `(concur:then
              ,current-promise-form
              ;; Correctly construct the anaphoric lambda
              (lambda (<>)
                ,(if short-circuit-on-nil-p `(when <> ,step) step)))
          (user-error "Invalid concur:chain step: %S" step)))))

  (defmacro concur--expand-chain-internal (initial-value-expr
                                           steps short-circuit-on-nil-p)
    "Internal helper to expand `concur:chain` and `concur:chain-when`.
This macro takes the initial value, a list of steps, and a boolean
flag for short-circuiting. It expands into a nested series of `concur:then`
(and other primitive) calls.

Arguments:
- `initial-value-expr` (form): The expression for the chain's starting value.
- `steps` (list): The list of step clauses to expand.
- `short-circuit-on-nil-p` (boolean): The flag for `concur:chain-when`.

Returns:
- `(form)`: The fully expanded Lisp form for the promise chain."
    (declare (indent 1) (debug t))
    (let ((result-form `(concur:resolved! ,initial-value-expr)))
      (dolist (step (concur--expand-sugar steps))
        (setq result-form (concur--chain-process-single-step result-form
                                                           step
                                                           short-circuit-on-nil-p)))
      result-form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Promise Chaining Primitives

;;;###autoload
(defmacro concur:then (source-promise-form
                       &optional on-resolved-form on-rejected-form)
  "Attaches success and failure handlers to a promise, returning a new promise.
This is the fundamental operation for promise chaining, compliant with
the Promise/A+ specification.

The `on-resolved-form` and `on-rejected-form` are handler functions. The new
promise returned by `concur:then` is settled based on the outcome of
whichever handler is executed:
- If a handler returns a regular value, the new promise is resolved with
  that value.
- If a handler returns a promise (a 'thenable'), the new promise will
  'assimilate' its state, eventually resolving or rejecting with the same
  outcome.
- If a handler signals a Lisp error, the new promise is rejected with a
  `concur-callback-error`.

Arguments:
- `SOURCE-PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
- `ON-RESOLVED-FORM` (form, optional): A lambda `(lambda (value) ...)` for
  the success case. If nil, defaults to an identity function that passes
  the value through to the next promise in the chain.
- `ON-REJECTED-FORM` (form, optional): A lambda `(lambda (error) ...)` for
  the failure case. If nil, defaults to a function that re-jects the
  promise, propagating the error down the chain.

Returns:
- `(concur-promise)`: A new promise representing the outcome of the handler."
  (declare (indent 1) (debug t))
  (let* ((p-sym (gensym "source-promise-"))
         (new-p-sym (gensym "new-promise-"))
         ;; Gensyms for the handler arguments to prevent variable capture.
         (target-p-arg (gensym "target-p-"))
         (val-arg (gensym "val-"))
         (err-arg (gensym "err-")))

    ;; The macro will expand into this single `let*` block.
    `(let* ((,p-sym ,source-promise-form)
            (,new-p-sym (concur:make-promise :parent-promise ,p-sym)))

       ;; This function passes the source and *target* promises along with
       ;; the handler functions to the core system.
       (concur-attach-then-callbacks
        ,p-sym
        ,new-p-sym ;; Pass the newly created promise explicitly.

        ;; === ON-RESOLVED HANDLER ===
        ;; This wrapper lambda now explicitly ensures the user's handler
        ;; is called with exactly one argument, wrapping it if necessary.
        ;; This avoids arity confusion for handlers expecting a single value.
        (lambda (,target-p-arg ,val-arg)
          (condition-case err
              (let ((res (if ,on-resolved-form
                             ;; Use a simple 1-arg lambda to wrap the user's handler.
                             ;; This ensures `funcall` gets a clear 1-arg target.
                             (funcall (lambda (user-arg)
                                        (funcall ,on-resolved-form user-arg))
                                      ,val-arg)
                           ,val-arg)))
                (concur:resolve ,target-p-arg res))
            (error
             (concur:reject ,target-p-arg
                            (concur:make-error
                             :type :callback-error
                             :message (format "Resolved handler failed: %S" err)
                             :cause err :promise ,target-p-arg)))))

        ;; === ON-REJECTED HANDLER ===
        ;; This wrapper lambda now explicitly ensures the user's handler
        ;; is called with exactly one argument, wrapping it if necessary.
        (lambda (,target-p-arg ,err-arg)
          (condition-case handler-err
              (if ,on-rejected-form
                  ;; Use a simple 1-arg lambda to wrap the user's handler.
                  (let ((res (funcall (lambda (user-arg)
                                        (funcall ,on-rejected-form user-arg))
                                      ,err-arg)))
                    (concur:resolve ,target-p-arg res))
                (concur:reject ,target-p-arg ,err-arg))
            (error
             (concur:reject ,target-p-arg
                            (concur:make-error
                             :type :callback-error
                             :message (format "Rejected handler failed: %S" handler-err)
                             :cause handler-err :promise ,target-p-arg))))))
       ,new-p-sym)))

;;;###autoload
(defmacro concur:catch (promise-form handler-form)
  "Attach an error `HANDLER-FORM` to a promise.
This is a convenience alias for `(concur:then promise nil handler)`.
The `HANDLER-FORM` can 'recover' from the error by returning a non-error
value, which will resolve the new promise, allowing subsequent `.then`
handlers in a chain to execute.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `HANDLER-FORM` (form): A lambda `(lambda (error) ...)` to execute on failure.

Returns:
- `(concur-promise)`: A new promise."
  (declare (indent 1) (debug t))
  `(concur:then ,promise-form nil ,handler-form))

;;;###autoload
(defmacro concur:finally (promise-form callback-form)
  "Attach `CALLBACK-FORM` to run after `PROMISE-FORM` settles.
The callback executes regardless of whether the source promise resolved or
rejected. It is ideal for cleanup operations (e.g., closing files,
releasing locks).

The promise returned by `concur:finally` will adopt the outcome of the
original promise, unless the `CALLBACK-FORM` itself returns a rejected
promise or signals a Lisp error.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A nullary lambda `(lambda () ...)` to execute.

Returns:
- `(concur-promise)`: A new promise."
  (declare (indent 1) (debug t))
  (let ((p-sym (gensym "promise-"))
        (new-p-sym (gensym "new-promise-"))
        (val-sym (gensym "val-"))
        (err-sym (gensym "err-"))
        (cb-res-sym (gensym "callback-result-"))) ; To hold the result of the callback

    `(let* ((,p-sym ,promise-form)
            (,new-p-sym (concur:make-promise :parent-promise ,p-sym))) ; New promise from finally

       (concur-attach-then-callbacks
        ,p-sym
        ,new-p-sym

        ;; ON-RESOLVED handler for the original promise:
        (lambda (,new-p-sym ,val-sym) ; new-p-sym is the target promise for this handler
          (condition-case cb-err
              (let ((,cb-res-sym (funcall ,callback-form))) ; Execute the finally callback
                (if (concur-promise-p ,cb-res-sym)
                    ;; If callback returns a promise, assimilate its state.
                    ;; When it resolves, resolve new-p-sym with original value.
                    ;; When it rejects, reject new-p-sym with callback's error.
                    (concur:then ,cb-res-sym
                                 (lambda (_) (concur:resolve ,new-p-sym ,val-sym))
                                 (lambda (actual-cb-err) (concur:reject ,new-p-sym actual-cb-err)))
                  ;; If callback returns a non-promise, resolve new-p-sym with original value.
                  (concur:resolve ,new-p-sym ,val-sym)))
            ;; If callback signals a Lisp error, reject new-p-sym.
            (error
             (concur:reject ,new-p-sym
                            (concur:make-error
                             :type :callback-error
                             :message (format "Finally resolved handler failed: %S" cb-err)
                             :cause cb-err :promise ,new-p-sym)))))

        ;; ON-REJECTED handler for the original promise:
        (lambda (,new-p-sym ,err-sym) ; new-p-sym is the target promise for this handler
          (condition-case cb-err
              (let ((,cb-res-sym (funcall ,callback-form))) ; Execute the finally callback
                (if (concur-promise-p ,cb-res-sym)
                    ;; If callback returns a promise, assimilate its state.
                    ;; When it resolves, reject new-p-sym with original error.
                    ;; When it rejects, reject new-p-sym with callback's error (overrides original).
                    (concur:then ,cb-res-sym
                                 (lambda (_) (concur:reject ,new-p-sym ,err-sym))
                                 (lambda (actual-cb-err) (concur:reject ,new-p-sym actual-cb-err)))
                  ;; If callback returns a non-promise, reject new-p-sym with original error.
                  (concur:reject ,new-p-sym ,err-sym)))
            ;; If callback signals a Lisp error, reject new-p-sym.
            (error
             (concur:reject ,new-p-sym
                            (concur:make-error
                             :type :callback-error
                             :message (format "Finally rejected handler failed: %S" cb-err)
                             :cause cb-err :promise ,new-p-sym))))))
       ,new-p-sym)))

;;;###autoload
(defmacro concur:tap (promise-form callback-form)
  "Attach `CALLBACK-FORM` for side effects, without altering the promise chain.
This is useful for inspecting a promise's value or error at a certain
point in a chain without modifying it (e.g., for logging or debugging).
The returned promise will resolve or reject with the exact same value or
error as the original promise.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A lambda `(lambda (value error) ...)`. It is
  called with `(value, nil)` on success or `(nil, error)` on failure.

Returns:
- `(concur-promise)`: A new promise identical in outcome to the original."
  (declare (indent 1) (debug t))
  `(concur:then
    ,promise-form
    ;; on-resolved: run callback, pass original value through.
    (lambda (val) (funcall ,callback-form val nil) val)
    ;; on-rejected: run callback, re-throw original error.
    (lambda (err) (funcall ,callback-form nil err) (concur:rejected! err))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: High-Level Flow Control

;;;###autoload
(defmacro concur:chain (initial-value-expr &rest steps)
  "Thread `INITIAL-VALUE-EXPR` through a series of asynchronous steps.
This macro provides a powerful, readable way to compose complex
asynchronous workflows. It starts with an initial value (which is
lifted into a promise) and passes it through a series of `STEPS`.

Each step can be a form which is implicitly wrapped in a `:then`
handler, or it can be a keyword-based clause for more complex
operations. The anaphoric variable `<>` can be used in forms to
refer to the resolved value of the previous step.

Available Clauses:
- `(some-form ...)`: An S-expression to execute. Handled by `:then`.
- `(:then (lambda (val) ...))`: Attach a standard resolve handler.
- `(:catch (lambda (err) ...))`: Attach a standard rejection handler.
- `(:finally (lambda () ...))`: Attach a cleanup handler.
- `(:tap (lambda (val err) ...))`: Inspect the chain without altering it.
- `(:log \"format-string\")`: Tap the chain to log the current value/error.
- `(:sleep MS)`: Pause the chain for `MS` milliseconds.
- `(:await-all FORMS)`: Wait for all promises in `FORMS` to resolve.
- `(:await-race FORMS)`: Wait for the first promise in `FORMS` to resolve.
- `(:retry N FORM)`: Retry `FORM` up to `N` times on failure.
- `(:timeout MS &rest FORMS)`: Run sub-chain `FORMS` with a `MS` timeout.

Arguments:
- `INITIAL-VALUE-EXPR` (form): The value or promise to start the chain.
- `STEPS` (list): A list of step clauses.

Returns:
- `(concur-promise)`: A promise representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  `(concur--expand-chain-internal ,initial-value-expr ,steps nil))

;;;###autoload
(defmacro concur:chain-when (initial-value-expr &rest steps)
  "Like `concur:chain` but short-circuits if a step resolves to `nil`.
If any anaphoric step in the chain resolves to a `nil` value, all
subsequent anaphoric steps are skipped. Explicit clauses like `:then`,
`:catch`, and `:finally` will still execute. This is useful for
workflows where steps may fail gracefully by returning `nil`.

Arguments:
- `INITIAL-VALUE-EXPR` (form): The value or promise to start the chain.
- `STEPS` (list): A list of step clauses.

Returns:
- `(concur-promise)`: A promise representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  `(concur--expand-chain-internal ,initial-value-expr ,steps t))

(provide 'concur-chain)
;;; concur-chain.el ends here