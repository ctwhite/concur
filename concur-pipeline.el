;;; concur-pipeline.el --- High-Level Asynchronous Pipelines -*-
;;; lexical-binding: t; -*-

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

(require 'cl-lib)
(require 's)
(require 'concur-core)
(require 'concur-graph)
(require 'concur-async)
(require 'concur-shell)
(require 'concur-chain)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro concur:pipeline! (initial-input &rest steps)
  "Define and execute a linear pipeline of asynchronous steps.
This macro takes an INITIAL-INPUT and threads it through a series of
steps. Each step can be a shell command or a Lisp function. The result
of each step is passed as the input to the next.

Each step in the pipeline can be one of two forms:
1. `(:shell \"command-string...\")`: Executes a shell command. The input from
   the previous step is available as the anaphoric variable `<>`. The `stdout`
   of the command becomes the input for the next step.
2. `(lisp-function ...)`: Any other form is treated as a Lisp function call.
   The anaphoric variable `<>` is bound to the input from the previous step.
   The return value becomes the input for the next step.

Arguments:
- `INITIAL-INPUT` (form): A form evaluating to the initial value for the pipeline.
- `STEPS` (list): A list of pipeline step forms.

Returns:
  (concur-promise) A promise that resolves with the value of the final
  step in the pipeline."
  (declare (indent 1) (debug t))
  (let* ((nodes '())
         (prev-node-name 'start)
         ;; Define the executor for `:lisp` steps.
         (lisp-executor
          '(lambda (form dep-alist)
             ;; BUG FIX: Get input from the single dependency, not a hardcoded key.
             (let ((input (cdr (car dep-alist))))
               ;; `concur:async!` (from `concur-async.el`) is assumed to exist
               ;; for running Lisp code in a background worker pool.
               (concur:async! `(let ((<> ,input)) ,form)))))
         ;; Define the executor for `:shell` steps.
         (shell-executor
          '(lambda (form dep-alist)
             ;; BUG FIX: Get input from the single dependency.
             (let ((input (cdr (car dep-alist))))
               ;; Use a session to robustly execute the shell command.
               (concur:shell-session (run!)
                 (let* ((command-string (eval `(let ((< > ,input)) ,form)))
                        (result-promise (run! command-string)))
                   ;; Pipe only stdout to the next step.
                   (concur:then (cdr result-promise)
                                (lambda (_)
                                  (concur:stream-drain
                                   (car result-promise))))))))))

    ;; Convert the linear steps into a dependency graph `let` block.
    (push `(start (:lisp ,initial-input)) nodes)
    (cl-loop for step in steps for i from 0 do
             (let* ((node-name (make-symbol (format "step-%d" i)))
                    (type (if (eq (car-safe step) :shell) :shell :lisp))
                    (form (if (eq type :shell) (cadr step) step)))
               (push `(,node-name (,type ',form :depends-on ,prev-node-name)) nodes)
               (setq prev-node-name node-name)))

    ;; Expand to a call to the generic graph macro with our executors.
    `(concur:task-graph! (:let ,(nreverse nodes))
       :executors (:lisp ,lisp-executor :shell ,shell-executor)
       ,prev-node-name)))

(provide 'concur-pipeline)
;;; concur-pipeline.el ends here