;;; concur-chain.el --- Chaining and flow-control for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the primary user-facing API for composing and chaining
;; promises. It contains the fundamental `concur:then` macro for attaching
;; success and failure handlers, as well as higher-level convenience macros like
;; `concur:catch`, `concur:finally`, and the powerful `concur:chain` for
;; expressing complex asynchronous workflows in a clear, sequential manner.
;;
;; This module depends on `concur-ast.el` to correctly "lift" variables from
;; lexical closures, making them available across asynchronous boundaries. This
;; allows handlers to seamlessly use variables from their surrounding scope
;; without manual capturing.
;;
;; Architectural Highlights:
;;
;; - `concur:then`: The fundamental chaining primitive, which uses AST
;;   analysis to capture lexical environments, making asynchronous callbacks
;;   feel like natural closures.
;;
;; - `concur:chain`: A powerful "threading" macro that provides a readable,
;;   linear syntax for composing complex sequences of asynchronous operations,
;;   complete with syntactic sugar for common patterns.
;;
;; - Block Syntax for Sub-chains: Keywords that take a sequence of steps
;;   (like `:timeout`) support a natural, block-based syntax, improving
;;   readability by removing the need for explicit `(list ...)` wrappers.

;;; Code:

(require 'cl-lib)
(require 'dash)

(require 'concur-ast)
(require 'concur-core)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:all "concur-combinators" (promises-list &key mode))
(declare-function concur:race "concur-combinators" (promises-list &key mode))
(declare-function concur:timeout "concur-combinators"
                  (promise timeout-seconds))
(declare-function concur:delay "concur-combinators"
                  (seconds &optional value))
(declare-function concur:retry "concur-combinators"
                  (fn &key retries delay pred))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Macro Helpers (Compile-Time)

(eval-and-compile
  (defun concur--then-analyze-handlers (on-resolved-form on-rejected-form env)
    "Use the AST analyzer to prepare lexical context for `concur:then` handlers."
    (-let* ((resolved-analysis
             (concur-ast-analysis (or on-resolved-form '(lambda (val) val)) env))
            (rejected-analysis
             (concur-ast-analysis (or on-rejected-form
                                      '(lambda (err) (concur:rejected! err)))
                                  env))
            (all-vars
             (cl-delete-duplicates
              (append (concur-ast-analysis-result-free-vars-list resolved-analysis)
                      (concur-ast-analysis-result-free-vars-list
                       rejected-analysis))))
            (captured-vars-form (concur-ast-make-captured-vars-form all-vars)))
      `(:resolved-lambda
        ,(concur-ast-analysis-result-expanded-callable-form resolved-analysis)
        :resolved-vars
        ,(concur-ast-analysis-result-free-vars-list resolved-analysis)
        :rejected-lambda
        ,(concur-ast-analysis-result-expanded-callable-form rejected-analysis)
        :rejected-vars
        ,(concur-ast-analysis-result-free-vars-list rejected-analysis)
        :context-form ,captured-vars-form)))

  (defun concur--expand-sugar (steps)
    "Transform sugar keywords in `concur:chain` into canonical clauses."
    (let (processed)
      (while steps
        (let ((key (pop steps)) arg1 sub-chain)
          (pcase key
            ;; Keywords that take a block of steps (e.g., :timeout).
            ((or :timeout)
             (setq arg1 (pop steps))
             ;; Greedily consume all subsequent non-keyword forms as the sub-chain.
             (setq sub-chain (cl-loop for form in steps
                                      while (and form (not (keywordp form)))
                                      collect form))
             (setq steps (nthcdr (length sub-chain) steps))
             ;; If the sub-chain was wrapped in `(list ...)` for clarity,
             ;; unwrap it.
             (when (and (= 1 (length sub-chain)) (eq 'list (caar sub-chain)))
               (setq sub-chain (cdar sub-chain)))
             (pcase key
               (:timeout
                (push `(:then (lambda (<>)
                                (concur:timeout (concur:chain <> ,@sub-chain)
                                                ,arg1)))
                      processed))))

            ;; Keywords that take a single argument.
            ((or :await-all :await-race :if-then :map :filter :each :sleep :retry)
             (setq arg1 (pop steps))
             (pcase key
               (:await-all (push `(:then (lambda (<>) (concur:all ,arg1))) processed))
               (:await-race (push `(:then (lambda (<>) (concur:race ,arg1))) processed))
               (:if-then
                (let* ((then-form arg1)
                       (else-form (when (and steps (not (keywordp (car steps))))
                                    (pop steps))))
                  (push `(:then (lambda (<>)
                                  (if <> ,then-form ,(or else-form '<>))))
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

            ;; Keywords with optional arguments.
            (:log
             (let ((fmt (if (and steps (stringp (car steps))) (pop steps) "%S")))
               (push `(:tap (lambda (val err) (message ,fmt (or val err))))
                     processed)))

            ;; Default case for standard chain steps or implicit :then steps.
            (_ (push key processed)
               (when steps (push (pop steps) processed))))))
      (nreverse processed)))

  (defun concur--chain-process-single-step (current-promise-form step
                                             short-circuit-on-nil-p)
    "Generate the code for a single step in a `concur:chain` expansion."
    (let ((anaphoric-wrapper
           (lambda (body)
             `(lambda (<>) ,(if short-circuit-on-nil-p `(when <> ,body) body)))))
      (pcase step
        (`(:then ,handler)    `(concur:then ,current-promise-form ,handler))
        (`(:catch ,handler)   `(concur:catch ,current-promise-form ,handler))
        (`(:finally ,handler) `(concur:finally ,current-promise-form ,handler))
        (`(:tap ,handler)     `(concur:tap ,current-promise-form ,handler))
        (_ (if (listp step)
               `(concur:then ,current-promise-form
                             ,(funcall anaphoric-wrapper step))
             (error "Invalid concur:chain step: %S" step))))))

  (defmacro concur--expand-chain-internal (initial-promise-expr steps
                                            short-circuit-on-nil-p)
    "Internal helper to expand `concur:chain` and `concur:chain-when`."
    (let ((result-form `(concur:resolved! ,initial-promise-expr)))
      (dolist (step (concur--expand-sugar steps))
        (setq result-form
              (concur--chain-process-single-step result-form step
                                                 short-circuit-on-nil-p)))
      result-form))
) ; End of eval-and-compile

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Promise Chaining Primitives

;;;###autoload
(cl-defmacro concur:then (source-promise-form
                          &optional on-resolved-form on-rejected-form
                          &environment env)
  "Chain a new promise from `SOURCE-PROMISE-FORM`, transforming its result.
This is the fundamental promise chaining primitive, analogous to `.then()`
in JavaScript. It attaches success and failure handlers that execute
asynchronously when the source promise settles. Lexical variables from the
surrounding scope are automatically captured via AST analysis.

Arguments:
- `SOURCE-PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
- `ON-RESOLVED-FORM` (form, optional): A lambda `(lambda (value) ...)` or a
  function to handle success. The value it returns determines the resolution
  of the new promise. Defaults to an identity function `(lambda (v) v)`.
- `ON-REJECTED-FORM` (form, optional): A lambda `(lambda (error) ...)` or a
  function to handle failure. It can recover from an error by returning a
  normal value. Defaults to re-rejecting the original error.
- `ENV` (environment, implicit): The lexical environment at the macro call site.

Returns:
  (concur-promise) A new promise that resolves or rejects based on the
  outcome of the executed handler."
  (declare (indent 1) (debug t))
  (-let* (((&plist :resolved-lambda resolved-lambda
                   :resolved-vars resolved-vars
                   :rejected-lambda rejected-lambda
                   :rejected-vars rejected-vars
                   :context-form context-form)
           (concur--then-analyze-handlers on-resolved-form on-rejected-form env))
          (new-promise (gensym "new-promise")))
    `(let ((,new-promise
            (concur:make-promise :parent-promise ,source-promise-form)))
       (concur-attach-callbacks
        ,source-promise-form
        ;; Create the success callback.
        (concur-make-resolved-callback
         ,resolved-lambda ,new-promise :captured-vars ,resolved-vars
         :context ,context-form)
        ;; Create the failure callback.
        (concur-make-rejected-callback
         ,rejected-lambda ,new-promise :captured-vars ,rejected-vars
         :context ,context-form))
       ,new-promise)))

;;;###autoload
(defmacro concur:catch (promise-form handler-form)
  "Attach an error `HANDLER-FORM` to a promise.
This is a convenience alias for `(concur:then promise nil handler)`. It is
useful for handling failures without needing to provide a success case.
The `HANDLER-FORM` can 'recover' from the error by returning a regular value,
which will resolve the new promise.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `HANDLER-FORM` (form): A lambda `(lambda (error) ...)` or function symbol
  that will be executed if the promise is rejected.

Returns:
  (concur-promise) A new promise."
  (declare (indent 1) (debug t))
  `(concur:then ,promise-form nil ,handler-form))

;;;###autoload
(defmacro concur:finally (promise-form callback-form)
  "Attach `CALLBACK-FORM` to run after `PROMISE-FORM` settles.
The callback executes regardless of whether the source promise resolved or
rejected, making it ideal for cleanup operations (e.g., closing files,
releasing locks). The returned promise adopts the state of the original
promise, unless the `CALLBACK-FORM` itself errors.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A nullary lambda `(lambda () ...)` or function
  symbol to execute upon settlement.

Returns:
  (concur-promise) A new promise."
  (declare (indent 1) (debug t))
  `(concur:then
    ,promise-form
    ;; on-resolved: run callback, then pass original value through.
    (lambda (val)
      (concur:then (concur:resolved! (funcall ,callback-form))
                   (lambda (_) val)))
    ;; on-rejected: run callback, then re-throw original error.
    (lambda (err)
      (concur:then (concur:resolved! (funcall ,callback-form))
                   (lambda (_) (concur:rejected! err))))))

;;;###autoload
(defmacro concur:tap (promise-form callback-form)
  "Attach `CALLBACK-FORM` for side effects, without altering the promise chain.
This is useful for inspecting a promise's value or error at a certain
point in a chain without modifying it (e.g., for logging). The return
value of `CALLBACK-FORM` is ignored.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A lambda `(lambda (value error) ...)` or function
  symbol. It is called with `(value, nil)` on success or `(nil, error)` on failure.

Returns:
  (concur-promise) A new promise that resolves or rejects with the
  exact same value or error as the original promise."
  (declare (indent 1) (debug t))
  `(concur:then
    ,promise-form
    ;; on-resolved: run callback, pass original value through.
    (lambda (val)
      (funcall ,callback-form val nil)
      val)
    ;; on-rejected: run callback, re-throw original error.
    (lambda (err)
      (funcall ,callback-form nil err)
      (concur:rejected! err))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: High-Level Flow Control

;;;###autoload
(defmacro concur:chain (initial-promise-expr &rest steps)
  "Thread `INITIAL-PROMISE-EXPR` through a series of asynchronous steps.
This macro provides a readable, linear syntax for composing promises,
avoiding deeply nested `concur:then` calls ('callback hell').
The anaphoric variable `<>` holds the result of the previous step.

Arguments:
- `INITIAL-PROMISE-EXPR` (form): The promise or value to start the chain.
- `STEPS` (list): A list of step clauses. Supported clauses include:
  - `:then (lambda (<>) ...)`: Standard `then` handler.
  - `:catch (lambda (err) ...)`: Standard rejection handler.
  - `:finally (lambda () ...)`: Cleanup handler.
  - `:tap (lambda (val err) ...)`: Inspection handler.
  - `:await-all <form>`: `concur:all` on the result of `<form>`.
  - `:await-race <form>`: `concur:race` on the result of `<form>`.
  - `:sleep <ms>`: Delays the chain for <ms> milliseconds.
  - `:log [\"format\"]`: Logs the current value or error.
  - `:timeout <sec> <steps...>`: Applies a timeout to a sub-chain.
  - Any other form is treated as an implicit `:then` step.

Returns:
  (concur-promise) A promise representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  `(concur--expand-chain-internal ,initial-promise-expr ,steps nil))

;;;###autoload
(defmacro concur:chain-when (initial-promise-expr &rest steps)
  "Like `concur:chain` but short-circuits on `nil` resolved values.
If any promise in the chain resolves with a `nil` or `false` value,
subsequent value-transforming steps are skipped. Error and cleanup
handlers (`:catch`, `:finally`) will still execute.

Arguments:
- See `concur:chain`.

Returns:
  (concur-promise) A promise representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  `(concur--expand-chain-internal ,initial-promise-expr ,steps t))

(provide 'concur-chain)
;;; concur-chain.el ends here