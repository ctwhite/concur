;;; concur-ast.el --- AST Analysis and Lexical Lifting for Concur
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides Abstract Syntax Tree (AST) analysis specifically tailored
;; for the `concur` promise library.
;;
;; Its primary purpose is to identify free lexical variables within user-provided
;; callback functions. It performs a read-only traversal of the AST and returns
;; the original function along with a list of names of these variables so they
;; can be explicitly captured and passed across asynchronous boundaries by the
;; caller (e.g., `concur:then`).
;;
;; This library is an adaptation of the variable lifting logic found in
;; `yield-cpm.el`, repurposed for generic lambda analysis.

;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'subr-x)
(require 'dash)
(require 'macroexp)

(require 'concur-hooks)

;; All of these functions are helpers for macros and need to be available
;; to the byte-compiler.
(eval-and-compile

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; Structs

  (cl-defstruct (concur-ast-context (:constructor %%make-concur-ast-context))
    "A context for AST analysis, for identifying free lexical variables.
    This struct holds state relevant to a single analysis pass, focusing on
    tracking lexical variable bindings and usage.

    Fields:
    - `identified-free-vars`: A list of unique *original symbols* that have
    been
      identified as free variables during this pass.
    - `known-bindings`: A list of symbols that are lexically bound in the
      *current* scope and should therefore not be treated as free variables
      (e.g., lambda parameters, `let` variables)."
    (identified-free-vars nil :type list)
    (known-bindings nil :type list))

  (cl-defstruct (concur-ast-lambda-info (:constructor %%make-concur-ast-lambda-info))
    "Information extracted about a lambda or function form during analysis.

    Fields:
    - `expanded-form`: The result of `macroexpand-all` on the original handler.
    - `param-alist`: An alist `(param-symbol . param-symbol)` for the lambda's
      parameters."
    (expanded-form nil :type t)
    (param-alist nil :type alist))

  (cl-defstruct (concur-ast-analysis-result (:constructor %%make-concur-ast-analysis-result))
    "Information for a single lambda/function analysis result.

    Fields:
    - `callable-form`: The original, unexpanded form passed to the analyzer.
    - `expanded-callable-form`: The form after `macroexpand-all`. This is the
      canonical form that `concur-ast.el` analyzes recursively.
    - `free-vars-list`: A list of *original symbols* that were identified as
      free variables *relative to the callable's definition context*."
    (callable-form nil :type t)
    (expanded-callable-form nil :type t)
    (free-vars-list nil :type list))

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; Core Helpers

  (defconst concur-ast--ignored-symbol-names
    '("_" "err" "err-in-handler" "," "@" "backquote" "unquote"
      "unquote-splicing" "cl-lib-reader-comma" "cl-lib-reader-comma-at")
    "List of symbol names that should always be ignored by the AST analyzer
    as potential free variables. Includes special Emacs Lisp symbols and
    common internal macro-generated variable names to prevent incorrect
    lifting.")

  (defun concur-ast--error-symbol-p (sym)
    "Return non-nil if SYM is an error condition type."
    (and (symbolp sym) (get sym 'error-conditions)))

  (defun concur-ast--is-special-ignored-symbol-name (sym-name)
    "Check if `SYM-NAME` is in the list of specially ignored symbol names.

    Arguments:
    - `sym-name`: A string representing the symbol's name.

    Returns:
    `t` if the `sym-name` is in the ignored list, `nil` otherwise."
    (member sym-name concur-ast--ignored-symbol-names))

  (defun concur-ast--analyze-symbol (ast-ctx sym)
    "Determine if `SYM` is a variable that could potentially be 'free'.

    This function explicitly excludes:
    - Non-symbols (numbers, strings, keywords).
    - Emacs Lisp special forms, globally defined functions (`fboundp`),
      and special variables (`special-variable-p`).
    - Symbols explicitly marked as 'known' (locally bound) in `AST-CTX`.
    - Symbols with names on the `concur-ast--ignored-symbol-names` list.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `sym`: The symbol to analyze.

    Returns:
    A list containing `sym` if it's a candidate for a free variable,
    otherwise `nil`."
    (if (or (not (symbolp sym))
            (keywordp sym)
            (memq sym '(nil t))
            (memq sym (concur-ast-context-known-bindings ast-ctx))
            (fboundp sym)
            (special-form-p sym)
            (special-variable-p sym)
            (concur-ast--error-symbol-p sym)
            (string-prefix-p "cl-" (symbol-name sym))
            (string-prefix-p "concur-ast-" (symbol-name sym))
            (concur-ast--is-special-ignored-symbol-name (symbol-name sym))) ; Consolidated check
        nil
      (list sym)))

  (defun concur-ast--get-lifed-symbol (ast-ctx original-sym)
    "Analyzes `ORIGINAL-SYM` to determine if it is a free variable.
    If it is a free variable and not yet tracked, it adds it to the
    context's `identified-free-vars` list.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `original-sym`: The original symbol from the Lisp code being analyzed.

    Returns:
    The `ORIGINAL-SYM` itself. This function primarily performs
    side-effects on `ast-ctx` in this read-only analysis approach."

    (let ((is-free-candidate (car (concur-ast--analyze-symbol ast-ctx original-sym))))
      (when (and (symbolp original-sym) is-free-candidate)
        (unless (memq original-sym
                      (concur-ast-context-identified-free-vars ast-ctx))
          (push original-sym
                (concur-ast-context-identified-free-vars ast-ctx)))))

    original-sym)

  (defun concur-ast--analyze-substitute-bindings (ast-ctx form)
    "Recursively traverses `FORM`. When a symbol is encountered, it triggers
    analysis to identify if it's a free variable.

    In read-only mode, this function does not modify the `FORM` it returns;
    it primarily performs side-effects on the `ast-ctx`.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The Lisp form (or atom) to traverse and analyze.

    Returns:
    The original `FORM` (unmodified)."
    (pcase form
      ((pred atom)
       (cond
        ((symbolp form)
         (concur-ast--get-lifed-symbol ast-ctx form)
         form)
        (t form)))

      ((pred consp)
       (cons (concur-ast--analyze-substitute-bindings ast-ctx (car form))
             (concur-ast--analyze-substitute-bindings ast-ctx (cdr form))))

      (_ form)))

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; AST Traversal Helpers (private and renamed to --analyze-*)

  (defun concur-ast--unwrap-callable-form (callable-form)
    "If `CALLABLE-FORM` is `#'(lambda ...)` or `'(lambda ...)`, unwrap it."
    (pcase callable-form
      (`(function ,(and body `(lambda . ,_))) body)
      (`(quote ,(and body `(lambda . ,_))) body)
      (_ callable-form)))

  (defun concur-ast--parse-lambda-list-for-analysis (lambda-list)
    "Parse a standard or macro LAMBDA-LIST.
This handles &optional, &rest, &key, &aux, and supplied-p variables.
Returns a cons cell: (BOUND-VARS . INIT-FORMS)."
    (let ((vars '())
          (init-forms '())
          (state 'required))
      (dolist (item lambda-list)
        (cond
         ((eq item '&optional) (setq state '&optional))
         ((eq item '&rest)     (setq state '&rest))
         ((eq item '&key)      (setq state '&key))
         ((eq item '&aux)      (setq state '&aux))
         ((eq item '&allow-other-keys) nil)
         (t
          (pcase state
            ((or 'required '&rest)
             (when (symbolp item) (push item vars)))
            ('&aux
             (if (consp item)
                 (progn (push (car item) vars)
                        (when (cadr item) (push (cadr item) init-forms)))
               (push item vars)))
            ((or '&optional '&key)
             (cond
              ((symbolp item) (push item vars))
              ((consp item)
               (let* ((var-spec (car item))
                      (init-form (cadr item))
                      (s-p-var (caddr item))
                      (var-name (if (consp var-spec) (cadr var-spec) var-spec)))
                 (push var-name vars)
                 (when init-form (push init-form init-forms))
                 (when s-p-var (push s-p-var vars))))))))))
    (cons (nreverse vars) (nreverse init-forms))))

  (defun concur-ast--analyze-body-sequence (ast-ctx body-forms)
    "Traverses a sequence of forms for analysis.
    Each form in the sequence is processed in order by the main dispatcher.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `body-forms`: A list of Lisp forms to traverse.

    Returns:
    The original `body-forms` (unmodified)."
    (cl-loop for form in body-forms
             do (concur-ast--analyze-form-recursively ast-ctx form))
    body-forms)

  (defun concur-ast--analyze-lambda (ast-ctx form)
    "Traverses a lambda form for analysis, handling its local parameter scope.

      [Parent CTX]
          │
          ├─> Copy CTX for new LAMBDA scope
          │       ├─> Add lambda params to copied CTX's known-bindings
          │       └─> Analyze Body (recursive calls use copied CTX)
          │
          └─> Merge identified free vars from copied CTX back to Parent CTX,
              excluding vars bound locally in the lambda.

  Arguments:
  - `ast-ctx`: The current `concur-ast-context` instance.
  - `form`: The `lambda` form to analyze.

  Returns:
  The original `lambda` form (unmodified)."
    (let* ((lambda-list (cadr form))
          (body-forms (cddr form))
          ;; Create a context to isolate free vars from the body
          (body-ctx (copy-concur-ast-context ast-ctx))
          ;; Parse arguments and any initialization forms
          (parsed (concur-ast--parse-lambda-list-for-analysis lambda-list))
          (params (car parsed))
          (inits  (cdr parsed)))

      ;; Bind parameters in inner context
      (dolist (param params)
        (push param (concur-ast-context-known-bindings body-ctx)))

      ;; Analyze init forms (like destructured defaults)
      (dolist (init inits)
        (concur-ast--analyze-form-recursively body-ctx init))

      ;; Analyze lambda body
      (concur-ast--analyze-body-sequence body-ctx body-forms)

      ;; Merge discovered free vars upward, filtering out locally bound vars
      (let ((local-bindings (concur-ast-context-known-bindings body-ctx)))
        (setf (concur-ast-context-identified-free-vars ast-ctx)
              (cl-union (concur-ast-context-identified-free-vars ast-ctx)
                        (cl-set-difference
                        (concur-ast-context-identified-free-vars body-ctx)
                        local-bindings))))
      form))

  (defun concur-ast--analyze-let (ast-ctx form)
    "Traverses a `let` or `let*` form for AST analysis, identifying free variables.
    This version correctly models `let` vs `let*` scoping for init forms and body,
    and properly merges identified free variables back to the parent context.
    It also normalizes binding forms for robust processing.

        [Parent CTX]
            │
            ├─> Analyze init-forms in current or new context depending on let/let*
            │
            ├─> Create sub-context for body with new bindings
            │
            ├─> Analyze Body in sub-context
            │
            └─> Merge free vars from sub-context back to Parent CTX

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The `let` or `let*` form to analyze.

    Returns:
    The original `let` or `let*` form (unmodified)."
    (let* ((let-type (car form))
          (bindings (cadr form))
          (body (cddr form))
          ;; NEW: Normalize bindings. (var) -> (var nil) for consistent processing.
          (normalized-bindings (-map (lambda (b) (if (symbolp b) (list b nil) b)) bindings))
          (sub-ast-ctx (copy-concur-ast-context ast-ctx)))
      (pcase let-type
        ('let
        ;; Analyze init-forms in the PARENT context (evaluated in outer scope).
        ;; Use `normalized-bindings` to consistently get the init form (`cadr b`).
        (dolist (b normalized-bindings) ; Iterate over normalized bindings
          (when (cadr b) ; Check if init form exists (i.e., not nil)
            (concur-ast--analyze-form-recursively ast-ctx (cadr b)))) ; Analyze init form
        ;; Add local variables to `known-bindings` in the SUB-CONTEXT (for the body).
        ;; Use `normalized-bindings` to consistently get the variable symbol (`car b`).
        (dolist (b normalized-bindings)
          (push (car b) (concur-ast-context-known-bindings sub-ast-ctx))))
        ('let*
        ;; Analyze init-forms sequentially in the SUB-CONTEXT (reflecting sequential binding).
        ;; Use `normalized-bindings` for consistent (var init) structure.
        (dolist (b normalized-bindings) ; Iterate over normalized bindings
          (let* ((var (car b))
                  (init (cadr b)))
            (when init (concur-ast--analyze-form-recursively sub-ast-ctx init))
            (push var (concur-ast-context-known-bindings sub-ast-ctx))))))
      ;; Analyze the body in the sub-context, as before.
      (concur-ast--analyze-body-sequence sub-ast-ctx body)
      ;; Merge identified free variables from sub-context back to parent, as before.
      (setf (concur-ast-context-identified-free-vars ast-ctx)
            (cl-union (concur-ast-context-identified-free-vars ast-ctx)
                      (concur-ast-context-identified-free-vars sub-ast-ctx)))
      form))
      
  (defun concur-ast--analyze-scoped-functions (ast-ctx form)
    "Traverses `flet` or `cl-labels` for analysis in read-only mode.
    This version corrects a bug by properly handling scope and merging variables.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The `flet` or `cl-labels` form to analyze.

    Returns:
    The original `flet` or `cl-labels` form (unmodified)."
    (pcase-let* ((`(,op ,bindings . ,body) form)
                 (main-body-ctx (copy-concur-ast-context ast-ctx)))
      (dolist (b bindings)
        (push (car b) (concur-ast-context-known-bindings main-body-ctx)))
      (cl-loop for binding in bindings do
               (pcase-let* ((`(,fn-name ,args . ,fn-body) binding)
                            (func-body-ctx (copy-concur-ast-context main-body-ctx)))
                 (concur-ast--analyze-lambda func-body-ctx `(lambda ,args ,@fn-body))
                 (setf (concur-ast-context-identified-free-vars main-body-ctx)
                       (cl-union (concur-ast-context-identified-free-vars main-body-ctx)
                                 (concur-ast-context-identified-free-vars func-body-ctx)))))
      (concur-ast--analyze-body-sequence main-body-ctx body)
      (setf (concur-ast-context-identified-free-vars ast-ctx)
            (cl-union (concur-ast-context-identified-free-vars ast-ctx)
                      (concur-ast-context-identified-free-vars main-body-ctx)))
      form))

  (defun concur-ast--analyze-setf (ast-ctx form)
    "Traverses a `setf` form for analysis in read-only mode.
    It identifies potential free variables but does not rewrite the form.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The `setf` form to analyze.

    Returns:
    The original `setf` form (unmodified)."
    (pcase-let ((`(setf ,place ,value-form) form))
      (unless (symbolp place)
        (error "concur-ast: `setf` only supports symbol places, got %S" place))
      (concur-ast--get-lifed-symbol ast-ctx place)
      (concur-ast--analyze-form-recursively ast-ctx value-form)
      form))

  (defun concur-ast--analyze-setq (ast-ctx form)
    "Traverses a `setq` form for analysis in read-only mode.
    It triggers analysis for its parts but does not really rewrite the form.

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The `setq` form to analyze.

    Returns:
    The original `setq` form (unmodified)."
    (let ((setq-args (cdr form)))
      (when (/= 0 (% 2 (length setq-args)))
        (error "concur-ast: Odd number of arguments to setq: %S" form))
      (while setq-args
        (concur-ast--get-lifed-symbol ast-ctx (car setq-args))
        (concur-ast--analyze-form-recursively ast-ctx (cadr setq-args))
        (setq setq-args (cddr setq-args)))
      form))

  (defun concur-ast--analyze-funcall (ast-ctx form)
    "Traverse a generic function call for analysis, handling keyword arguments safely.

  Arguments:
  - `ast-ctx`: The current `concur-ast-context` instance.
  - `form`: The function call form to analyze.

  Returns:
  The original function call form (unmodified)."
    (let ((fn (car form))
          (args (cdr form)))
      ;; Analyze function position if it's an expression
      (when (consp fn)
        (concur-ast--analyze-form-recursively ast-ctx fn))

      ;; Analyze the argument list
      (while args
        (let ((current-arg (car args)))
          (if (keywordp current-arg)
              ;; --- It's a Keyword-Value Pair ---
              (progn
                ;; 1. Move past the keyword itself (we don't analyze it).
                (setq args (cdr args))
                ;; 2. If a value exists for the keyword, analyze that value.
                (when args
                  (concur-ast--analyze-form-recursively ast-ctx (car args))
                  ;; 3. Move past the value, so the next loop starts after it.
                  (setq args (cdr args))))
            ;; --- It's a Positional Argument ---
            (progn
              (concur-ast--analyze-form-recursively ast-ctx current-arg)
              (setq args (cdr args)))))))
    form)

  (defun concur-ast--analyze-cond (ast-ctx form)
    "Traverses a `cond` form for analysis in read-only mode.
    It walks tests and bodies but does not rewrite the form.

       [Cond]
            │
            ├─> Clause 1 (Test)
            │       ├─> Analyze Test
            │       └─> Analyze Body Sequence
            │
            ├─> Clause 2 (Test)
            │       ├─> Analyze Test
            │       └─> Analyze Body Sequence
            │
            └─> ... (continues for all clauses)

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The `cond` form to analyze.

    Returns:
    The original `cond` form (unmodified)."
    (cl-loop for clause in (cdr form)
             do
             (pcase-let ((`(,test . ,body) clause))
               (concur-ast--analyze-form-recursively ast-ctx test)
               (concur-ast--analyze-body-sequence ast-ctx body)))
    form)

  (defun concur-ast--analyze-condition-case (ast-ctx form)
    "Traverses a `condition-case` form for analysis.
    It walks the main body and then each error handler clause, handling the
    lexical scope of the error variable (e.g., `err`).

        [Condition-Case (Error Var)]
            │
            ├─> Analyze Main Body
            │
            └─> For each Handler Clause:
                    ├─> Copy CTX for Handler scope
                    │       ├─> Add Error Var to copied CTX known-bindings
                    │       └─> Analyze Handler Body
                    │
                    └─> Merge identified free vars from copied CTX to Parent CTX

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The `condition-case` form to analyze.

    Returns:
    The original `condition-case` form (unmodified)."
    (pcase-let* ((`(condition-case ,error-var ,body-form . ,handlers) form))
      (concur-ast--analyze-form-recursively ast-ctx body-form)
      (cl-loop for handler in handlers
               do
               (pcase-let* ((`(,condition . ,handler-body) handler)
                            (handler-ctx (copy-concur-ast-context ast-ctx)))
                 (when (symbolp error-var)
                   (push error-var (concur-ast-context-known-bindings handler-ctx)))
                 (concur-ast--analyze-body-sequence handler-ctx handler-body)
                 (setf (concur-ast-context-identified-free-vars ast-ctx)
                       (cl-union (concur-ast-context-identified-free-vars ast-ctx)
                                 (concur-ast-context-identified-free-vars handler-ctx)))))
      form))

  (defun concur-ast--analyze-form-recursively (ast-ctx form)
    "Walks a single Lisp `FORM` to identify free variables (read-only mode).
    This is the main internal entry point for the recursive AST walker.
    It uses `pcase` to match the structure of the form and call the appropriate handler.

     [FORM]
          │
          ├─> Atom?           -> `concur-ast--analyze-substitute-bindings`
          ├─> Quoted Form?    -> Skip (literal)
          ├─> Macro Reader?   -> Recurse on inner form
          ├─> Special Form?
          │   (`let`, `lambda`, `cl-defun`, etc.)
          │       └─> Call specific `concur-ast--analyze-*` handler
          └─> List (function call)? -> `concur-ast--analyze-funcall`

    Arguments:
    - `ast-ctx`: The current `concur-ast-context` instance.
    - `form`: The Lisp form to analyze.

    Returns:
    The original `FORM` (unmodified)."
    (pcase form
      ;; Handle all atomic forms (symbols, numbers, strings, t, nil).
      ((pred atom) (concur-ast--analyze-substitute-bindings ast-ctx form))
      ;; Quoted forms are literals and are not traversed.
      (`(quote ,_) form)

      ;; Handle reader macros for unquote/unquote-splicing by unwrapping them.
      (`(,(or 'unquote '\,) ,arg)
       (concur-ast--analyze-form-recursively ast-ctx arg))
      (`(,(or 'unquote-splicing '\@) ,arg)
       (concur-ast--analyze-form-recursively ast-ctx arg))

      ;; Handle special forms that introduce lexical scope.
      (`(,(or 'let 'let*) . ,_) (concur-ast--analyze-let ast-ctx form))
      (`(,(or 'flet 'cl-labels) . ,_)
       (concur-ast--analyze-scoped-functions ast-ctx form))

      ;; Handle assignment forms.
      (`(setq . ,_) (concur-ast--analyze-setq ast-ctx form))
      (`(setf . ,_) (concur-ast--analyze-setf ast-ctx form))

      ;; Handle lambdas.
      (`(lambda . ,_) (concur-ast--analyze-lambda ast-ctx form))

      ;; Handle `cond` forms.
      (`(cond . ,_) (concur-ast--analyze-cond ast-ctx form))

      ;; Handle `condition-case` forms.
      (`(condition-case . ,_) (concur-ast--analyze-condition-case ast-ctx form))

      ;; Fallback for generic function calls.
      ((pred consp) (concur-ast--analyze-funcall ast-ctx form))

      ;; Error on any other unhandled forms.
      (_ (error "concur-ast: Unhandled form in analysis: %S" form))))

  (cl-defun concur-ast--lift-lambda-form
      (ast-ctx expanded-callable-form initial-param-alist additional-capture-vars &optional env)
    "Analyzes an *expanded* callable form to find free lexical variables.

    This is an internal helper called by `concur-ast-analysis`. It sets up
    the initial context for a top-level callable analysis, then delegates
    to the main recursive walker (`concur-ast--analyze-form-recursively`).

    Arguments:
    - `ast-ctx`: The `concur-ast-context` instance for this callable.
    - `expanded-callable-form`: The callable form after macro-expansion.
    - `initial-param-alist`: An alist of `(original-arg . original-arg)`
      for parameters of this callable that should not be lifted.
    - `additional-capture-vars`: An alist of `(var . t)` pairs to explicitly
      mark as free variables that must be identified.
    - `env`: The lexical environment from macro expansion.

    Returns:
    A cons cell `(EXPANDED-CALLABLE-FORM . FREE-VARS-LIST)`."
  (pcase expanded-callable-form
    ;; --- CASE 1: The form is a literal lambda. ---
    ((or `(lambda . ,_) `(function (lambda . ,_)) `(quote (lambda . ,_)))
     (let* ((raw-lambda (concur-ast--unwrap-callable-form expanded-callable-form))
            (arglist (nth 1 raw-lambda))
            (original-body (cddr raw-lambda))
            (docstring (when (stringp (car original-body)) (car original-body)))
            (body-to-transform (if docstring (cdr original-body) original-body))
            (parsed (concur-ast--parse-lambda-list-for-analysis arglist))
            (bound-vars (car parsed))
            (init-forms (cdr parsed)))
       
       ;; Register lambda arguments as known bindings
       (dolist (param bound-vars)
         (push param (concur-ast-context-known-bindings ast-ctx)))

       ;; Analyze body
       (concur-ast--analyze-body-sequence ast-ctx body-to-transform)

       ;; Identify free variables
       (let* ((implicit-free-vars
               (cl-set-difference (concur-ast-context-identified-free-vars ast-ctx)
                                  (concur-ast-context-known-bindings ast-ctx)
                                  :test #'eq))
              (final-free-var-list
               (cl-delete-duplicates
                (append (mapcar #'car additional-capture-vars)
                        implicit-free-vars)
                :test #'eq)))
         (cons expanded-callable-form final-free-var-list))))

    ;; --- CASE 2: The form is a function quote, e.g., #'my-func ---
    (`(function ,name)
     (cons expanded-callable-form '()))

    ;; --- CASE 3: The form is a raw symbol, e.g., 'my-func ---
    ((pred symbolp)
     (concur-ast--lift-lambda-form ast-ctx `(function ,expanded-callable-form)
                                   initial-param-alist additional-capture-vars env))

    ;; --- CASE 4: Unhandled form ---
    (_ (error "concur-ast: Expected a lambda or function symbol, got %S"
              expanded-callable-form))))

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; Public API - Top-level Analysis Functions

  (cl-defun concur-ast-analyze-lambda-form (handler-raw-form &optional env)
    "Expand `HANDLER-RAW-FORM` and extract its actual lambda form and
    parameter alist."
    (let* ((expanded-form (macroexpand-all handler-raw-form env))
           (params nil))
      (pcase-let* ((params-and-form
                    (pcase expanded-form
                      (`(lambda ,p . ,_)
                       (list (if (listp p) p (list p)) expanded-form))
                      (`(function (lambda ,p . ,_))
                       (list (if (listp p) p (list p)) expanded-form))
                      (`(quote (lambda ,p . ,_))
                       (list (if (listp p) p (list p)) expanded-form))
                      (`(function ,sym)
                       (list nil expanded-form))
                      ((pred symbolp)
                       (list nil expanded-form))
                      (_
                       (error "concur-ast-analyze-lambda-form: Unhandled expanded form for analysis: %S" expanded-form)))))
        (let ((params (car params-and-form))
              (actual-expanded-form (cadr params-and-form)))
          (%%make-concur-ast-lambda-info
           :expanded-form actual-expanded-form
           :param-alist (cl-loop for p in params collect (cons p p)))))))

  (cl-defun concur-ast-analysis (raw-callable-form &optional env additional-capture-vars)
    "Analyzes an *expanded* callable form to find free lexical variables."
    (let* ((initial-ast-ctx (%%make-concur-ast-context))
           (lambda-info (concur-ast-analyze-lambda-form raw-callable-form env))
           (expanded-callable-form (concur-ast-lambda-info-expanded-form lambda-info))
           (param-alist (concur-ast-lambda-info-param-alist lambda-info))
           (lift-result (concur-ast--lift-lambda-form initial-ast-ctx
                                                      expanded-callable-form
                                                      param-alist
                                                      additional-capture-vars env))
           (free-vars-list (cdr lift-result)))
      (%%make-concur-ast-analysis-result
       :callable-form raw-callable-form
       :expanded-callable-form expanded-callable-form
       :free-vars-list free-vars-list)))

  (cl-defun concur-ast-make-captured-vars-form (all-vars)
    "Generates the Lisp code to create a hash table containing captured variables.
  Returns a form that evaluates to a hash table. If `all-vars` is empty,
  it returns a form that evaluates to an empty hash table, ensuring
  callers always receive a hash table context."
    (let ((ht-sym (gensym "context-ht-")))
      `(let ((,ht-sym (make-hash-table :test 'eq)))
        ,@(cl-loop for var in all-vars
                    collect `(setf (gethash ',var ,ht-sym) ,var))
        ,ht-sym)))

) ; End of eval-and-compile block

(provide 'concur-ast)
;;; concur-ast.el ends here