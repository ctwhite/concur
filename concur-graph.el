;;; concur-graph.el --- Asynchronous Task Dependency Graph -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a generic, high-level function, `concur:task-graph!`,
;; for defining and executing a dependency graph of asynchronous tasks. It
;; allows developers to specify tasks and their relationships declaratively,
;; and the system automatically executes them with maximum parallelism.
;;
;; The graph engine is abstract and can be configured with custom "executors"
;; for different task types. This makes it a powerful and extensible foundation
;; for managing complex, cancellable asynchronous workflows.

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-combinators)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-graph-error "Generic error in task graph execution." 'concur-error)
(define-error 'concur-graph-parse-error "Invalid graph definition syntax." 'concur-graph-error)
(define-error 'concur-graph-cycle-error "Cycle detected in the task graph." 'concur-graph-error)
(define-error 'concur-graph-unknown-executor-error "Unknown task type." 'concur-graph-error)
(define-error 'concur-graph-node-not-found-error "Specified node not found." 'concur-graph-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-graph-node (:constructor %%make-graph-node))
  "Represents a single node (task) in a dependency graph.

Fields:
- `name` (symbol): The unique name of the node.
- `type` (keyword): The task type (e.g., `:lisp`), mapping to an executor.
- `form` (any): The Lisp form or command string to execute for this task.
- `dependencies` (list): A list of symbols naming nodes this node depends on.
- `promise` (concur-promise or nil): The promise for this node's result."
  name type form dependencies promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Global Executor Management

