;;; concur-generator.el --- Concurrent Generator Step Runner -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides a step-based concurrent runner using generators.
;; It enables composing structured workflows as sequential steps, each of
;; which may yield or complete asynchronously while capturing errors, retries,
;; and context.
;;
;; Each step can be specified as a plain form or a plist describing:
;;
;;   :form         - the actual code to run
;;   :name         - name of the step (used for logging and results)
;;   :timeout      - optional timeout for step execution
;;
;; `concur-generator--step-runner` orchestrates the flow of execution:
;;
;;   - Steps can yield using `concur-generator-yield!` to signal suspension.
;;   - Placeholder substitution allows referencing earlier step results.
;;   - Thunks are instrumented for retries, error handling, and logging.
;;
;; Hooks like `:before`, `:after`, and `:error-handler` provide extension points.
;; Step metadata and intermediate results are stored in a result hash table.
;;
;; Thunks are generated via `concur-generator--make-step-thunk`, which handles
;; retries, logging, instrumentation, and forwarding to error-handling logic.
;;
;; Placeholders like `(:result :step-1)` or `(:step "fetch")` in a step form are
;; replaced using `concur-generator--replace-placeholders`.
;;
;;; Code:

(require 'cl-lib)
(require 'concur-fsm)
(require 'dash)
(require 'scribe)

(defun concur-generator--yield-runtime (&rest vals)
  "Runtime yield function for generators.

Throws a tagged value 'generator-yield with yielded VALS.
If only one value is yielded, it throws that single value, else the list."
  (throw 'concur-generator-yield! (if (= (length vals) 1) (car vals) vals)))

(defun concur-generator--split-on-yield (form)
  "Recursively split FORM into a list of steps at each `(yield! ...)`.

Each step is a form or a `progn` wrapping one or more forms.

Replaces `(yield! val...)` with `(concur-generator--yield-runtime val...)` for runtime execution."
  (cl-labels
      ((split (form)
         (cond
          ;; Replace top-level yield!
          ((and (listp form) (eq (car form) 'yield!))
           (list `(concur-generator--yield-runtime ,@(cdr form))))

          ;; Atoms are treated as single steps
          ((atom form)
           (list form))

          ;; Compound forms
          ((listp form)
           (let ((steps '())
                 (current-step '()))
             (dolist (subform form)
               (let ((sub-steps (split subform)))
                 (if (> (length sub-steps) 1)
                     (progn
                       (when current-step
                         (push `(progn ,@(reverse current-step)) steps)
                         (setq current-step '()))
                       (setq steps (append steps sub-steps)))
                   (push (car sub-steps) current-step))))
             (when current-step
               (push `(progn ,@(reverse current-step)) steps))
             (nreverse steps)))

          (t
           (list form)))))
    (split form)))

(defun concur-generator--pipeline (steps &optional options)
  "Run a pipeline of STEPS as a generator-style FSM.

Each step may be:
- A plist with at least a `:form` key or quoted form.
- A lambda function (used directly).
- A raw form like (message \"hi\") or its quoted version '(message \"hi\").

OPTIONS is a plist that may include:
- :retries       Number of retries per step (default 1)
- :error-store   Function called on step error with (name error)
- :error-handler Function called on step error with (error)
- Any other keys for step-thunk construction or hooks.

Returns a plist describing the current pipeline status:
- If done: (:done t :results HT) where HT is the hash table of results.
- If yielded: (:done nil :step-index IDX :step-name NAME :result VAL)
  representing the current yielded step info.

The pipeline uses `concur-fsm-run` internally, which manages
state transitions, retries, errors, and yield/done control flow."
  (log! "Starting concur-generator--pipeline with %d steps" (length steps) :level 'debug)
  (let* ((fsm-steps
          (--map-indexed
           (let* ((step it)
                  (idx it-index)
                  (name (format "step-%d" idx))
                  ;; Unwrap quoted forms
                  (unquoted (if (and (listp step)
                                     (eq (car step) 'quote))
                                (cadr step)
                              step)))
             (log! "Preparing step %d: %S" idx step :level 'trace)
             (cond
              ;; Case: plist with :form
              ((and (listp unquoted)
                    (plist-get unquoted :form))
               (let ((form (plist-get unquoted :form)))
                 (log! "Step %d is a plist with :form: %S" idx form :level 'trace)
                 (list :name (or (plist-get unquoted :name) name)
                       :thunk `(lambda () ,form)
                       :before (plist-get unquoted :before)
                       :after  (plist-get unquoted :after)
                       :timeout (plist-get unquoted :timeout))))
    
              ;; Case: already a lambda
              ((and (functionp unquoted) (not (symbolp unquoted)))
               (log! "Step %d is a lambda function" idx :level 'trace)
               (list :name name :thunk unquoted))
    
              ;; Case: raw form (quoted or not) → wrap in lambda
              ((listp unquoted)
               (log! "Step %d is a raw form, wrapping in lambda: %S" idx unquoted :level 'trace)
               (list :name name :thunk `(lambda () ,unquoted)))
              (t
               (error "Invalid step: %S" step))))
           steps))
         result)
    
    (log! "Running concur-fsm-run with prepared steps and options: %S" options :level 'debug)
    (catch 'concur-finished
      (catch 'concur-yield
        (setq result (concur-fsm-run fsm-steps options))))
    
    (log! "FSM run result: %S" result :level 'debug)
    (if (plist-get result :done)
        (progn
          (log! "Pipeline finished successfully with results." :level 'info)
          (list :done t :results (concur-fsm-results result)))
      (progn
        (log! "Pipeline yielded at step %d (%s)" (plist-get result :step-index)
              (plist-get result :step-name) :level 'info)
        (list :done nil
              :step-index (plist-get result :step-index)
              :step-name (plist-get result :step-name)
              :result (plist-get result :result))))))

;;;###autoload
(defmacro concur-generator-yield! (&rest expr)
  "Marker macro for generator yield points inside `defgenerator!` bodies.

Expands to `(concur-generator--yield-runtime ,@expr)`, which signals
the runner to pause execution and yield control.

Usage:

  (concur-generator-yield! VALUE)

Yields VALUE from the generator, resuming from this point on next call."
  `(concur-generator--yield-runtime ,@expr))

;;;###autoload
(defun concur-generator (&rest args)
  "Run multiple STEPS followed by keyword OPTIONS.

STEPS can be zero-arg lambdas, raw forms (lists of expressions), or
let/let* forms containing `concur-generator-yield!` calls.

OPTIONS is a plist of keyword arguments, passed through to
`concur-generator--pipeline`.

Each STEP is internally converted into a zero-arg thunk by:

- Leaving zero-arg lambdas as-is.
- For let/let* forms or raw lists of forms, splitting on `yield!`
  calls into multiple steps, each wrapped in a lambda.
- For single raw forms, wrapping directly in a zero-arg lambda.

Returns a zero-arg thunk that runs one step per call, yielding values
at each `concur-generator-yield!` point or nil when done."  
  (let* ((split-pos (cl-position-if #'keywordp args))
         (raw-steps (if split-pos (cl-subseq args 0 split-pos) args))
         (options (if split-pos (cl-subseq args split-pos) nil))
         (steps
          (--map
           (cond
            ;; Step is already a zero-arg lambda, leave as-is
            ((and (consp it) (eq (car it) 'lambda)) it)

            ;; Step is a let or let* form — unwrap and split yields inside
          ((and (consp it) (memq (car it) '(let let*)))
           (let* ((kind (car it))
                  (bindings (cadr it))
                  (body (cddr it))
                  (split-steps (concur-generator--split-on-yield `(progn ,@body))))
            (--map `(lambda () (,kind ,bindings ,it)) split-steps)))

            ;; Step is a raw list of forms (progn body) — wrap & split yields
            ((consp it)
             `(lambda ()
                ,@(concur-generator--split-on-yield `(progn ,@it))))

            ;; Fallback: single form — wrap directly in zero-arg lambda
            (t `(lambda () ,it)))
           raw-steps)))
    (apply #'concur-generator--pipeline steps options)))

;;;###autoload
(defmacro defgenerator! (name args &rest body)
  "Define a generator function NAME with ARGS supporting `(yield!)` calls.

This macro transforms BODY into a generator function that can pause and
resume execution at each `(concur-generator-yield! EXPR)` point.

The generated function returns a zero-argument thunk that, when called,
executes the generator until the next yield or completion and returns
the yielded value or nil when finished.

Locals can be declared by wrapping BODY in `let` or `let*`, allowing state
to persist across yields.

The generator supports optional keyword arguments after ARGS:

- :before    (lambda (step idx results ctx))  
  Called before each step executes.

- :after     (lambda (step idx results ctx result))  
  Called after each step completes.

- :on-error  (lambda (error step idx ctx))  
  Called when a step signals an error.

These hooks are internally handled by the FSM.

Example:

  (concur-generator! count-to-n (n)
    (let ((i 0))
      (while (< i n)
        (concur-generator-yield! i)
        (setq i (1+ i))))

  (let ((gen (count-to-n 3
               :on-error (lambda (err step idx ctx)
                           (message \"Error at step %d: %S\" idx err)))))
    (while-let ((val (funcall gen)))
      (message \"Yielded: %s\" val)))

Arguments:

- NAME: symbol, the generator function name.
- ARGS: argument list for the generator function.
- BODY: forms containing zero or more `(concur-generator-yield! EXPR)` calls.

Returns:

A function that returns a zero-arg thunk. Calling the thunk advances
the generator to the next yield or completion, returning the yielded
value or nil if done or errored."
  (declare (indent defun))
  (let* ((locals-p (and (consp body) (memq (car (car body)) '(let let*))))
         (locals-form (and locals-p (car body)))
         (code-body (if locals-p (cdr body) body))
         (wrapped `(progn ,@code-body))
         (steps (concur-generator--split-on-yield wrapped))
         (quoted-steps (--map `(quote ,it) steps))
         (name-str (symbol-name name)))
    `(defun ,name ,(append args '(&rest rest-args))
       (log! "generator [%s]: started" ,name-str :info)
      ,(if locals-p
            ;; Fixed: extract actual bindings from (let BINDINGS ...)
            `(let ,(cadr locals-form)
              (apply #'concur-generator (list ,@quoted-steps) rest-args))
          `(apply #'concur-generator (list ,@quoted-steps) rest-args)))))

;;; Aliases
                  
(defalias 'concur-yield! 'concur-generator-yield!)

(provide 'concur-generator)
;;; concur-generator.el ends here                  

