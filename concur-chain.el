;;; concur-chain.el --- Chaining and flow-control for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the primary user-facing API for composing and chaining
;; promises. It contains the fundamental `concur:then` macro, convenience
;; wrappers like `concur:catch` and `concur:finally`, and the powerful
;; `concur:chain` macro for expressing complex asynchronous workflows in a
;; clear, sequential style.
;;
;; Architectural Highlights:
;; - Simplified Primitives: `concur:then` is now built directly on
;;   `concur:with-executor`, delegating complex lifecycle management to the
;;   core library for improved robustness and simplicity.
;; - Ergonomic Flow Control: The `concur:chain` macro provides a rich DSL
;;   for writing sequential-style async code, now including a powerful `:let`
;;   clause for binding results of async operations to variables.
;; - Native Closures: The library fully relies on standard Emacs Lisp lexical
;;   closures, ensuring robust and predictable behavior.

;;; Code:

(require 'cl-lib)
(require 'dash)

(require 'concur-core)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization

(defcustom concur-chain-anaphoric-symbol '<>
  "The anaphoric symbol to use in `concur:chain` steps.
This symbol will be bound to the resolved value of the previous step."
  :type 'symbol
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

;; These functions from `concur-combinators.el` are used in `concur:chain`.
(declare-function concur:all "concur-combinators")
(declare-function concur:race "concur-combinators")
(declare-function concur:timeout "concur-combinators")
(declare-function concur:delay "concur-combinators")
(declare-function concur:retry "concur-combinators")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Macro Helpers

;; `eval-and-compile` is necessary here because the `concur:chain` macro
;; needs these helper functions to be available at compile time to perform
;; its expansion.
(eval-and-compile
  (defun concur--chain-expand-let-step (binding-form body-forms short-circuit-p)
    "Expand a `:let` clause within a `concur:chain` macro.
This function creates a nested chain. It takes a BINDING-FORM, executes it,
binds its result to a variable, and then executes the BODY-FORMS within the
lexical scope of that binding.

Arguments:
- `BINDING-FORM` (form): A single binding `(VAR FORM)`.
- `BODY-FORMS` (list): The remaining steps of the `concur:chain`.
- `SHORT-CIRCUIT-P` (boolean): If non-nil, short-circuit on nil values.

Returns:
- `(form)`: The expanded Lisp form for this `:let` step."
    (let ((var (car binding-form))
          (form (cadr binding-form)))
      `(concur:then
        ,form
        (lambda (,var)
          ,(if short-circuit-p
               `(concur:chain-when ,var ,@body-forms)
             `(concur:chain ,var ,@body-forms))))))

  (defun concur--chain-expand-sugar (steps)
    "Transform syntactic sugar keywords in `concur:chain` into canonical clauses.
This function preprocesses the list of steps, converting keywords like
`:sleep`, `:log`, etc., into their equivalent `(:then ...)` or `(:tap ...)` forms.

Arguments:
- `STEPS` (list): The list of forms from a `concur:chain` macro call.

Returns:
- `(list)`: A new list of steps with all sugar expanded."
    (let (processed)
      (while steps
        (let ((key (pop steps)) arg1)
          (pcase key
            (:log
             (let ((fmt (if (and steps (stringp (car steps)))
                            (pop steps) "chain: %S")))
               (push `(:tap (lambda (val err)
                              (concur--log :info nil ,fmt (or val err))))
                     processed)))
            (:sleep
             (setq arg1 (pop steps))
             (push `(:then (lambda (val)
                             (concur:then (concur:delay (/ ,arg1 1000.0))
                                          (lambda (_) val))))
                   processed))
            (:retry
             (setq arg1 (pop steps))
             (let ((retry-form (pop steps)))
               (push `(:then (lambda (val)
                               (concur:retry (lambda () ,retry-form)
                                             :retries ,arg1)))
                     processed)))
            (_
             (push key processed)
             (when steps (push (pop steps) processed))))))
      (nreverse processed)))

  (defun concur--chain-expand-steps (promise-form steps short-circuit-p)
    "Recursively expand `concur:chain` steps into nested `concur:then` calls.

Arguments:
- `PROMISE-FORM` (form): Form evaluating to the promise from the previous step.
- `STEPS` (list): The remaining steps to expand.
- `SHORT-CIRCUIT-P` (boolean): If non-nil, short-circuit on nil values.

Returns:
- `(form)`: The fully expanded Lisp form for the promise chain."
    (if (null steps)
        promise-form
      (let* ((step (car steps))
             (rest-steps (cdr steps))
             (anaphor (intern (symbol-name concur-chain-anaphoric-symbol))))
        (pcase step
          (`(:let ,binding)
           ;; Let binding takes over the rest of the chain recursively.
           (let ((binding-form (if (consp (car-safe binding)) binding (list binding))))
             `(concur:then
               ,promise-form
               (lambda (,anaphor)
                 ,(concur--chain-expand-let-step
                   (car binding-form) rest-steps short-circuit-p)))))

          ((or `(:then ,_) `(:catch ,_) `(:finally ,_) `(:tap ,_))
           ;; For explicit clauses, wrap and recurse.
           (let ((next-promise `(,(car step) ,promise-form ,(cadr step))))
             (concur--chain-expand-steps next-promise rest-steps short-circuit-p)))

          ;; Default case: implicit `:then` with an anaphoric variable.
          (_
           (let ((next-promise
                  `(concur:then
                    ,promise-form
                    (lambda (,anaphor)
                      ,(if short-circuit-p
                           `(when ,anaphor ,step)
                         step)))))
             (concur--chain-expand-steps
              next-promise rest-steps short-circuit-p))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Core Chaining Primitives

;;;###autoload
(defmacro concur:then (source-promise-form
                       &optional on-resolved-form on-rejected-form)
  "Attach success and failure handlers to a promise, returning a new promise.
This is the fundamental operation for chaining, compliant with the
Promise/A+ specification. The returned promise is settled based on
the outcome of the executed handler:
- If a handler returns a value, the new promise is resolved with that value.
- If a handler returns another promise, the new promise 'assimilates' its
  state, eventually settling with the same outcome.
- If a handler signals an error, the new promise is rejected.

Arguments:
- `SOURCE-PROMISE-FORM` (form): A form evaluating to a `concur-promise`.
- `ON-RESOLVED-FORM` (form, optional): A lambda `(lambda (value) ...)` for
  the success case. Defaults to an identity function.
- `ON-REJECTED-FORM` (form, optional): A lambda `(lambda (error) ...)` for
  the failure case. Defaults to a function that re-throws the error.

Returns:
- `(concur-promise)`: A new promise representing the outcome of the handler."
  (declare (indent 1) (debug t))
  `(concur:with-executor (resolve reject)
     (let* ((on-resolved-handler
             (or ,on-resolved-form (lambda (value) value)))
            (on-rejected-handler
             (or ,on-rejected-form (lambda (err) (concur:rejected! err))))
            (source-promise ,source-promise-form))
       (unless (concur-promise-p source-promise)
         (error "concur:then expected a promise, but got %S" source-promise))

       (concur-attach-then-callbacks
        source-promise source-promise ; Source and target are the same here.
        ;; on-resolved: execute handler and resolve the new promise with its result.
        (lambda (value)
          (condition-case err
              (funcall resolve (funcall on-resolved-handler value))
            (error (funcall reject (concur:make-error :type :callback-error
                                                      :cause err)))))
        ;; on-rejected: execute handler and resolve the new promise with its result.
        (lambda (err)
          (condition-case err
              (funcall resolve (funcall on-rejected-handler err))
            (error (funcall reject (concur:make-error :type :callback-error
                                                      :cause err)))))))))

;;;###autoload
(defmacro concur:catch (promise-form handler-form)
  "Attach an error `HANDLER-FORM` to a promise.
This is a convenience alias for `(concur:then promise nil handler)`.
The handler can 'recover' from the error by returning a normal value,
which will resolve the new promise and allow the chain to continue.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `HANDLER-FORM` (form): A lambda `(lambda (error) ...)` to run on failure.

Returns:
- `(concur-promise)`: A new promise."
  (declare (indent 1) (debug t))
  `(concur:then ,promise-form nil ,handler-form))

;;;###autoload
(defmacro concur:finally (promise-form callback-form)
  "Attach a `CALLBACK-FORM` to run after a promise settles.
The callback executes regardless of whether the source promise resolved
or rejected, making it ideal for cleanup operations. The promise
returned by `concur:finally` will adopt the outcome of the original
promise, unless the callback itself fails.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A nullary lambda `(lambda () ...)` to execute.

Returns:
- `(concur-promise)`: A new promise."
  (declare (indent 1) (debug t))
  `(concur:then
    ,promise-form
    ;; on-resolved: run callback, then resolve with original value.
    (lambda (val)
      (concur:then (funcall ,callback-form) (lambda (_) val)))
    ;; on-rejected: run callback, then reject with original error.
    (lambda (err)
      (concur:then (funcall ,callback-form)
                   (lambda (_) (concur:rejected! err))))))

;;;###autoload
(defmacro concur:tap (promise-form callback-form)
  "Attach a `CALLBACK-FORM` for side effects, without altering the chain.
This is useful for inspecting a promise's value or error (e.g., for
logging) without modifying the outcome. The returned promise will
resolve or reject with the exact same value or error as the original.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a promise.
- `CALLBACK-FORM` (form): A lambda `(lambda (value error) ...)`. It is
  called with `(value, nil)` on success or `(nil, error)` on failure.

Returns:
- `(concur-promise)`: A new promise with the same outcome as the original."
  (declare (indent 1) (debug t))
  `(concur:then
    ,promise-form
    (lambda (val) (funcall ,callback-form val nil) val)
    (lambda (err) (funcall ,callback-form nil err) (concur:rejected! err))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: High-Level Flow Control

;;;###autoload
(defmacro concur:chain (initial-value-expr &rest steps)
  "Thread `INITIAL-VALUE-EXPR` through a series of asynchronous steps.
This macro provides a powerful, readable way to compose complex
asynchronous workflows. It starts with an initial value and passes
it through a series of `STEPS`.

Each step can be a form which is implicitly wrapped in a `:then`
handler, or it can be a keyword-based clause. The anaphoric
variable (default `<>`) refers to the resolved value of the previous step.

Available Clauses:
- `(some-form ...)`: An S-expression to execute. Handled by `:then`.
- `(:let (VAR FORM))`: Await `FORM` and bind its result to `VAR` for
  subsequent steps. This is the preferred way to write sequential logic.
- `(:then (lambda (val) ...))`: Attach a standard resolve handler.
- `(:catch (lambda (err) ...))`: Attach a standard rejection handler.
- `(:finally (lambda () ...))`: Attach a cleanup handler.
- `(:tap (lambda (val err) ...))`: Inspect the chain without altering it.
- `(:log \"format-string\")`: A shortcut to tap and log the current value/error.
- `(:sleep MS)`: Pause the chain for `MS` milliseconds.
- `(:retry N FORM)`: Retry `FORM` up to `N` times on failure.

Arguments:
- `INITIAL-VALUE-EXPR` (form): The value or promise to start the chain.
- `STEPS` (list): A list of step clauses.

Returns:
- `(concur-promise)`: A promise for the final outcome of the chain."
  (declare (indent 1) (debug t))
  (let ((sugared-steps (concur--chain-expand-sugar steps)))
    (concur--chain-expand-steps
     `(concur:resolved! ,initial-value-expr) sugared-steps nil)))

;;;###autoload
(defmacro concur:chain-when (initial-value-expr &rest steps)
  "Like `concur:chain`, but short-circuits if a step resolves to `nil`.
If any anaphoric step in the chain resolves to a `nil` value, all
subsequent anaphoric steps are skipped. Explicit clauses like `:then`,
`:catch`, and `:finally` will still execute.

Arguments:
- `INITIAL-VALUE-EXPR` (form): The value or promise to start the chain.
- `STEPS` (list): A list of step clauses.

Returns:
- `(concur-promise)`: A promise for the final outcome of the chain."
  (declare (indent 1) (debug t))
  (let ((sugared-steps (concur--chain-expand-sugar steps)))
    (concur--chain-expand-steps
     `(concur:resolved! ,initial-value-expr) sugared-steps t)))

(provide 'concur-chain)
;;; concur-chain.el ends here


;; ;;;###autoload
;; (defmacro concur:then (source-promise-form
;;                        &optional on-resolved-form on-rejected-form)
;;   "Attaches success and failure handlers to a promise, returning a new promise.
;; This is the fundamental operation for promise chaining, compliant with
;; the Promise/A+ specification.

;; The `on-resolved-form` and `on-rejected-form` are handler functions. The new
;; promise returned by `concur:then` is settled based on the outcome of
;; whichever handler is executed:
;; - If a handler returns a regular value, the new promise is resolved with
;;   that value.
;; - If a handler returns a promise (a 'thenable'), the new promise will
;;   'assimilate' its state, eventually resolving or rejecting with the same
;;   outcome.
;; - If a handler signals a Lisp error, the new promise is rejected with a
;;   `concur-callback-error`.

;; Arguments:
;; - `SOURCE-PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
;; - `ON-RESOLVED-FORM` (form, optional): A lambda `(lambda (value) ...)` for
;;   the success case. If nil, defaults to an identity function that passes
;;   the value through to the next promise in the chain.
;; - `ON-REJECTED-FORM` (form, optional): A lambda `(lambda (error) ...)` for
;;   the failure case. If nil, defaults to a function that re-jects the
;;   promise, propagating the error down the chain.

;; Returns:
;; - `(concur-promise)`: A new promise representing the outcome of the handler."
;;   (declare (indent 1) (debug t))
;;   (let* ((p-sym (gensym "source-promise-"))
;;          (new-p-sym (gensym "new-promise-"))
;;          ;; Gensyms for the handler arguments to prevent variable capture.
;;          (target-p-arg (gensym "target-p-"))
;;          (val-arg (gensym "val-"))
;;          (err-arg (gensym "err-")))

;;     ;; The macro will expand into this single `let*` block.
;;     `(let* ((,p-sym ,source-promise-form)
;;             (,new-p-sym (concur:make-promise :parent-promise ,p-sym)))

;;        ;; This function passes the source and *target* promises along with
;;        ;; the handler functions to the core system.
;;        (concur-attach-then-callbacks
;;         ,p-sym
;;         ,new-p-sym ;; Pass the newly created promise explicitly.

;;         ;; === ON-RESOLVED HANDLER ===
;;         ;; This is now a TWO-ARGUMENT lambda. When executed, the core will call
;;         ;; it with the target promise and the resolved value.
;;         (lambda (,target-p-arg ,val-arg)
;;           (condition-case err
;;               (let ((res (if ,on-resolved-form
;;                              (funcall ,on-resolved-form ,val-arg)
;;                            ,val-arg)))
;;                 ;; We use `target-p-arg`, the promise passed in at runtime.
;;                 (concur:resolve ,target-p-arg res))
;;             (error
;;              (concur:reject ,target-p-arg
;;                             (concur:make-error
;;                              :type :callback-error
;;                              :message (format "Resolved handler failed: %S" err)
;;                              :cause err :promise ,target-p-arg)))))

;;         ;; === ON-REJECTED HANDLER ===
;;         ;; This is also a TWO-ARGUMENT lambda.
;;         (lambda (,target-p-arg ,err-arg)
;;           (condition-case handler-err
;;               (if ,on-rejected-form
;;                   (let ((res (funcall ,on-rejected-form ,err-arg)))
;;                     (concur:resolve ,target-p-arg res))
;;                 ;; Default behavior: propagate rejection to the target promise.
;;                 (concur:reject ,target-p-arg ,err-arg))
;;             (error
;;              (concur:reject ,target-p-arg
;;                             (concur:make-error
;;                              :type :callback-error
;;                              :message (format "Rejected handler failed: %S" handler-err)
;;                              :cause handler-err :promise ,target-p-arg))))))
;;        ,new-p-sym)))