(defvar concur--graph-global-executors (make-hash-table :test 'eq)
  "A global hash table mapping executor type keywords to their functions.")

(defun concur:graph-register-executor (type function)
  "Register a global executor for a given `TYPE`.
This allows `concur:task-graph!` to run tasks of this `TYPE`
without needing an explicit `:executors` definition.

Arguments:
- `TYPE` (keyword): The executor type to register (e.g., `:shell`).
- `FUNCTION` (function): An executor function with the signature
  `(lambda (form dep-alist) PROMISE)`."
  (unless (keywordp type) (error "Executor type must be a keyword"))
  (unless (functionp function) (error "Executor must be a function"))
  (puthash type function concur--graph-global-executors))

(defun concur--graph-get-executor (type local-executors)
  "Get an executor for `TYPE`, preferring local over global definitions.

Arguments:
- `TYPE` (keyword): The type of executor to find.
- `LOCAL-EXECUTORS` (plist): The `:executors` plist from the macro call.

Returns:
- (function or nil): The executor function, or `nil` if not found."
  (or (plist-get local-executors type)
      (gethash type concur--graph-global-executors)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Graph Analysis

(defun concur--graph-parse-let-block (let-block-form)
  "Parse the `:let` block of a graph macro into a hash table of nodes.

Arguments:
- `let-block-form` (list): A list of node definition forms.

Returns:
- (hash-table): A hash table mapping node names to `concur-graph-node` structs.

Signals:
- `concur-graph-parse-error` on invalid syntax."
  (unless (listp let-block-form)
    (signal 'concur-graph-parse-error
            (list ":let block must be a list of node definitions" let-block-form)))
  (let ((graph-nodes (make-hash-table :test 'eq)))
    (dolist (binding let-block-form)
      (unless (and (listp binding) (symbolp (car binding))
                   (listp (cadr binding)) (keywordp (caadr binding)))
        (signal 'concur-graph-parse-error
                (list "Invalid node definition. Expected (NAME (TYPE ...))" binding)))
      (let* ((name (car binding))
             (spec (cadr binding))
             (type (car spec))
             (form (cadr spec))
             (deps-plist (cddr spec))
             (deps (plist-get deps-plist :depends-on)))
        (when (gethash name graph-nodes)
          (signal 'concur-graph-parse-error (list "Duplicate node name" name)))
        (puthash name (%%make-graph-node
                       :name name :type type :form form
                       :dependencies (if (listp deps) deps (and deps (list deps))))
                 graph-nodes)))
    graph-nodes))

(defun concur--graph-detect-cycle (nodes)
  "Detect cycles in the dependency graph using Depth-First Search.

Arguments:
- `NODES` (hash-table): The graph nodes.

Returns:
- `nil` if no cycle is found.

Signals:
- `concur-graph-cycle-error` if a cycle is detected."
  (let ((visiting (make-hash-table :test 'eq)) ; Nodes in current DFS path.
        (visited (make-hash-table :test 'eq)))  ; Fully processed nodes.
    (cl-labels ((visit (node-name)
                  (unless (gethash node-name nodes)
                    (signal 'concur-graph-node-not-found-error
                            (list "Dependency not defined as a node" node-name)))
                  (puthash node-name t visiting)
                  (dolist (dep (concur-graph-node-dependencies (gethash node-name nodes)))
                    (when (gethash dep visiting)
                      (signal 'concur-graph-cycle-error
                              (list "Cycle detected in dependency graph" dep)))
                    (unless (gethash dep visited) (visit dep)))
                  (remhash node-name visiting)
                  (puthash node-name t visited)))
      (maphash (lambda (name _) (unless (gethash name visited) (visit name)))
               nodes))))

(defun concur--graph-visualize (nodes target)
  "Generate and display a textual representation of the dependency graph.

Arguments:
- `NODES` (hash-table): The graph nodes.
- `TARGET` (symbol): The final node to visualize dependencies from."
  (let ((output (with-temp-buffer
                  (insert (format "Execution Graph for target: '%s'\n\n" target))
                  (cl-labels ((print-node (node-name indent)
                                (let* ((node (gethash node-name nodes))
                                       (name (symbol-name node-name))
                                       (type (symbol-name (concur-graph-node-type node))))
                                  (insert (make-string indent ?\s) "-> " name
                                          (format " (%s)\n" type))
                                  (dolist (dep (concur-graph-node-dependencies node))
                                    (print-node dep (+ 2 indent))))))
                    (print-node target 0))
                  (buffer-string))))
    (with-current-buffer (get-buffer-create "*concur-graph*")
      (erase-buffer) (insert output) (display-buffer (current-buffer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Graph Execution Engine

(defun concur--graph-run (nodes executors target-node cancel-token)
  "Run the dependency graph to resolve the `TARGET-NODE`.
This function uses recursion with memoization to ensure each node is
executed only once. It resolves dependencies in parallel.

Arguments:
- `NODES` (hash-table): The graph nodes, parsed from the macro.
- `EXECUTORS` (plist): A map from node type keywords to executor functions.
- `TARGET-NODE` (symbol): The final node whose promise should be returned.
- `CANCEL-TOKEN` (concur-cancel-token): Token to cancel the entire graph.

Returns:
- `(concur-promise)`: A promise for the result of the `TARGET-NODE`."
  (unless (gethash target-node nodes)
    (signal 'concur-graph-node-not-found-error
            (list "Target node not found in graph" target-node)))
  (concur-log :info nil "Starting graph execution for target '%S'." target-node)

  (cl-labels ((execute-node-memo (node-name)
             (let ((node (gethash node-name nodes)))
               (unless node
                 (signal 'concur-graph-node-not-found-error
                         (list "Node not found in dependency list" node-name)))
               ;; Return memoized promise if already executing/done.
               (or (concur-graph-node-promise node)
                   (let* ((deps (concur-graph-node-dependencies node))
                          ;; Recursively get promises for dependencies.
                          (dep-promises (mapcar #'execute-node-memo deps)))
                     (concur-log :debug nil "Executing node '%S' (deps: %S)."
                                 node-name deps)
                     ;; Store new promise immediately for memoization.
                     (setf (concur-graph-node-promise node)
                           (concur:chain
                               ;; Wait for all dependencies to resolve.
                               (concur:all dep-promises :cancel-token cancel-token)
                             (:then
                              (lambda (dep-values)
                                (let* ((type (concur-graph-node-type node))
                                       (form (concur-graph-node-form node))
                                       (executor (concur--graph-get-executor
                                                  type executors))
                                       (dep-alist (mapcar #'cons deps dep-values)))
                                  (unless executor
                                    (signal 'concur-graph-unknown-executor-error
                                            (list "No executor for type" type)))
                                  (concur-log :debug nil "Node '%S' running." node-name)
                                  ;; Execute task via its executor.
                                  (funcall executor form dep-alist)))))))))))
    ;; Start execution from the target node.
    (execute-node-memo target-node)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:task-graph! (let-block &rest body)
  "Define and execute a dependency graph of asynchronous tasks.
This function provides a declarative way to define a complex workflow,
which the system then executes with maximum parallelism.

It takes a `:let` block to define tasks, an optional `:executors`
block, and a final `TARGET-NODE`.

Each node in `:let` has the form: `(NAME (TYPE FORM &key DEPENDS-ON))`
- `NAME`: A unique symbol for the node.
- `TYPE`: A keyword specifying the task type (e.g., `:lisp`, `:shell`).
- `FORM`: The Lisp form or command string to execute.
- `DEPENDS-ON`: A symbol or list of symbols this node depends on.

Arguments:
- `LET-BLOCK` (form): `(:let ((node-def-1) ...))` defining the graph.
- `BODY` (list): Remaining forms, which can include:
  - `:executors` (plist): A plist mapping type keywords to executor functions.
    An executor has the signature `(lambda (form dep-alist) PROMISE)`.
    Executors defined here override global ones.
  - `:cancel-token` (concur-cancel-token): A token to cancel the graph.
  - `:show t` (optional): If present, visualizes the graph instead of running it.
  - `TARGET-NODE` (symbol): The final symbol specifying the target node.

Returns:
- `(concur-promise)`: A promise for the result of the `TARGET-NODE`.

Signals:
- `error` for invalid syntax or if a cycle is detected."
  (unless (and (listp let-block) (eq (car let-block) :let) (listp (cadr let-block)))
    (error "concur:task-graph!: `let-block` must be like `(:let (...))`"))

  (let* ((let-definitions (cadr let-block))
         (target-node (car (last body)))
         (executors (plist-get body :executors))
         (cancel-token (plist-get body :cancel-token))
         (show-p (plist-get body :show))
         (nodes (concur--graph-parse-let-block let-definitions)))

    (concur--graph-detect-cycle nodes)

    (if show-p
        (progn
          (concur--graph-visualize nodes target-node)
          (concur:resolved! (format "Graph for %S visualized." target-node)))
      (concur--graph-run nodes executors target-node cancel-token))))

;;;###autoload
(defun concur:graph-status (graph-nodes &optional target-node)
  "Return a snapshot of the status of nodes in a `concur:task-graph!`.
This function is for introspecting a graph that has already been run.

Arguments:
- `GRAPH-NODES` (hash-table): The hash table of `concur-graph-node` structs.
- `TARGET-NODE` (symbol, optional): If provided, limits the status report
  to this node and its dependencies.

Returns:
- (plist): A property list with graph metrics.

Signals:
- `error` if `GRAPH-NODES` is not a hash table or `TARGET-NODE` is not found."
  (interactive)
  (unless (hash-table-p graph-nodes) (error "GRAPH-NODES must be a hash table"))
  (let ((nodes-to-report (make-hash-table :test #'eq))
        (pending-count 0) (resolved-count 0) (rejected-count 0)
        (node-statuses-list '()))
    (if target-node
        (progn
          (unless (gethash target-node graph-nodes)
            (signal 'concur-graph-node-not-found-error (list "Target node" target-node)))
          (cl-labels ((collect-deps (node-name)
                        (unless (gethash node-name nodes-to-report)
                          (puthash node-name t nodes-to-report)
                          (dolist (dep (concur-graph-node-dependencies
                                        (gethash node-name graph-nodes)))
                            (collect-deps dep)))))
            (collect-deps target-node)))
      (maphash (lambda (name _) (puthash name t nodes-to-report)) graph-nodes))
    (maphash
     (lambda (name _)
       (let* ((node (gethash name graph-nodes))
              (promise (concur-graph-node-promise node)))
         (if promise
             (let ((status (concur:status promise)))
               (pcase status
                 (:pending (cl-incf pending-count))
                 (:resolved (cl-incf resolved-count))
                 (:rejected (cl-incf rejected-count)))
               (push `(,name (:status ,status
                              :value ,(concur:value promise)
                              :error ,(concur:error-value promise)))
                     node-statuses-list))
           (cl-incf pending-count)
           (push `(,name (:status :unevaluated)) node-statuses-list))))
     nodes-to-report)
    `(:total-nodes ,(hash-table-count nodes-to-report)
      :pending-nodes ,pending-count :resolved-nodes ,resolved-count
      :rejected-nodes ,rejected-count
      :node-statuses ,(nreverse node-statuses-list))))

(provide 'concur-graph)
;;; concur-graph.el ends here