;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-pipeline.el --- High-Level Asynchronous Pipelines -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a high-level macro, `concur:pipeline!`, for
;; defining and executing linear data-processing workflows that can
;; seamlessly mix external shell commands and internal Lisp functions.
;;
;; It is built on top of the generic graph engine from `concur-graph.el`
;; but provides a simplified syntax focused on a common use case: taking
;; an initial input and "piping" it through a series of transformations.
;;
;; It uses `concur:shell-session` for its `:shell` executor, ensuring
;; that even complex pipelines with stateful shell commands execute reliably.

;;; Code:

(require 'cl-lib)     ; For cl-loop, cl-subseq, cl-delete-duplicates
(require 's)          ; For string utilities, e.g., s-join
(require 'concur-core) ; For `concur-promise` types, `concur:resolved!`,
                       ; `concur:rejected!`, `user-error`, `concur--log`
(require 'concur-graph) ; For `concur:task-graph!` (underlying engine)
(require 'concur-async) ; For `concur:async!` (Lisp executor)
(require 'concur-shell) ; For `concur:shell-session` (Shell executor)
(require 'concur-chain) ; For `concur:chain`, `concur:then` (promise chaining)
(require 'concur-process) ; For `concur:command` (used in shell executor's chain)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(defmacro concur:pipeline! (initial-input &rest steps)
  "Define and execute a linear pipeline of asynchronous steps.
This macro takes an `INITIAL-INPUT` and threads it through a series of
steps. Each step can be a shell command or a Lisp function. The result
of each step is passed as the input to the next.

Each step in the pipeline can be one of two forms:
1.  `(:shell \"command-string...\")`: Executes a shell command. The input from
    the previous step is available as the anaphoric variable `<>`. The `stdout`
    of the command becomes the input for the next step.
2.  `(lisp-function ...)`: Any other form is treated as a Lisp function call.
    The anaphoric variable `<>` is bound to the input from the previous step.
    The return value becomes the input for the next step.

Arguments:
- `INITIAL-INPUT` (form): A form evaluating to the initial value for the pipeline.
- `STEPS` (list): A list of pipeline step forms.

Returns:
  (concur-promise) A promise that resolves with the value of the final
  step in the pipeline. If any step rejects, the pipeline's promise
  will reject."
  (declare (indent 1) (debug t))
  (unless (listp steps)
    (user-error "concur:pipeline!: STEPS must be a list. Got: %S" steps))
  (concur--log :info nil "Defining pipeline with initial input %S and %d steps."
               initial-input (length steps))

  (let* ((nodes '())
         (prev-node-name (gensym "pipeline-start-"))
         ;; Define the executor for `:lisp` steps.
         (lisp-executor
          '(lambda (form dep-alist)
             ;; Get input from the single dependency.
             ;; `dep-alist` is `((<dep-node-name> . <dep-value>))`.
             (let ((input (cdr (car dep-alist))))
               (concur--log :debug nil "Pipeline Lisp executor: input %S, form %S."
                            input form)
               ;; `concur:async!` (from `concur-async.el`) runs Lisp code
               ;; in a background worker pool or deferred.
               (concur:async! `(let ((<> ,input)) ,form)))))
         ;; Define the executor for `:shell` steps.
         (shell-executor
          '(lambda (form dep-alist)
             ;; Get input from the single dependency.
             (let ((input (cdr (car dep-alist))))
               (concur--log :debug nil "Pipeline Shell executor: input %S, form %S."
                            input form)
               ;; Use a session to robustly execute the shell command.
               (concur:chain
                   (concur:shell-session (shell-run-fn)
                     ;; Evaluate `form` with `<>` bound to input,
                     ;; then execute the resulting command string.
                     (let ((command-string (eval `(let ((<> ,input)) ,form))))
                       (concur--log :debug nil "Executing shell command: %S."
                                    command-string)
                       ;; `concur:command` handles exit code and stderr checks.
                       ;; It resolves with stdout string or rejects.
                       (funcall shell-run-fn command-string)))
                 ;; The previous step resolves with `concur-process-result`.
                 (:then (lambda (command-output-string)
                          command-output-string))))))) ; Pass stdout string to next step

    ;; Convert the linear steps into a dependency graph `let` block.
    ;; The first node `start` provides the `initial-input`.
    (push `(,prev-node-name (:lisp ,initial-input)) nodes)

    (cl-loop for step in steps for i from 0 do
             (let* ((node-name (gensym (format "pipeline-step-%d-" i)))
                    (type (if (eq (car-safe step) :shell) :shell :lisp))
                    (form (if (eq type :shell) (cadr step) step)))
               ;; Each node depends only on the previous node.
               (push `(,node-name (,type ',form :depends-on ,prev-node-name))
                     nodes)
               (setq prev-node-name node-name)))

    ;; Expand to a call to the generic graph macro with our executors.
    ;; The last `prev-node-name` is the target for the graph.
    `(concur:task-graph! (:let ,(nreverse nodes))
       :executors (:lisp ,lisp-executor :shell ,shell-executor)
       ,prev-node-name)))

(provide 'concur-pipeline)
;;; concur-pipeline.el ends here