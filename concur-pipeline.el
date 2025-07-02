;;; concur-pipeline.el --- High-Level Asynchronous Pipelines -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a high-level macro, `concur:pipeline!`, for
;; defining and executing linear data-processing workflows. It allows for
;; seamlessly mixing external shell commands and internal Emacs Lisp functions
;; in a clear, sequential syntax.
;;
;; It is built on top of `concur:chain`, inheriting its flexibility. This
;; means standard chaining clauses like `:catch` and `:log` can be used
;; directly within a pipeline definition for fine-grained control.
;;
;; The pipeline ensures that shell commands are executed in a stateful
;; session, allowing subsequent commands to rely on the state (e.g., current
;; directory) of previous ones.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-shell)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-pipeline-error
  "An error occurred during pipeline execution."
  'concur-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Macro Helpers

(defun concur--pipeline-expand-steps (steps)
  "Expand `concur:pipeline!` `STEPS` into `concur:chain` clauses.

Arguments:
- `STEPS` (list): The list of pipeline step forms.

Returns:
- `(list)`: A new list of forms suitable for `concur:chain`."
  (let (expanded-steps anaphor)
    (setq anaphor (intern (symbol-name concur-chain-anaphoric-symbol)))
    (while steps
      (let* ((step-name-clause (when (eq (car-safe (car steps)) :name) (pop steps)))
             (step-name (when step-name-clause (cadr step-name-clause)))
             (step (pop steps)))
        (unless step (error "Incomplete pipeline definition"))

        (when step-name
          (push `(:tap (lambda (val err)
                         (concur--log :info nil "[Pipeline START] %s" ,step-name)))
                expanded-steps))

        (pcase step
          ;; Pass through standard chain clauses directly.
          ((or `(:then ,_) `(:catch ,_) `(:finally ,_) `(:tap ,_) `(:log ,_))
           (push step expanded-steps))

          ;; Handle a shell command step.
          (`(:shell ,command)
           (push `(:then (lambda (,anaphor)
                           (concur:shell-command
                            (s-lex-format ,command ,anaphor))))
                 expanded-steps))

          ;; Handle a Lisp form step.
          (_
           (push `(:then (lambda (,anaphor)
                           ;; Use backquote to safely inject the runtime value
                           ;; of the anaphor into the form sent to the pool.
                           (concur:pool-eval
                            `(let ((,,anaphor ',,anaphor)) ,,step))))
                 expanded-steps)))

        (when step-name
          (push `(:tap (lambda (val err)
                         (concur--log :info nil "[Pipeline END]   %s -> %S"
                                      ,step-name (or val err))))
                expanded-steps))))
    (nreverse expanded-steps)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro concur:pipeline! (initial-input &rest steps)
  "Define and execute a linear pipeline of asynchronous steps.
This macro takes an `INITIAL-INPUT` and threads it through a series of
steps. Each step's output becomes the next step's input. The pipeline
is built on `concur:chain`, so standard clauses like `:catch` and `:log`
can be used between steps.

Pipeline-specific Steps:
- `(:shell \"command...\")`: Executes a shell command. The input from the
  previous step is available via `{<>}` in the command string (see
  `s-lex-format`). The `stdout` of the command becomes the next input.
- `(lisp-function ...)`: Any other form is treated as a Lisp function call
  to be executed in a worker pool. The anaphoric variable `<>` (or the
  symbol in `concur-chain-anaphoric-symbol`) is bound to the previous
  step's result.
- `(:name \"Step Name\")`: A special clause that can precede any step to
  provide descriptive logging for that step.

Arguments:
- `INITIAL-INPUT` (form): A form for the initial pipeline value.
- `STEPS` (list): A list of pipeline step forms.

Returns:
- `(concur-promise)`: A promise that resolves with the value of the final
  step, or rejects if any step fails."
  (declare (indent 1) (debug t))
  (unless (listp steps) (error "STEPS must be a list. Got: %S" steps))
  (concur--log :info nil "Defining pipeline with %d steps." (length steps))

  ;; Use a `shell-session` to ensure all :shell steps run in the same
  ;; stateful environment, preserving CWD, env vars, etc.
  `(concur:shell-session (shell)
     (let ((concur-chain-anaphoric-symbol ',concur-chain-anaphoric-symbol))
       (apply #'concur:chain
              (concur:resolved! ,initial-input)
              (concur--pipeline-expand-steps ',steps)))))

(provide 'concur-pipeline)
;;; concur-pipeline.el ends here