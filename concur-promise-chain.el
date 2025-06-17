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

;; All of these functions are helpers for macros and need to be available
;; to the byte-compiler.
(eval-and-compile
  (require 'concur-ast)

  (defun concur--safe-ht-get (hash-table key &optional default)
    "Safely get `KEY` from `HASH-TABLE`, returning `DEFAULT` if not a hash
    table or key not found.

    Arguments:
    - `hash-table`: The hash table to query.
    - `key`: The key to look up.
    - `default`: (optional) The value to return if `hash-table` is not a hash
      table or `key` is not found.

    Returns:
    The value associated with `key`, or `DEFAULT`."
    (if (hash-table-p hash-table)
        (gethash key hash-table default)
      default))

  (defun concur--prepare-then-macro-data (on-resolved-form on-rejected-form env)
    "Prepare data for `concur:then` using the read-only AST analyzer.

    This function orchestrates the analysis of resolved and rejected handler
    forms, identifies their free variables, and prepares the necessary code
    to capture these variables into a runtime context hash table.

    Arguments:
    - `on-resolved-form`: The user-provided form for the resolved handler.
      Defaults to `(lambda (val) val)`.
    - `on-rejected-form`: The user-provided form for the rejected handler.
      Defaults to `(lambda (err) (concur:rejected! err))`.
    - `env`: The lexical environment captured by the calling macro, used
      for `macroexpand-all`.

    Returns:
    A plist containing:
    - `:source-promise-sym`: A generated symbol for the source promise.
    - `:new-promise-sym`: A generated symbol for the new promise created by `concur:then`.
    - `:original-resolved-lambda`: The expanded resolved handler lambda.
    - `:resolved-vars`: A list of original symbols identified as free variables
      in the resolved handler.
    - `:original-rejected-lambda`: The expanded rejected handler lambda.
    - `:rejected-vars`: A list of original symbols identified as free variables
      in the rejected handler.
    - `:captured-vars-form`: The Lisp code (a `let` block) to create and populate
      a hash table with the values of all combined free variables."
    (-let* ((source-promise-sym (gensym "source-promise"))
            (new-promise-sym (gensym "new-promise"))

            ;; Analyze the resolved handler using the centralized AST analysis function.
            (resolved-analysis (concur-ast-analysis
                                (or on-resolved-form '(lambda (val) val))
                                env))

            ;; Analyze the rejected handler using the centralized AST analysis function.
            (rejected-analysis (concur-ast-analysis
                                (or on-rejected-form '(lambda (err) (concur:rejected! err)))
                                env))

            ;; Combine all free variables from both handlers.
            (all-vars (cl-delete-duplicates
                       (append (concur-ast-analysis-result-free-vars-list resolved-analysis)
                               (concur-ast-analysis-result-free-vars-list rejected-analysis))))

            ;; Generate the Lisp code for the context hash table from all combined free variables.
            (captured-vars-form (concur-ast-make-captured-vars-form all-vars)))

    ;; ADD THIS LOG HERE:
    (message "DEBUG: resolved-analysis: %S (type %S), rejected-analysis: %S (type %S)"
             resolved-analysis (type-of resolved-analysis)
             rejected-analysis (type-of rejected-analysis))
             
      ;; Return all the pieces the macro needs to build the final code.
      `(:source-promise-sym ,source-promise-sym
        :new-promise-sym ,new-promise-sym
        :original-resolved-lambda
        ,(concur-ast-analysis-result-expanded-callable-form resolved-analysis)
        :resolved-vars
        ,(concur-ast-analysis-result-free-vars-list resolved-analysis)
        :original-rejected-lambda
        ,(concur-ast-analysis-result-expanded-callable-form rejected-analysis)
        :rejected-vars
        ,(concur-ast-analysis-result-free-vars-list rejected-analysis)
        :captured-vars-form ,captured-vars-form)))

  (defun concur--expand-sugar (steps)
    "Transform sugar keywords in `concur:chain` `STEPS` into canonical clauses.

    Arguments:
    - `steps`: A list of step clauses from `concur:chain`.

    Returns:
    A list of canonical `concur:then`, `concur:catch`, etc., clauses."
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
    "Helper to expand a single step in a `concur:chain` or `concur:chain-when`.

    Arguments:
    - `current-form`: The promise form representing the current state of the chain.
    - `step`: A single step clause (e.g., `(:then handler)`, `(expression)`).
    - `when-p`: Non-nil if this is a `concur:chain-when` context (skips `:then` on `nil`).
    - `prefix`: A string prefix for error messages, indicating the macro context.

    Returns:
    The expanded Lisp form for this step."
    (let* ((anaphoric-lambda
            (lambda (handler-body)
              (let ((lambda-body `(let ((<> <>)) ,handler-body)))
                `(lambda (<>) ,(if when-p `(when <> ,lambda-body) lambda-body))))))
      (pcase step
        ;; Explicit clauses like :then, :catch just pass through.
        (`(:then ,handler)     `(concur:then ,current-form ,handler))
        (`(:catch ,handler)    `(concur:catch ,current-form ,handler))
        (`(:finally ,handler)  `(concur:finally ,current-form ,handler))
        (`(:tap ,handler)      `(concur:tap ,current-form ,handler))
        (`(:all ,promises)     `(concur:all ,promises))
        (`(:race ,promises)    `(concur:race ,promises))

        ;; This handles implicit :then steps, e.g., `(message "%s" <>)`
        (_ (if (listp step)
               `(concur:then ,current-form ,(funcall anaphoric-lambda step))
             (error "%sInvalid concur:chain step: %S" prefix step))))))

) ; End of eval-and-compile block

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Promise Chaining and Flow Control

(cl-defmacro concur:then (source-promise-form
                         &optional on-resolved-form on-rejected-form
                         &environment env)
  "Chain a new promise from `SOURCE-PROMISE-FORM`, transforming its result.

  This is the fundamental promise chaining primitive. It allows attaching
  success and failure handlers that execute asynchronously when the source
  promise settles. Lexical variables from the `concur:then`'s macro expansion
  environment are automatically captured and made available to handlers.

  Arguments:
  - `source-promise-form`: A form that evaluates to a `concur-promise`.
  - `on-resolved-form`: (optional) A lambda `(lambda (value) ...)` or a
    function symbol. Called if `source-promise-form` resolves successfully.
    Defaults to `(lambda (val) val)`.
  - `on-rejected-form`: (optional) A lambda `(lambda (error) ...)` or a
    function symbol. Called if `source-promise-form` rejects. It can recover
    from errors by resolving to a value or another promise. Defaults to
    `(lambda (err) (concur:rejected! err))`.
  - `env`: (Implicit) The lexical environment for macro expansion.

  Returns:
  A new `concur-promise` that resolves or rejects based on the outcome
  of the handlers."
  (declare (indent 1) (debug t))
  ;; --- STEP 1: Analyze user code and prepare all components first. ---
  (-let* (((&plist :original-resolved-lambda original-resolved-lambda
                   :resolved-vars resolved-vars
                   :original-rejected-lambda original-rejected-lambda
                   :rejected-vars rejected-vars
                   :captured-vars-form captured-vars-context-form)
           (concur--prepare-then-macro-data
            on-resolved-form on-rejected-form env))
          (new-promise-sym (gensym "new-promise"))
          (err-sym (gensym "err-"))) ; Gensym for `err` in condition-case

    (let ((err-in-handler-sym (gensym "err-in-handler-"))) ; Gensym for `err-in-handler`

      ;; --- STEP 2: Assemble the final code structure. ---
      `(let ((,new-promise-sym (concur:make-promise)))
         (concur--on-resolve
          ,source-promise-form
          (concur--make-resolved-callback
           (lambda (value context) ; `context` here is the hash table or nil from captured-vars-context-form
             (condition-case ,err-sym ; Use the gensym'd error variable for macro hygiene
                 (concur--resolve-with-maybe-promise
                  ,new-promise-sym
                  (let ,(cl-loop for var in resolved-vars
                                 ;; Ensure context is a hash-table before using gethash
                                 collect `(,var (concur--safe-ht-get context ',var)))
                    (funcall ,original-resolved-lambda value)))
               (error (concur:reject ,new-promise-sym `(executor-error :original-error ,,err-sym)))))
           ,new-promise-sym :captured-vars ,captured-vars-context-form)
          (concur--make-rejected-callback
           (lambda (error context) ; `context` here is the hash table or nil from captured-vars-context-form
             (condition-case ,err-in-handler-sym ; Use the gensym'd error variable for macro hygiene
                 (concur--resolve-with-maybe-promise
                  ,new-promise-sym
                  (let ,(cl-loop for var in rejected-vars
                                 ;; Ensure context is a hash-table before using gethash
                                 collect `(,var (concur--safe-ht-get context ',var)))
                    (funcall ,original-rejected-lambda error)))
               (error (concur:reject ,new-promise-sym `(executor-error :original-error ,,err-in-handler-sym)))))
           ,new-promise-sym  :captured-vars ,captured-vars-context-form))
         ,new-promise-sym))))

;;;###autoload
(defmacro concur:catch (caught-promise-form handler-form)
  "Attach an error `HANDLER-FORM` to `CAUGHT-PROMISE-FORM`.

  This is a convenience alias for `(concur:then promise nil handler)`.

  Arguments:
  - `caught-promise-form`: A form that evaluates to a `concur-promise`.
  - `handler-form`: A lambda `(lambda (error) ...)` or function symbol that
    is called if the promise rejects.

  Returns:
  A new `concur-promise`."
  (declare (indent 1) (debug t))
  `(concur:then ,caught-promise-form nil ,handler-form))

(defmacro concur:finally (final-promise-form callback-form)
  "Attach `CALLBACK-FORM` to run after `FINAL-PROMISE-FORM` settles.

  This runs regardless of outcome. The returned promise adopts the state of the
  original promise, unless the `callback-form` itself fails or rejects.

  Arguments:
  - `final-promise-form`: A form evaluating to a `concur-promise`.
  - `callback-form`: A lambda `(lambda () ...)` or function symbol called when
    the promise settles.

  Returns:
  A new `concur-promise` that settles with the same value/error as the
  `final-promise-form`, after the `callback-form` has completed."
  (declare (indent 1) (debug t))
  `(concur:then
    ,final-promise-form
    ;; on-resolved:
    (lambda (val)
      ;; We must wait for the callback to complete before passing through the
      ;; original value. By wrapping the funcall in `concur:resolved!`, we get
      ;; a promise that resolves when the callback is done. This also handles
      ;; the case where the callback itself might return a promise for async cleanup.
      (concur:then (concur:resolved! (funcall ,callback-form))
                   ;; Once the callback is done, this lambda ignores its result (_)
                   ;; and resolves with the *original* value.
                   (lambda (_) val)))
    ;; on-rejected:
    (lambda (err)
      (funcall ,callback-form nil err)
      ;; Always re-reject with the original error.
      (concur:then (concur:resolved! (funcall ,callback-form))
                   ;; Once the callback is done, this lambda ignores its result (_)
                   ;; and re-rejects with the *original* error.
                   (lambda (_) (concur:rejected! err))))))

(defmacro concur:tap (tapped-promise-form callback-form)
  "Attach `CALLBACK-FORM` for side effects, without altering the promise chain.

  This is useful for logging or debugging. The return value and any errors from
  the callback are ignored.

  Arguments:
  - `tapped-promise-form`: A form evaluating to a `concur-promise`.
  - `callback-form`: A lambda `(lambda (value error) ...)` or function symbol.
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

  This macro provides a readable, linear syntax for composing and chaining
  promises. It supports various step types, including transformations,
  error handling, and side effects.

  Arguments:
  - `initial-promise-expr`: The promise or value to start the chain.
  - `steps`: A list of step clauses. Supported step types:
    - `:then (lambda (val) ...)`: Transforms the resolved value.
    - `:catch (lambda (err) ...)`: Handles a rejection, can recover.
    - `:finally (lambda () ...)`: Runs a side-effecting callback when settled.
    - `:tap (lambda (val err) ...)`: Side-effecting callback, ignores result.
    - `:all (list-of-promises)`: Waits for all promises in a list.
    - `:race (list-of-promises)`: Waits for the first promise to settle.
    - `:sleep (ms)`: Delays the chain execution for a specified duration in ms.
    - `:log (fmt)`: Logs the current value/error using a format string.
    - `:retry (n fn)`: Retries an asynchronous function `fn` up to `n` times
      on failure.
    - `:let ((v e) ...)`: Introduces lexical bindings for subsequent steps,
      evaluated in order.

  Anaphoric variables `<>` (for the resolved value) and `<!>` (for the error)
  are bound within `:then`, `:catch`, `:tap`, and implicit expression steps.

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
  - `initial-promise-expr`: The initial promise or value.
  - `steps`: A list of step clauses (same as `concur:chain`).

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