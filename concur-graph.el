;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-graph.el --- Asynchronous Task Dependency Graph -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a generic, high-level macro, `concur:task-graph!`,
;; for defining and executing a dependency graph of asynchronous tasks. It
;; allows developers to specify a set of tasks and their relationships
;; declaratively, and the system automatically executes them with maximum
;; parallelism.
;;
;; The graph engine is abstract and can be configured with custom "executors"
;; for different task types. This makes it a powerful and extensible foundation
;; for managing complex asynchronous workflows, ensuring tasks run only when
;; their dependencies are met.

;;; Code:

(require 'cl-lib)        ; For cl-defstruct, cl-loop, cl-find, cl-remove
(require 's)             ; For string utilities, e.g., s-join
(require 'concur-core)   ; For `concur-promise` types, `concur:make-promise`,
                         ; `concur:resolved!`, `concur:rejected!`,
                         ; `concur:reject`, `concur-promise-p`,
                         ; `concur:value`, `concur:error-value`,
                         ; `concur-promise-id`, `user-error`, `concur--log`
(require 'concur-chain)       ; For `concur:then`
(require 'concur-combinators) ; For `concur:all`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures & Errors

(define-error 'concur-graph-error
  "A generic error occurred in the task graph execution."
  'concur-error)
(define-error 'concur-graph-cycle-error
  "A cycle was detected in the task dependency graph."
  'concur-graph-error)
(define-error 'concur-graph-unknown-executor-error
  "An unknown task type was encountered in the graph, with no corresponding
  executor defined."
  'concur-graph-error)
(define-error 'concur-graph-node-not-found-error
  "A specified graph node was not found in the graph definition."
  'concur-graph-error)

(cl-defstruct (concur-graph-node (:constructor %%make-concur-graph-node))
  "Represents a single node (task) in a dependency graph.

  Arguments:
  - `name` (symbol): The unique name of the node.
  - `type` (keyword): The type of task (e.g., `:lisp`, `:shell`), which
    maps to an executor function.
  - `form` (any): The Lisp form or command string to execute for this task.
  - `dependencies` (list): A list of symbols naming other nodes that this
    node depends on. This node will not execute until all its dependencies
    have successfully completed.
  - `promise` (concur-promise or nil): The `concur-promise` for this node's
    result. This is `nil` until the node is executed. Defaults to `nil`."
  (name nil :type symbol)
  (type nil :type keyword)
  (form nil)
  (dependencies nil :type list)
  (promise nil :type (or null (satisfies concur-promise-p))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Graph Parsing and Analysis

(defun concur--graph-parse-let-block (let-block-form)
  "Parse the `:let` block of a graph macro into a hash-table of nodes.

  Arguments:
  - `let-block-form` (list): The content of the `:let` block, typically
    `((NODE-DEF-1) (NODE-DEF-2) ...)`. Each `NODE-DEF` is `(NAME (TYPE FORM ...))`.

  Returns:
  - (hash-table): A hash table where keys are node names (symbols) and values
    are `concur-graph-node` structs.

  Signals:
  - `user-error`: If `let-block-form` is not a list."
  (unless (listp let-block-form)
    (user-error "concur--graph-parse-let-block: :let block must be a list of \
                 node definitions: %S" let-block-form))
  (let ((graph-nodes (make-hash-table :test 'eq)))
    (cl-loop for binding in let-block-form do
             (unless (and (listp binding) (symbolp (car binding))
                          (listp (cadr binding)) (keywordp (caadr binding)))
               (user-error "concur--graph-parse-let-block: Invalid node \
                            definition: %S. Expected (NAME (TYPE FORM ...))."
                           binding))
             (let* ((name (car binding))
                    (spec (cadr binding))
                    (type (car spec))
                    (form (cadr spec))
                    (deps-plist (cddr spec))
                    (deps (plist-get deps-plist :depends-on)))
               (when (gethash name graph-nodes)
                 (user-error "concur--graph-parse-let-block: Duplicate node \
                              name '%S'." name))
               (puthash name (%%make-concur-graph-node
                              :name name :type type :form form
                              :dependencies (if (listp deps) deps (list deps)))
                        graph-nodes)))
    graph-nodes))

(defun concur--graph-detect-cycle (nodes)
  "Detect cycles in the dependency graph using Depth-First Search (DFS).
Signals a `concur-graph-cycle-error` if a cycle is found.

  Arguments:
  - `nodes` (hash-table): The graph nodes, a hash table of `concur-graph-node`s.

  Returns:
  - `nil` (side-effect: may signal an error)."
  (let ((visiting (make-hash-table :test 'eq)) ; Nodes currently in DFS path
        (visited (make-hash-table :test 'eq)))  ; Nodes fully processed
    (cl-labels ((visit (node-name)
                  (unless (gethash node-name nodes)
                    (user-error "concur--graph-detect-cycle: Dependency '%S' \
                                 not defined as a node." node-name))
                  (puthash node-name t visiting)
                  (dolist (dep (concur-graph-node-dependencies
                                (gethash node-name nodes)))
                    (when (gethash dep visiting)
                      (concur--log :error nil "Cycle detected involving node %S." dep)
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
  "Generate and display a textual representation of the dependency graph.

  Arguments:
  - `nodes` (hash-table): The graph nodes.
  - `target` (symbol): The final node to visualize dependencies from.

  Returns:
  - `nil` (side-effect: displays graph in messages buffer)."
  (let ((output (with-temp-buffer
                  (insert (format "Execution Graph for target: '%s'\n\n" target))
                  (cl-labels ((print-node (node-name indent)
                                (let* ((node (gethash node-name nodes))
                                       (name-str (symbol-name node-name))
                                       (type-str (symbol-name (concur-graph-node-type node))))
                                  (insert (make-string indent ?\s) "-> "
                                          name-str
                                          (format " (%s)\n" type-str))
                                  (dolist (dep (concur-graph-node-dependencies node))
                                    (print-node dep (+ 2 indent))))))
                    (print-node target 0))
                  (buffer-string))))
    (message "%s" output)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Graph Execution Engine

(defun concur-graph-run (nodes executors target)
  "Run the dependency graph to resolve the TARGET node.
This function uses recursion with memoization (via `concur-graph-node-promise`
field) to ensure each node is executed only once.
It resolves dependencies in parallel using `concur:all`.

  Arguments:
  - `NODES` (hash-table): The graph nodes, parsed from the macro.
  - `EXECUTORS` (plist): A map from node type keywords to executor functions.
    An executor function has the signature `(lambda (form dep-alist) Promise)`.
  - `TARGET` (symbol): The final node whose promise should be returned.

  Returns:
  - (concur-promise): A promise for the result of the `TARGET` node."
  (unless (gethash target nodes)
    (user-error "concur-graph-run: Target node '%S' not found in graph." target))
  (concur--log :info nil "Starting graph execution for target '%S'." target)

  (cl-labels ((execute-node-memo (node-name)
                (let* ((node (gethash node-name nodes)))
                  (unless node
                    (user-error "concur-graph-run: Node '%S' not found." node-name))
                  (or (concur-graph-node-promise node) ; Return memoized promise
                      (let* ((deps (concur-graph-node-dependencies node))
                             ;; Recursively get promises for dependencies
                             (dep-promises (--map #'execute-node-memo deps)))
                        (concur--log :debug nil "Executing node '%S' (deps: %S)."
                                     node-name deps)
                        ;; Store the new promise in the node immediately (memoization)
                        (setf (concur-graph-node-promise node)
                              (concur:chain (concur:all dep-promises) ; Wait for all deps
                                (:then (lambda (dep-values)
                                         (let* ((type (concur-graph-node-type node))
                                                (form (concur-graph-node-form node))
                                                (executor (plist-get executors type))
                                                ;; Create an alist of `(dep-name . dep-value)`
                                                (dep-alist (mapcar #'cons deps dep-values)))
                                           (unless executor
                                             (concur--log :error nil "No executor for type %S in node %S." type node-name)
                                             (signal 'concur-graph-unknown-executor-error
                                                     (list (format "No executor for type %s \
                                                                    in node %s" type node-name))))
                                           (concur--log :debug nil "Node '%S' executing with executor %S."
                                                        node-name type)
                                           ;; Execute the task via its executor
                                           (funcall executor form dep-alist))))
                                (:catch (lambda (err)
                                          (concur--log :error nil "Node '%S' failed: %S" node-name err)
                                          (concur:rejected! (concur:make-error ; Propagate rich error
                                                              :type 'concur-graph-error
                                                              :message (format "Node '%S' failed." node-name)
                                                              :cause err
                                                              :node node-name)))))))
                        (concur-graph-node-promise node)))))
    ;; Start execution from the target node.
    (execute-node-memo target)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

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
- `NAME` (symbol): A unique name for the node.
- `TYPE` (keyword): A keyword specifying the task type (e.g., `:lisp`,
  `:shell`).
- `FORM` (any): The Lisp form or command string to execute for this task.
- `DEPENDS-ON` (symbol or list of symbols, optional): Symbol(s) naming
  the nodes this node depends on.

Arguments:
- `LET-BLOCK` (form): A form `(:let ((node-def-1) ...))` defining the graph.
  It must be a list starting with the keyword `:let`.
- `BODY` (list): The rest of the forms, which must include:
  - `:executors` (plist): A plist mapping type keywords to executor functions.
    An executor has the signature `(lambda (form dep-alist) PROMISE)`.
  - `TARGET-NODE` (symbol): The final symbol specifying the target node
    whose result is desired.
  - `:show t` (optional): If present, visualizes the graph instead of
    running it at macro expansion time.

Returns:
  - (concur-promise): A promise that resolves with the value of the
    `TARGET-NODE` if `:show t` is absent.
  - (form): A form that displays the graph visualization if `:show t` is present.

Signals:
- `user-error`: For invalid input formats.
- `concur-graph-cycle-error`: If a cycle is detected in the dependencies."
  (declare (indent 1) (debug t))
  (unless (and (listp let-block) (eq (car let-block) :let)
               (listp (cadr let-block)))
    (user-error "concur:task-graph!: `let-block` must be a list starting \
                 with :let, like `(:let (...))`. Got: %S" let-block))

  (let* ((target-node (car (last body))) ; Last element is target node
         (executors (plist-get body :executors))
         (show-p (plist-get body :show))
         (nodes (concur--graph-parse-let-block (cadr let-block))))

    ;; Perform validation at macro-expansion time.
    (concur--log :debug nil "Parsing task graph for target %S." target-node)
    (concur--graph-detect-cycle nodes) ; Signals error if cycle exists

    ;; Handle visualization option.
    (when show-p
      (concur--log :info nil "Visualizing task graph for target %S." target-node)
      (concur--graph-visualize nodes target-node)
      (cl-return-from concur:task-graph!
        `(concur:resolved! ',(format "Graph for %S visualized." target-node))))

    ;; Generate the code to run the graph at runtime.
    (concur--log :info nil "Generating graph execution code for target %S."
                 target-node)
    `(concur-graph-run ',nodes ',executors ',target-node)))

;;;###autoload
(defun concur-graph-status (graph-nodes &optional target-node)
  "Return a snapshot of the status of nodes in a `concur:task-graph!`.
This function is intended for introspection on a graph that has already
been run (i.e., where `concur-graph-node-promise` fields are populated).

  Arguments:
  - `GRAPH-NODES` (hash-table): The hash table of `concur-graph-node`
    structs, as generated by `concur--graph-parse-let-block`.
  - `TARGET-NODE` (symbol, optional): If provided, limits the status
    report to this node and its direct/indirect dependencies. Defaults
    to all nodes in the graph.

  Returns:
  - (plist): A property list with graph metrics:
    `:total-nodes`: Total number of nodes in the report scope.
    `:pending-nodes`: Number of nodes whose promises are still pending.
    `:resolved-nodes`: Number of nodes whose promises have resolved.
    `:rejected-nodes`: Number of nodes whose promises have rejected.
    `:node-statuses`: An alist mapping node names to their promise status
      and value/error, e.g., `(NODE-NAME (:status :resolved :value "foo"))`.

  Signals:
  - `user-error`: If `GRAPH-NODES` is not a hash table or `TARGET-NODE`
    is not found."
  (interactive)
  (unless (hash-table-p graph-nodes)
    (user-error "concur-graph-status: GRAPH-NODES must be a hash table: %S"
                graph-nodes))

  (let* ((nodes-to-report (make-hash-table :test #'eq))
         (pending-count 0)
         (resolved-count 0)
         (rejected-count 0)
         (node-statuses-list '()))

    ;; Populate `nodes-to-report` based on `TARGET-NODE` or all nodes.
    (cond
     (target-node
      (unless (gethash target-node graph-nodes)
        (user-error "concur-graph-status: Target node '%S' not found in graph."
                    target-node))
      (cl-labels ((collect-deps (node-name)
                    (unless (gethash node-name nodes-to-report)
                      (puthash node-name t nodes-to-report)
                      (dolist (dep-name (concur-graph-node-dependencies
                                         (gethash node-name graph-nodes)))
                        (collect-deps dep-name)))))
        (collect-deps target-node)))
     (t ; No target-node, report all nodes.
      (maphash (lambda (name _) (puthash name t nodes-to-report)) graph-nodes)))

    ;; Iterate over collected nodes and get their status.
    (maphash (lambda (name _)
               (let* ((node (gethash name graph-nodes))
                      (promise (concur-graph-node-promise node)))
                 (if promise
                     (let* ((status (concur:status promise))
                            (val (when (eq status :resolved)
                                   (concur:value promise)))
                            (err (when (eq status :rejected)
                                   (concur:error-value promise))))
                       (pcase status
                         (:pending (cl-incf pending-count))
                         (:resolved (cl-incf resolved-count))
                         (:rejected (cl-incf rejected-count)))
                       (push `(,name (:status ,status
                                      :value ,val
                                      :error ,err))
                             node-statuses-list))
                   ;; Node not yet executed (promise is nil)
                   (cl-incf pending-count)
                   (push `(,name (:status :unevaluated))
                         node-statuses-list))))
             nodes-to-report)

    `(:total-nodes ,(hash-table-count nodes-to-report)
      :pending-nodes ,pending-count
      :resolved-nodes ,resolved-count
      :rejected-nodes ,rejected-count
      :node-statuses ,(nreverse node-statuses-list))))

(provide 'concur-graph)
;;; concur-graph.el ends here