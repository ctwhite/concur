;;; concur-graph.el --- Asynchronous Task Dependency Graph -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a generic, high-level macro, `concur:task-graph!`,
;; for defining and executing a dependency graph of asynchronous tasks. It allows
;; developers to specify a set of tasks and their relationships declaratively,
;; and the system automatically executes them with maximum parallelism.
;;
;; The graph engine is abstract and can be configured with custom "executors"
;; for different task types. This makes it a powerful and extensible foundation
;; for managing complex asynchronous workflows.

;;; Code:

(require 'cl-lib)
(require 's)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-combinators)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures & Errors

(define-error 'concur-graph-error "Error in the task graph." 'concur-error)
(define-error 'concur-graph-cycle-error "Cycle detected in task graph."
  'concur-graph-error)
(define-error 'concur-graph-unknown-executor-error
  "Unknown task type in graph." 'concur-graph-error)

(cl-defstruct (concur-graph-node (:constructor %%make-concur-graph-node))
  "Represents a single node (task) in a dependency graph.

Fields:
- `name` (symbol): The unique name of the node.
- `type` (keyword): The type of task, e.g., `:lisp` or `:shell`.
- `form` (any): The Lisp form or command string to execute.
- `dependencies` (list): Symbols naming the nodes this node depends on.
- `promise` (concur-promise): The promise for this node's result."
  name type form dependencies promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Graph Parsing and Analysis

(defun concur--graph-parse-let-block (let-block)
  "Parse the `:let` block of a graph macro into a hash-table of nodes."
  (let ((graph-nodes (make-hash-table :test 'eq)))
    (dolist (binding let-block)
      (let* ((name (car binding))
             (spec (cadr binding))
             (type (car spec))
             (form (cadr spec))
             (deps (plist-get (cddr spec) :depends-on)))
        (puthash name (%%make-concur-graph-node
                       :name name :type type :form form
                       :dependencies (if (listp deps) deps (list deps)))
                 graph-nodes)))
    graph-nodes))

(defun concur--graph-detect-cycle (nodes)
  "Detect cycles in the dependency graph using DFS. Signals an error if found."
  (let ((visiting (make-hash-table :test 'eq))
        (visited (make-hash-table :test 'eq)))
    (cl-labels ((visit (node-name)
                  (puthash node-name t visiting)
                  (dolist (dep (concur-graph-node-dependencies
                                (gethash node-name nodes)))
                    (when (gethash dep visiting)
                      (signal 'concur-graph-cycle-error
                              (list (format "Cycle detected involving node %s" dep))))
                    (unless (gethash dep visited)
                      (visit dep)))
                  (remhash node-name visiting)
                  (puthash node-name t visited)))
      (maphash (lambda (name _)
                 (unless (gethash name visited)
                   (visit name)))
               nodes))))

(defun concur--graph-visualize (nodes target)
  "Generate and display a textual representation of the dependency graph."
  (let ((output (with-temp-buffer
                  (insert (format "Execution Graph for target: '%s'\n\n" target))
                  (cl-labels ((print-node (node-name indent)
                                (insert (make-string indent ?\s) "-> "
                                        (symbol-name node-name) "\n")
                                (dolist (dep (concur-graph-node-dependencies
                                              (gethash node-name nodes)))
                                  (print-node dep (+ 2 indent)))))
                    (print-node target 0))
                  (buffer-string))))
    (message "%s" output)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Graph Execution Engine

(defun concur-graph-run (nodes executors target)
  "Run the dependency graph to resolve the TARGET node.
This function uses recursion with memoization to ensure each node is
executed only once.

Arguments:
- `NODES` (hash-table): The graph nodes, parsed from the macro.
- `EXECUTORS` (plist): A map from node type keywords to executor functions.
- `TARGET` (symbol): The final node whose promise should be returned.

Returns:
  (concur-promise) A promise for the result of the `TARGET` node."
  (let ((memo (make-hash-table)))
    (cl-labels ((execute-node-memo (node-name)
                  ;; Retrieve the promise from the cache, or compute it.
                  (or (gethash node-name memo)
                      (let* ((node (gethash node-name nodes))
                             (deps (concur-graph-node-dependencies node))
                             (dep-promises (--map (execute-node-memo it) deps)))
                        (unless node (error "Graph node '%s' not found" node-name))
                        ;; Store the new promise in the cache immediately.
                        (puthash
                         node-name
                         (concur:then
                          (concur:all dep-promises)
                          (lambda (dep-values)
                            (let* ((type (concur-graph-node-type node))
                                   (form (concur-graph-node-form node))
                                   (executor (plist-get executors type))
                                   (dep-alist (mapcar #'cons deps dep-values)))
                              (unless executor
                                (signal 'concur-graph-unknown-executor-error
                                        (list (format "No executor for type %s" type))))
                              (funcall executor form dep-alist))))
                         memo)))))
      (execute-node-memo target))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro concur:task-graph! (let-block &rest body)
  "Define and execute a dependency graph of asynchronous tasks.
This macro provides a declarative way to define a complex workflow,
which the system then executes with maximum parallelism.

The macro takes three parts: a `:let` block to define the task nodes,
an `:executors` block to define how to run each task type, and a
final form specifying the target node whose result is desired.

Each node in the `:let` block has the form:
`(NAME (TYPE FORM &key DEPENDS-ON))`
- `NAME`: A symbol to name the node.
- `TYPE`: A keyword specifying the task type (e.g., `:lisp`, `:shell`).
- `FORM`: The Lisp form or command string to execute.
- `DEPENDS-ON`: A symbol or list of symbols naming other nodes.

Arguments:
- `LET-BLOCK` (form): A form `(:let ((node-def-1) ...))` defining the graph.
- `BODY` (list): The rest of the forms, including:
  - `:executors` (plist): A plist mapping type keywords to executor functions.
    An executor has the signature `(lambda (form dep-alist) ...)`.
  - `(target-node)`: A final symbol specifying the target node.
  - `:show t` (optional): To visualize the graph instead of running it.

Returns:
  (concur-promise) A promise that resolves with the value of the target node."
  (declare (indent 1) (debug t))
  (let* ((target (car (last body)))
         (executors (plist-get body :executors))
         (show-p (plist-get body :show))
         (nodes (concur--graph-parse-let-block (cadr let-block))))
    ;; Perform validation and visualization at macro-expansion time.
    (concur--graph-detect-cycle nodes)
    (when show-p
      (concur--graph-visualize nodes target)
      (cl-return-from concur:task-graph!
        `(concur:resolved! ',(format "Graph for %s visualized." target))))
    ;; Generate the code to run the graph at runtime.
    `(concur-graph-run ',nodes ',executors ',target)))

(provide 'concur-graph)
;;; concur-graph.el ends here