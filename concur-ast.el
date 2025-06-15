;;; concur-ast.el --- AST Analysis and Lexical Lifting for Concur
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides Abstract Syntax Tree (AST) analysis and transformation
;; capabilities specifically tailored for the `concur` promise library.
;;
;; Its primary purpose is to "lift" free lexical variables from user-provided
;; callback functions. It rewrites the function and extracts the names of these
;; variables so they can be explicitly captured and passed across asynchronous
;; boundaries, ensuring they remain accessible even after byte-compilation.
;;
;; This library is an adaptation of the variable lifting logic found in
;; `yield-cpm.el`, repurposed for generic lambda analysis.

;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'subr-x)
(require 'dash)

(require 'concur-hooks)

;; All of these functions are helpers for macros and need to be available
;; to the byte-compiler.
(eval-and-compile

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; AST Context Struct & Core Helpers

  (cl-defstruct (concur-ast-context (:constructor %%make-concur-ast-context))
    "A context for AST transformation, primarily for variable lifting.
This struct holds state relevant to a single transformation pass, focusing on
tracking lexical variable bindings and usage.

Fields:
  current-bindings: An alist mapping original symbols to their lifted
    (gensym'd) counterparts within the current lexical scope.
  all-lifted-symbols: A list of all unique gensym'd symbols that
    represent variables that needed to be lifted during this pass."
    (current-bindings nil :type alist)
    (all-lifted-symbols nil :type list))

  (defun concur-ast-gensym (prefix)
    "Generate a unique symbol with a given PREFIX for AST transformations.
Using a custom wrapper ensures all our generated symbols have a consistent and
identifiable naming scheme.

Arguments:
- PREFIX: A string to use as the base for the symbol name.

Returns:
A new, unique symbol."
    (gensym (format "concur-ast-%s-" prefix)))

  (defun concur-ast-get-lifted-symbol (ast-ctx original-sym)
    "Get or create a lifted (gensym'd) symbol for ORIGINAL-SYM.
This function is the core of the lifting mechanism. It checks the current
context for a variable. If the variable is not a known local, it is
deemed 'free', and a new unique symbol is generated for it. This new
symbol is then stored in the context for future lookups.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- ORIGINAL-SYM: The original symbol from the Lisp code being analyzed.

Returns:
The corresponding lifted (gensym'd) symbol."
    (let ((binding (assq original-sym (concur-ast-context-current-bindings ast-ctx))))
      (or (cdr binding)
          (let ((new-lifted-sym (concur-ast-gensym (symbol-name original-sym))))
            (push new-lifted-sym (concur-ast-context-all-lifted-symbols ast-ctx))
            (push (cons original-sym new-lifted-sym)
                  (concur-ast-context-current-bindings ast-ctx))
            new-lifted-sym))))

  (defun concur-ast-substitute-bindings (ast-ctx form)
    "Recursively substitute original symbols in FORM with their lifted counterparts.
This function walks a form and replaces any symbol that has a lifted
counterpart in the AST context with that new symbol.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The Lisp form (or atom) to transform.

Returns:
The transformed Lisp form."
    (let ((bindings (concur-ast-context-current-bindings ast-ctx)))
      (pcase form
        ((pred symbolp) (or (cdr (assq form bindings)) form))
        ((pred consp) (cons (concur-ast-substitute-bindings ast-ctx (car form))
                            (concur-ast-substitute-bindings ast-ctx (cdr form))))
        (_ form))))

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; Transformation Helpers for Special Forms

  (defun concur-ast--transform-body-sequence (ast-ctx body-forms)
    "Transforms a sequence of forms, such as the body of a `let` or `lambda`.
Each form in the sequence is transformed in order.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- BODY-FORMS: A list of Lisp forms to transform.

Returns:
A list of transformed Lisp forms."
    (cl-loop for form in body-forms
             collect (concur-ast-transform-expression ast-ctx form)))

  (defun concur-ast-handle-atomic-form (ast-ctx form)
    "Transforms an atomic form (e.g., number, string, symbol, quote).
For symbols, this may involve substituting it with a lifted counterpart.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The atomic Lisp form to transform.

Returns:
The transformed (or original) atomic form."
    (concur-ast-substitute-bindings ast-ctx form))

  (defun concur-ast-transform-progn (ast-ctx form)
    "Transforms a `progn` form by recursively transforming its body.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `progn` form to transform.

Returns:
The transformed `progn` form."
    (let ((body-forms (cdr form)))
      (if (null body-forms)
          form
        `(progn ,@(concur-ast--transform-body-sequence ast-ctx body-forms)))))

  (defun concur-ast-transform-if (ast-ctx form)
    "Transforms an `if` form by recursively transforming its components.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `if` form to transform.

Returns:
The transformed `if` form."
    (pcase-let* ((`(if ,cond-form ,then-body . ,else-body) form))
      `(if ,(concur-ast-transform-expression ast-ctx cond-form)
           ,(concur-ast-transform-expression ast-ctx then-body)
         ,@(cl-loop for b in else-body
                    collect (concur-ast-transform-expression ast-ctx b)))))

  (defun concur-ast-transform-while (ast-ctx form)
    "Transforms a `while` loop by recursively transforming its test and body.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `while` form to transform.

Returns:
The transformed `while` form."
    (pcase-let* ((`(while ,test-form . ,body) form))
      `(while ,(concur-ast-transform-expression ast-ctx test-form)
         ,@(cl-loop for b in body
                    collect (concur-ast-transform-expression ast-ctx b)))))

  (defun concur-ast-transform-let (ast-ctx form)
  "Transforms a `let` or `let*` form, correctly handling the scoping
rules and rewriting the bindings to use lifted symbols."
  (concur--log :debug "AST: Transforming let/let*: %S" form)
  (let* ((let-type (car form))
         (bindings (cadr form))
         (body (cddr form))
         (original-bindings
          (-map (lambda (b) (if (symbolp b) `(,b nil) b)) bindings))
         ;; Save the original bindings from the context to restore later.
         (saved-bindings
          (copy-alist (concur-ast-context-current-bindings ast-ctx))))

    ;; `unwind-protect` ensures the context is ALWAYS restored.
    (unwind-protect
        (pcase let-type
          ;; --- Case 1: `let` (Parallel Scoping) ---
          ('let
           (let* (;; 1. Transform all init forms with the OUTSIDE context.
                  (transformed-inits
                   (mapcar (lambda (b)
                             (concur-ast-transform-expression ast-ctx (cadr b)))
                           original-bindings))
                  ;; 2. Create mappings for the new local variables.
                  (local-var-map
                   (mapcar (lambda (b)
                             (cons (car b)
                                   (concur-ast-gensym (symbol-name (car b)))))
                           original-bindings))

                  ;; --- CORRECTION: Replaced faulty `mapcar` with a clear `cl-loop` ---
                  ;; 3. Assemble the final `let` bindings list, using the
                  ;;    new "lifted" names for the variables.
                  (final-bindings
                   (cl-loop for mapping in local-var-map
                            for init in transformed-inits
                            collect (list (cdr mapping) init))))
             ;; 4. Update the context with the new local variable mappings.
             (dolist (mapping local-var-map)
               (push mapping (concur-ast-context-current-bindings ast-ctx)))
             ;; 5. Transform the main body using this new, updated context.
             (let ((transformed-body
                    (concur-ast--transform-body-sequence ast-ctx body)))
               `(let ,final-bindings ,@transformed-body))))

          ;; --- Case 2: `let*` (Sequential Scoping) ---
          ('let*
           (let ((transformed-bindings '()))
             ;; 1. Loop through each binding sequentially.
             (dolist (binding original-bindings)
               (let* ((var (car binding))
                      (init-form (cadr binding))
                      ;; 2. Transform the init-form using the CURRENT context.
                      (transformed-init
                       (concur-ast-transform-expression ast-ctx init-form))
                      ;; 3. Create a new lifted symbol for this local variable.
                      (lifted-var (concur-ast-gensym (symbol-name var))))
                 ;; 4. Add the transformed binding to our results list.
                 (push `(,lifted-var ,transformed-init) transformed-bindings)
                 ;; 5. CRUCIALLY, update the context for the NEXT iteration.
                 (push (cons var lifted-var)
                       (concur-ast-context-current-bindings ast-ctx))))
             ;; 6. Transform the body using the final, fully-updated context.
             (let ((transformed-body
                    (concur-ast--transform-body-sequence ast-ctx body)))
               `(let* ,(nreverse transformed-bindings) ,@transformed-body)))))

      ;; Cleanup form for `unwind-protect`: always restore the context.
      (setf (concur-ast-context-current-bindings ast-ctx) saved-bindings))))
    
  (defun concur-ast-transform-flet (ast-ctx form)
    "Transforms an `flet` form by handling its local function bindings.
This is necessary to correctly parse code generated by `cl-labels`.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `flet` form to transform.

Returns:
The transformed `flet` form."
    (pcase-let* ((`(flet ,bindings . ,body) form))
      (let* ((func-names (mapcar #'car bindings))
             (new-ast-bindings
              (copy-alist (concur-ast-context-current-bindings ast-ctx))))
        (dolist (fn-name func-names)
          (let* ((lifted-fn-name (concur-ast-gensym (symbol-name fn-name))))
            (push (cons fn-name lifted-fn-name) new-ast-bindings)))
        (let ((sub-ast-ctx (copy-concur-ast-context ast-ctx)))
          (setf (concur-ast-context-current-bindings sub-ast-ctx) new-ast-bindings)
          (let ((transformed-body-forms
                 (concur-ast--transform-body-sequence sub-ast-ctx body)))
            (setf (concur-ast-context-current-bindings ast-ctx)
                  (cl-union (concur-ast-context-current-bindings sub-ast-ctx)
                            (concur-ast-context-current-bindings ast-ctx)
                            :key #'car))
            `(flet ,bindings ,@transformed-body-forms))))))

  (defun concur-ast-transform-setf (ast-ctx form)
    "Transforms a `(setf PLACE VALUE)` form for variable substitution.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `setf` form to transform.

Returns:
The transformed `setf` form."
    (pcase-let ((`(setf ,place ,value-form) form))
      (unless (symbolp place)
        (error "concur-ast: `setf` only supports symbol places, got %S" place))
      (let ((lifted-var (concur-ast-get-lifted-symbol ast-ctx place)))
        `(setf ,lifted-var
               ,(concur-ast-transform-expression ast-ctx value-form)))))

  (defun concur-ast-transform-setq (ast-ctx form)
    "Transforms a `(setq VAR1 VAL1 ...)` form by converting it to `setf` forms.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `setq` form to transform.

Returns:
The transformed `progn` of `setf` forms."
    (let ((setq-args (cdr form))
          (progn-body '()))
      (when (/= 0 (% 2 (length setq-args)))
        (error "concur-ast: Odd number of arguments to setq: %S" form))
      (while setq-args
        (push `(setf ,(car setq-args) ,(cadr setq-args)) progn-body)
        (setq setq-args (cddr setq-args)))
      (concur-ast-transform-expression ast-ctx `(progn ,@(nreverse progn-body)))))

  (defun concur-ast-transform-funcall (ast-ctx form)
    "Transforms a generic function call `(f A1 A2 ...)` by transforming its args.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The function call form to transform.

Returns:
The transformed function call form."
    (cons (concur-ast-transform-expression ast-ctx (car form))
          (cl-loop for arg in (cdr form)
                   collect (concur-ast-transform-expression ast-ctx arg))))

  (defun concur-ast-transform-lambda (ast-ctx form)
    "Transforms a nested lambda form, handling its local parameter scope.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The `lambda` form to transform.

Returns:
The transformed `lambda` form."
    (let* ((original-args (cadr form))
           (original-body (cddr form))
           (new-ast-bindings
            (copy-alist (concur-ast-context-current-bindings ast-ctx))))
      ;; Make the lambda's parameters known to the sub-context so they are
      ;; not treated as free variables.
      (let ((arg-list (if (listp original-args) original-args
                        (if original-args (list original-args) nil))))
        (-each arg-list
               (-lambda (arg-sym)
                 (when (symbolp arg-sym)
                   (let ((lifted-sym (concur-ast-gensym (symbol-name arg-sym))))
                     (push (cons arg-sym lifted-sym) new-ast-bindings))))))
      (let ((sub-ast-ctx (copy-concur-ast-context ast-ctx)))
        (setf (concur-ast-context-current-bindings sub-ast-ctx) new-ast-bindings)
        (let ((transformed-body-forms
               (concur-ast--transform-body-sequence sub-ast-ctx original-body)))
          (setf (concur-ast-context-current-bindings ast-ctx)
                (cl-union (concur-ast-context-current-bindings sub-ast-ctx)
                          (concur-ast-context-current-bindings ast-ctx)
                          :key #'car))
          `(lambda (,@original-args) ,@transformed-body-forms)))))

  (defun concur-ast-transform-expression (ast-ctx form)
    "Transforms a single Lisp FORM for variable lifting by dispatching to a helper.
This is the main entry point for the recursive AST walker.

Arguments:
- AST-CTX: The current `concur-ast-context` instance.
- FORM: The Lisp form to transform.

Returns:
The transformed Lisp form."
    (pcase form
      ((pred numberp) (concur-ast-handle-atomic-form ast-ctx form))
      ((pred stringp) (concur-ast-handle-atomic-form ast-ctx form))
      ((pred (lambda (x) (memq x '(nil t)))) (concur-ast-handle-atomic-form ast-ctx form))
      ((pred symbolp) (concur-ast-handle-atomic-form ast-ctx form))
      (`(quote ,_) (concur-ast-handle-atomic-form ast-ctx form))
      ((and (pred consp) (guard (not (listp form)))) (concur-ast-substitute-bindings ast-ctx form))
      (`(progn . ,_) (concur-ast-transform-progn ast-ctx form))
      (`(if . ,_) (concur-ast-transform-if ast-ctx form))
      (`(while . ,_) (concur-ast-transform-while ast-ctx form))
      (`(,(or 'let 'let*) . ,_) (concur-ast-transform-let ast-ctx form))
      (`(flet . ,_) (concur-ast-transform-flet ast-ctx form))
      (`(setq . ,_) (concur-ast-transform-setq ast-ctx form))
      (`(setf . ,_) (concur-ast-transform-setf ast-ctx form))
      (`(lambda . ,_) (concur-ast-transform-lambda ast-ctx form))
      ((pred consp) (concur-ast-transform-funcall ast-ctx form))
      (_ (error "concur-ast: Unhandled form in transformation: %S" form))))

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;; Public API - Lexical Lifting Entry Point

  (cl-defun concur-ast-lift-lambda-form
      (user-lambda &optional initial-param-bindings additional-capture-vars)
    "Lifts free lexical variables from a USER-LAMBDA form.

This is the main public function of this library. It takes a lambda, walks its
AST to find all free variables (variables that are not formal parameters),
and returns a new, transformed lambda along with a list of the names of the
free variables it found.

The transformed lambda will accept an extra `context` argument. It contains
a `let` block that re-binds the lifted variables from values provided in the
`context` alist at runtime.

Arguments:
- USER-LAMBDA (form): The lambda form `(lambda (args...) body...)` to analyze.
- INITIAL-PARAM-BINDINGS (alist, optional): An alist of
  `(original-arg . original-arg)` from the lambda's parameters. This tells
  the lifter which symbols are parameters and should not be lifted.
- ADDITIONAL-CAPTURE-VARS (alist, optional): An alist of `(var-symbol . t)`
  pairs to explicitly mark as free variables that must be lifted.

Returns:
A cons cell `(LIFTED-LAMBDA . FREE-VARS-LIST)`.
- `LIFTED-LAMBDA`: The rewritten lambda form, which now takes `context`
  as its last argument and has its captured variables injected via a `let`.
- `FREE-VARS-LIST`: A list of symbols representing the names of all free
  variables that were found and need to be captured at runtime."
    (unless (and (consp user-lambda) (eq (car user-lambda) 'lambda))
      (error "concur-ast-lift-lambda-form: Expected a lambda form, got %S"
             user-lambda))
    (let* ((original-args (cadr user-lambda))
           (original-body (cddr user-lambda))
           (context-sym (concur-ast-gensym "context"))
           (cpm-ctx (%%make-concur-ast-context
                     :current-bindings (copy-alist initial-param-bindings))))
      ;; 1. Walk the AST, transforming the body. During the walk, the
      ;;    `cpm-ctx` is populated with mappings from original free variables
      ;;    to their new, unique "lifted" symbols.
      (let* ((transformed-body-forms
              (concur-ast--transform-body-sequence cpm-ctx original-body))
             (transformed-body `(progn ,@transformed-body-forms)))
        ;; 2. Identify all the variables that were lifted during the walk.
        (let* ((all-bound-symbols
                (mapcar #'car (concur-ast-context-current-bindings cpm-ctx)))
               (implicit-free-vars
                (cl-set-difference all-bound-symbols
                                   (mapcar #'car initial-param-bindings)
                                   :test #'eq))
               (final-free-var-list
                (cl-delete-duplicates
                 (append (mapcar #'car additional-capture-vars) implicit-free-vars)
                 :test #'eq))
               ;; 3. Create the `let` bindings that will be injected into the
               ;;    final lambda. This code retrieves the original variable's
               ;;    value from the `context` alist at runtime.
               (retrieval-bindings
                (cl-loop for original-var in final-free-var-list
                         for lifted-var = (cdr (assq original-var
                                                    (concur-ast-context-current-bindings
                                                     cpm-ctx)))
                         collect `(,lifted-var
                                   (cdr (assoc ',original-var ,context-sym)))))
               ;; 4. Assemble the final rewritten lambda.
               (lifted-lambda
                `(lambda (,@original-args ,context-sym)
                   (let (,@retrieval-bindings)
                     ,transformed-body))))
          ;; 5. Return the new lambda and the list of free variable names.
          (cons lifted-lambda final-free-var-list)))))

) ; End of eval-and-compile block

(provide 'concur-ast)
;;; concur-ast.el ends here