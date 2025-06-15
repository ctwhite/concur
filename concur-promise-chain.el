;;; concur-promise-chain.el --- Chaining and flow-control for Concur Promises
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the primary user-facing API for composing and chaining
;; promises. It contains the fundamental `concur:then` macro for attaching
;; success and failure handlers, as well as higher-level convenience macros like
;; `concur:catch`, `concur:finally`, `concur:tap`, and the powerful `concur:chain`
;; for expressing complex asynchronous workflows in a clear, sequential manner.
;;
;; This module depends on `concur-ast.el` to correctly "lift" variables from
;; lexical closures, making them available across asynchronous boundaries.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-promise-core)
(require 'concur-hooks)
(require 'concur-ast)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Compile-Time Macro Logic

;; These helpers are called by the macros during compilation. They must be
;; defined within `eval-and-compile` to be available to the byte-compiler.
(eval-and-compile
  (require 'concur-ast)

  (defun concur--process-handler (handler-form handler-type initial-param-bindings)
    "Process a handler form (lambda or function symbol) at macro-expansion time.
This function is the bridge to the AST lifter. It takes a handler form,
analyzes it, and returns a new form ready for inclusion in a macro expansion.

Arguments:
- HANDLER-FORM: The user-provided Lisp form, e.g., `(lambda (v) v)`.
- HANDLER-TYPE: A string describing the handler type, for logging.
- INITIAL-PARAM-BINDINGS: An alist mapping parameter symbols to themselves,
  to prevent the AST lifter from treating them as free variables.

Returns:
A cons cell `(LIFTED-LAMBDA . FREE-VARS-LIST)`."
    (pcase handler-form
      ;; Case 1: A raw lambda form. Lift its free variables.
      (`(lambda . ,_)
       (concur-ast-lift-lambda-form handler-form initial-param-bindings))
      ;; Case 2: A function symbol reference like #'foo. Wrap it in a lambda.
      (`(function ,sym)
       (let* ((arg-names (mapcar #'car initial-param-bindings))
              (extra-data-sym (gensym "extra-data")))
         (list `(lambda (,@arg-names ,extra-data-sym)
                  (funcall #',sym ,@arg-names))
               nil)))
      ;; Case 3: A `nil` handler. Substitute a default implementation.
      ('nil
       (list (if (string= handler-type "resolved")
                 '(lambda (val extra-data) val)
               '(lambda (err extra-data) (concur:rejected! err)))
             nil))
      ;; Case 4: A quoted form like '(lambda ...). Process the quoted content.
      (`(quote ,quoted-form)
       (concur--process-handler quoted-form handler-type initial-param-bindings))
      (_ (error "concur:%s: Invalid handler form: %S" handler-type handler-form))))

  (defun concur--process-callback (callback-form cb-type initial-param-bindings)
    "Process a general callback form for `finally` and `tap`.
This is a wrapper around `concur--process-handler`.

Arguments:
- CALLBACK-FORM: The user-provided Lisp form.
- CB-TYPE: A string describing the callback type, for logging.
- INITIAL-PARAM-BINDINGS: An alist of parameter symbols.

Returns:
A cons cell `(LIFTED-LAMBDA . FREE-VARS-LIST)`."
    (pcase callback-form
      (`(lambda . ,_)
       (concur-ast-lift-lambda-form callback-form initial-param-bindings))
      (`(function ,sym)
       (let* ((arg-names (mapcar #'car initial-param-bindings))
              (extra-data-sym (gensym "extra-data")))
         (list `(lambda (,@arg-names ,extra-data-sym) (funcall #',sym ,@arg-names))
               nil)))
      ('nil (list '(lambda (&rest _args) nil) nil))
      (`(quote ,quoted-form)
       (concur--process-callback quoted-form cb-type initial-param-bindings))
      (_ (error "concur:%s: Invalid callback form: %S" cb-type callback-form))))

  (defun concur--prepare-handler-params (handler-form default-form handler-type)
    "Prepare a handler at macro-expansion time, parsing params and lifting.
Arguments:
- HANDLER-FORM: The user-provided Lisp form, e.g., `(lambda (v) v)`.
- DEFAULT-FORM: The default lambda to use if HANDLER-FORM is nil.
- HANDLER-TYPE: A string (e.g., \"resolved\") for logging and errors.
Returns:
A plist with keys `:lifted-form` and `:captured-vars`."
    (let* ((final-form (or handler-form default-form))
           (params (if (and (consp final-form) (eq (car final-form) 'lambda))
                       (cadr final-form) nil))
           (param-names (if (listp params) params (if params (list params) nil)))
           (param-alist (mapcar (lambda (p) (cons p p)) param-names))
           (handler-info (concur--process-handler final-form handler-type param-alist))
           (lifted-form (car handler-info))
           (captured-vars (cdr handler-info)))
      (list :lifted-form lifted-form :captured-vars captured-vars)))

  (defun concur--prepare-then-macro-data (on-resolved-form on-rejected-form)
    "Prepare all data needed for the `concur:then` macro expansion.
Arguments:
- ON-RESOLVED-FORM: The user-provided form for the resolved handler.
- ON-REJECTED-FORM: The user-provided form for the rejected handler.
Returns:
A plist containing all necessary symbols and forms for the macro."
    (let* ((source-promise-sym (gensym "source-promise"))
           (new-promise-sym (gensym "new-promise"))
           (resolved-data
            (concur--prepare-handler-params on-resolved-form
                                            '(lambda (val) val) "resolved"))
           (rejected-data
            (concur--prepare-handler-params on-rejected-form
                                            '(lambda (err) (concur:rejected! err)) "rejected"))
           (lifted-resolved-form (plist-get resolved-data :lifted-form))
           (resolved-vars (plist-get resolved-data :captured-vars))
           (lifted-rejected-form (plist-get rejected-data :lifted-form))
           (rejected-vars (plist-get rejected-data :captured-vars))
           (captured-vars-form
            (let ((all-vars (cl-delete-duplicates (append resolved-vars rejected-vars))))
              `(list ,@(mapcar (lambda (v) `(cons ',v ,v)) all-vars)))))
      `(:source-promise-sym ,source-promise-sym
        :new-promise-sym ,new-promise-sym
        :lifted-resolved-fn ,lifted-resolved-form
        :lifted-rejected-fn ,lifted-rejected-form
        :captured-vars-form ,captured-vars-form)))

  (defun concur--expand-sugar (steps)
    "Transform sugar keywords in `concur:chain` STEPS into canonical clauses."
    (let ((processed nil)
          (remaining steps))
      (while remaining
        (let ((key (pop remaining)) arg1 arg2)
          (pcase key
            (:map (setq arg1 (pop remaining))
                  (push `(:then (lambda (list-val) (--map ,arg1 list-val)))
                        processed))
            (:filter (setq arg1 (pop remaining))
                     (push `(:then (lambda (list-val) (--filter ,arg1 list-val)))
                           processed))
            (:each (setq arg1 (pop remaining))
                   (push `(:then (lambda (list-val)
                                   (prog1 list-val (--each ,arg1 list-val))))
                         processed))
            (:sleep (setq arg1 (pop remaining))
                    (push `(:then (lambda (val)
                                    (concur:then (concur:delay (/ ,arg1 1000.0))
                                                 (lambda (_) val))))
                          processed))
            (:log (let ((fmt (if (and remaining (stringp (car remaining)))
                                 (pop remaining) "%S")))
                    (push `(:tap (lambda (val err) (message ,fmt (or val err))))
                          processed)))
            (:retry (setq arg1 (pop remaining)) (setq arg2 (pop remaining))
                    (push `(:then (lambda (<>)
                                    (concur:retry (lambda () ,arg2)
                                                  :retries ,arg1)))
                          processed))
            (_ (push key processed) (when remaining (push (pop remaining) processed))))))
      (nreverse processed)))

  (defun concur--chain-process-single-step-form (current-form step when-p prefix)
    "Helper to expand a single step in a `concur:chain` or `chain-when`."
    (let ((step-name (if (listp step) (car step) 'lambda)))
      (pcase step
        (`(:then ,arg)
         (let ((val (gensym "val-")))
           `(concur:then ,current-form
                         (lambda (,val)
                           (let ((<> ,val))
                             (if ,when-p (when <> ,arg) ,arg))))))
        (`(:catch ,arg)
         (let ((err (gensym "err-")))
           `(concur:then ,current-form nil
                         (lambda (,err) (let ((<!> ,err)) ,arg)))))
        (`(:finally ,arg)
         `(concur:finally ,current-form (lambda () ,arg)))
        (`(:tap ,arg)
         (let ((val (gensym "val-")) (err (gensym "err-")))
           `(concur:tap ,current-form
                        (lambda (,val ,err)
                          (let ((<> ,val) (<!> ,err))
                            (if ,when-p (when <> ,arg) ,arg))))))
        (`(:all ,arg) `(concur:all ,arg))
        (`(:race ,arg) `(concur:race ,arg))
        (`(<>))
        (_ (if (listp step)
               (let ((val (gensym "val-")))
                 (if (eq (car step) 'lambda)
                     (if when-p
                         `(concur:then ,current-form
                                       (lambda (,val) (when ,val (funcall ,step ,val))))
                       `(concur:then ,current-form ,step))
                   (if when-p
                       `(concur:then ,current-form
                                     (lambda (,val) (let ((<> ,val)) (when <> ,step))))
                     `(concur:then ,current-form
                                   (lambda (,val) (let ((<> ,val)) ,step))))))
             (error "%sInvalid concur:chain step: %S" prefix step))))))

) ; End of eval-and-compile block

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Promise Chaining and Flow Control

(defmacro concur:then (source-promise-form
                       &optional on-resolved-form on-rejected-form)
  "Chain a new promise from SOURCE-PROMISE-FORM, transforming its result.
This is the fundamental promise chaining primitive. It returns a new promise
that will be resolved or rejected based on the outcome of the handlers.

This macro uses an AST transformation step to find and 'lift' any lexically
free variables from the provided handler lambdas, ensuring they are
available when the asynchronous callbacks are executed.

Arguments:
- SOURCE-PROMISE-FORM: A form that evaluates to a `concur-promise`.
- ON-RESOLVED-FORM (form, optional): A lambda `(lambda (value) ...)` or
  function symbol called when the source promise resolves. Its return value
  becomes the resolved value of the new promise. Defaults to an identity
  function `(lambda (val) val)`.
- ON-REJECTED-FORM (form, optional): A lambda `(lambda (error) ...)` or
  function symbol called when the source promise rejects. Its return value
  (or a new rejection) determines the state of the new promise. Defaults
  to a function that re-rejects the promise.

Returns:
A new `concur-promise` representing the chained operation."
  (declare (indent 1) (debug t))
  ;; Use -let* to call the helper and destructure the results into local
  ;; variables, making the macro's body clean and declarative.
  (-let* (((&plist :source-promise-sym source-promise-sym
                   :new-promise-sym new-promise-sym
                   :lifted-resolved-fn lifted-resolved-handler-form
                   :lifted-rejected-fn lifted-rejected-handler-form
                   :captured-vars-form captured-vars-alist-form)
           ;; All preparation logic is now encapsulated in this one call.
           (concur--prepare-then-macro-data on-resolved-form on-rejected-form)))

    ;; The body of the macro is now just the final code assembly.
    `(let ((,source-promise-sym ,source-promise-form)
           (lifted-resolved-fn ,lifted-resolved-handler-form)
           (lifted-rejected-fn ,lifted-rejected-handler-form))
       (let ((,new-promise-sym (concur:make-promise)))
         ;; At runtime, build the full `extra-data` alist.
         (let ((extra-data
                (append (list (cons 'handler-target-promise ,new-promise-sym)
                              (cons 'source-promise ,source-promise-sym)
                              (cons 'internal--lifted-resolved-fn lifted-resolved-fn)
                              (cons 'internal--lifted-rejected-fn lifted-rejected-fn))
                        ,captured-vars-alist-form)))
           (concur--on-resolve
            ,source-promise-sym
            (concur--make-resolved-callback
             (lambda (value extra-data)
               (let* ((h-target-promise
                       (cdr (assoc 'handler-target-promise extra-data)))
                      (user-handler-fn
                       (cdr (assoc 'internal--lifted-resolved-fn extra-data))))
                 (condition-case err
                     (concur--resolve-with-maybe-promise
                      h-target-promise
                      (funcall user-handler-fn value extra-data))
                   (error (concur:reject h-target-promise err)))))
             ,new-promise-sym :context extra-data)
            (concur--make-rejected-callback
             (lambda (error extra-data)
               (let* ((h-target-promise
                       (cdr (assoc 'handler-target-promise extra-data)))
                      (user-handler-fn
                       (cdr (assoc 'internal--lifted-rejected-fn extra-data))))
                 (condition-case err-in-handler
                     (concur--resolve-with-maybe-promise
                      h-target-promise
                      (funcall user-handler-fn error extra-data))
                   (error (concur:reject h-target-promise err-in-handler)))))
             ,new-promise-sym :context extra-data)))
         ,new-promise-sym))))

;;;###autoload
(defmacro concur:catch (caught-promise-form handler-form)
  "Attach an error HANDLER-FORM to CAUGHT-PROMISE-FORM.
This is a convenience alias for `(concur:then promise nil handler)`.

Arguments:
- CAUGHT-PROMISE-FORM: A form that evaluates to a `concur-promise`.
- HANDLER-FORM: A lambda `(lambda (error) ...)` or function symbol that
  is called if the promise rejects.

Returns:
A new `concur-promise`."
  (declare (indent 1) (debug t))
  `(concur:then ,caught-promise-form nil ,handler-form))

(defmacro concur:finally (final-promise-form callback-form)
  "Attach CALLBACK-FORM to run after FINAL-PROMISE-FORM settles.
This runs regardless of outcome. The returned promise adopts the state of the
original promise, unless the `callback-form` itself fails or rejects.

Arguments:
- FINAL-PROMISE-FORM: A form evaluating to a `concur-promise`.
- CALLBACK-FORM: A lambda `(lambda () ...)` or function symbol called when
  the promise settles.

Returns:
A new `concur-promise` that settles with the same value/error as the
`final-promise-form`, after the `callback-form` has completed."
  (declare (indent 1) (debug t))
  `(concur:then
    ,final-promise-form
    ;; on-resolved:
    (lambda (val)
      ;; Run the callback, then chain to a new promise that resolves
      ;; with the *original* value.
      (concur:then (funcall ,callback-form)
                   (lambda (_) val)))
    ;; on-rejected:
    (lambda (err)
      ;; Run the callback, then chain to a new promise that re-rejects
      ;; with the *original* error.
      (concur:then (funcall ,callback-form)
                   (lambda (_) (concur:rejected! err))))))

(defmacro concur:tap (tapped-promise-form callback-form)
  "Attach CALLBACK-FORM for side effects, without altering the promise chain.
This is useful for logging or debugging. The return value and any errors from
the callback are ignored.

Arguments:
- TAPPED-PROMISE-FORM: A form evaluating to a `concur-promise`.
- CALLBACK-FORM: A lambda `(lambda (value error) ...)` or function symbol.
  `value` is non-nil on resolution, `error` is non-nil on rejection.

Returns:
A new `concur-promise` that settles with the identical state as the original."
  (declare (indent 1) (debug t))
  `(concur:then
    ,tapped-promise-form
    ;; on-resolved:
    (lambda (val)
      (funcall ,callback-form val nil)
      ;; Always return the original value to continue the chain unaltered.
      val)
    ;; on-rejected:
    (lambda (err)
      (funcall ,callback-form nil err)
      ;; Always re-reject with the original error.
      (concur:rejected! err))))

(defmacro concur:chain (initial-promise-expr &rest steps)
  "Thread `INITIAL-PROMISE-EXPR` through a series of asynchronous steps.
This provides a readable, linear syntax for chaining promises.

Supported steps:
- `:then (lambda (val) ...)`: Transforms the resolved value.
- `:catch (lambda (err) ...)`: Handles a rejection, can recover.
- `:finally (lambda () ...)`: Runs a side-effecting callback when settled.
- `:tap (lambda (val err) ...)`: Side-effecting callback, ignores result.
- `:all (list-of-promises)`: Waits for all promises in a list.
- `:race (list-of-promises)`: Waits for the first promise to settle.
- `:sleep (ms)`: Delays the chain.
- `:log (fmt)`: Logs the current value/error.
- `:retry (n fn)`: Retries an async function `fn` up to `n` times.
- `:let ((v e) ...)`: Lexical bindings for subsequent steps.

Anaphoric variables `<>` (value) and `<!>` (error) are bound in steps.

Arguments:
- INITIAL-PROMISE-EXPR: The promise or value to start the chain.
- STEPS: A list of step clauses.

Returns:
A `concur-promise` representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  (let* ((sugared-steps (concur--expand-sugar steps))
         (result-form initial-promise-expr)
         (current-remaining-steps sugared-steps))
    (while current-remaining-steps
      (let* ((step (pop current-remaining-steps))
             (temp-result-form result-form))
        (cond
         ((eq (car step) :let)
          (let ((bindings (cadr step)))
            (let ((inner-chain-accumulator temp-result-form)
                  (inner-remaining-steps current-remaining-steps))
              (while inner-remaining-steps
                (setq inner-chain-accumulator
                      (concur--chain-process-single-step-form
                       inner-chain-accumulator (pop inner-remaining-steps)
                       nil "Internal :let ")))
              (setq result-form `(let* ,bindings ,inner-chain-accumulator)))
            (setq current-remaining-steps nil)))
         (t
          (setq result-form
                (concur--chain-process-single-step-form
                 temp-result-form step nil ""))))))
    result-form))

(defmacro concur:chain-when (initial-promise-expr &rest steps)
  "Like `concur:chain` but short-circuits on `nil` resolved values.
If a promise in the chain resolves with `nil`, subsequent `:then` steps
are skipped. Error handling (`:catch`, `:finally`) still executes.

Arguments:
- INITIAL-PROMISE-EXPR: The initial promise or value.
- STEPS: A list of step clauses.

Returns:
A `concur-promise` representing the final outcome of the chain."
  (declare (indent 1) (debug t))
  (let* ((sugared-steps (concur--expand-sugar steps))
         (result-form initial-promise-expr)
         (current-remaining-steps sugared-steps))
    (while current-remaining-steps
      (let* ((step (pop current-remaining-steps))
             (temp-result-form result-form))
        (cond
         ((eq (car step) :let)
          (let ((bindings (cadr step)))
            (let ((inner-chain-accumulator temp-result-form)
                  (inner-remaining-steps current-remaining-steps))
              (while inner-remaining-steps
                (setq inner-chain-accumulator
                      (concur--chain-process-single-step-form
                       inner-chain-accumulator (pop inner-remaining-steps)
                       t "Internal :let (chain-when) ")))
              (setq result-form `(let* ,bindings ,inner-chain-accumulator)))
            (setq current-remaining-steps nil)))
         (t
          (setq result-form
                (concur--chain-process-single-step-form
                 temp-result-form step t ""))))))
    result-form))

(provide 'concur-promise-chain)
;;; concur-promise-chain.el ends here