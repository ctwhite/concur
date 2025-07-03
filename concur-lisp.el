;;; concur-lisp.el --- Persistent Lisp Worker Pool -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a high-performance, persistent worker pool for
;; executing asynchronous Emacs Lisp evaluation tasks. It is built upon the
;; generic `concur-abstract-pool` framework, specializing it for Lisp code.
;;
;; By maintaining a pool of ready-to-use background Emacs processes, it
;; avoids the overhead of starting a new process for each task. This makes
;; it ideal for parallelizing CPU-bound Lisp computations without freezing
;; the user interface.
;;
;; Key Features:
;; - Low-overhead execution of arbitrary Lisp forms.
;; - Priority-based task queue for managing workloads.
;; - High-level convenience macros like `concur:lisp-graph!` for defining
;;   and executing complex dependency graphs of Lisp computations.

;;; Code:

(require 'cl-lib)
(require 'concur-async)
(require 'concur-abstract-pool)
(require 'concur-graph)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (concur-lisp-task (:include concur-abstract-task))
  "A specialized task for the Lisp worker pool.

It extends the abstract task with fields specific to Lisp evaluation.

Fields:
- `form` (t): The Lisp S-expression to be evaluated in the worker.
- `vars` (alist): An association list of variables to be lexically bound
  within the worker during the evaluation of `form`, in the style of `let`."
  (form nil :type t)
  (vars nil :type (or null alist)))

(cl-defstruct (concur-lisp-pool (:include concur-abstract-pool))
  "A pool of persistent Lisp workers.
This struct currently has no fields beyond the abstract pool but is defined
for type-checking and future extension.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Worker Logic

(defun concur--lisp-task-executor-fn (payload context)
  "The function that executes a Lisp form inside a worker process.
This is the core logic that runs in the background. It takes the raw
payload (the form) and context (the `let` bindings) and evaluates them.

Arguments:
- `PAYLOAD` (t): The Lisp form to evaluate.
- `CONTEXT` (plist): A property list containing `:vars` for `let` bindings.

Returns:
- The result of the evaluated form."
  (let ((form payload)
        (vars (plist-get context :vars)))
    ;; The form is wrapped in a `let` to establish the lexical environment
    ;; requested by the task submitter.
    (eval `(let ,vars ,form) t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Pool Creation and Management

(defvar *concur-default-lisp-pool* nil
  "The global default instance of the Lisp worker pool.
It is initialized lazily on its first use.")

(defun concur--lisp-pool-get-default ()
  "Return or create the default global Lisp worker pool.
This function ensures that a single, shared instance of the pool is
available throughout an Emacs session."
  (unless (and *concur-default-lisp-pool*
               (concur-abstract-pool-p *concur-default-lisp-pool*))
    (setq *concur-default-lisp-pool* (concur:lisp-pool-create)))
  *concur-default-lisp-pool*)

(cl-defun concur:lisp-pool-create (&key (size 4))
  "Create and initialize a new Lisp worker pool."
  (concur-abstract-pool-create
   :name "lisp-pool"
   :size size
   :task-queue-type :priority
   :worker-factory-fn
   (lambda (worker _abstract-pool)
     (setf (concur-abstract-worker-process worker)
           (concur:async-launch
            `(lambda ()
               (concur--abstract-worker-entry-point
                #'concur--lisp-task-executor-fn nil))
            :require '(concur-lisp
                       concur-abstract-pool))))

   :worker-ipc-filter-fn
   (lambda (worker chunk pool)
     (let* ((proc (concur-abstract-worker-process worker))
            (buffer (concat (or (process-get proc 'ipc-buffer) "") chunk))
            (start 0)
            end)
       (while (setq end (string-match "\n" buffer start))
         (let ((line (substring buffer start end)))
           (when (>= (length line) 2)
             (let* ((prefix (substring line 0 2))
                    (payload (substring line 2))
                    (task (concur-abstract-worker-current-task worker)))
               (when task
                 (pcase prefix
                   ("R:" (concur--abstract-pool-handle-worker-output worker task `(:type :result :payload ,payload) pool))
                   ("E:" (concur--abstract-pool-handle-worker-output worker task `(:type :error :payload ,payload) pool))
                   ("M:" (concur--abstract-pool-handle-worker-output worker task `(:type :message :payload ,payload) pool)))))))
         (setq start (1+ end)))
       (process-put proc 'ipc-buffer (substring buffer start))))

   :worker-ipc-sentinel-fn
   (lambda (worker event pool)
     (concur--abstract-pool-handle-worker-death worker event pool))

   :task-serializer-fn
   (lambda (payload context)
     (prin1-to-string `(:id nil :payload ,payload :context ,context)))
   :result-parser-fn
   (lambda (s) (plist-get (read s) :result))
   :error-parser-fn
   (lambda (s) (concur-deserialize-error (plist-get (read s) :error)))
   :message-parser-fn
   (lambda (s) (read s))))
   
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(cl-defun concur:lisp-submit-task (pool form &key vars priority)
  "Submit a Lisp `FORM` to the `POOL` for asynchronous evaluation.

Arguments:
- `POOL` (concur-lisp-pool): The pool to submit the task to.
- `FORM` (t): The Lisp form to evaluate.
- `:vars` (alist, optional): A list of `(var value)` pairs to be `let`-bound
  during the evaluation of `FORM`.
- `:priority` (integer, optional): The task's priority (lower is higher).

Returns:
- A `concur-promise` that resolves with the result of the evaluation."
  (concur-abstract-pool-submit-task
   pool form :context `(:vars ,vars) :priority priority))

(defmacro concur:lisp! (form &rest keys)
  "Evaluate `FORM` in the default Lisp pool. A convenient shorthand.

Arguments:
- `FORM` (form): The Lisp form to evaluate.
- `KEYS` (plist): Keyword arguments for `concur:lisp-submit-task`, like
  `:vars` or `:priority`.

Returns:
- A `concur-promise` for the result."
  (declare (indent 1))
  `(apply #'concur:lisp-submit-task (concur--lisp-pool-get-default) ',form ',keys))

(defun concur:lisp-pool-shutdown! (&optional pool)
  "Shut down the Lisp worker pool, terminating all background processes.

Arguments:
- `POOL` (concur-lisp-pool, optional): The specific pool to shut down.
  If nil, shuts down the default global pool."
  (interactive)
  (let ((p (or pool *concur-default-lisp-pool*)))
    (when p (concur-abstract-pool-shutdown! p)))
  (when (eq pool *concur-default-lisp-pool*)
    (setq *concur-default-lisp-pool* nil)))

;;;###autoload
(defmacro concur:lisp-graph! (let-block &rest body)
  "Define and execute a dependency graph of Lisp tasks.
This is a convenience wrapper around `concur:task-graph!` that configures
it to use the default Lisp worker pool as its executor.

Each node in `:let` has the form: `(NAME (FORM &key DEPENDS-ON))`
- `NAME`: A symbol for the node.
- `FORM`: The Lisp form to evaluate. Resolved values of dependencies
  are available as variables inside this form.
- `DEPENDS-ON`: A symbol or list of symbols naming node dependencies.

Arguments:
- `LET-BLOCK` (form): `(:let ((node-def-1) ...))` defining the graph.
- `BODY` (list): Remaining forms, including the final target node symbol
  and optionally `:show t` to visualize the graph.

Returns:
- `(concur-promise)`: A promise that resolves with the value of the target node."
  (declare (indent 1) (debug t))
  (let* ((user-nodes (cadr let-block))
         ;; Wrap nodes to be compatible with the generic `task-graph` macro.
         (wrapped-nodes (mapcar (lambda (it) `(,(car it) (:lisp ,@(cdr it))))
                                user-nodes))
         (wrapped-let-block `(:let ,wrapped-nodes))
         ;; Define the executor for :lisp tasks. It submits a task to the
         ;; default lisp pool, providing the dependency results as `let` bindings.
         (lisp-executor
          '(lambda (form dep-alist)
             (concur:lisp-submit-task (concur--lisp-pool-get-default)
                                      form
                                      :vars dep-alist))))
    ;; Delegate to the generic graph macro.
    `(concur:task-graph! ,wrapped-let-block
       :executors (:lisp ,lisp-executor)
       ,@body)))

(provide 'concur-lisp)
;;; concur-lisp.el ends here