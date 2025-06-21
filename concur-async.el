;;; concur-async.el --- High-level async primitives for Emacs -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a suite of high-level asynchronous primitives that
;; build upon the foundational `concur-promise` system. It aims to make
;; complex asynchronous workflows easy to write and reason about.
;;
;; Core Features:
;;
;; - `concur:async!`: A powerful macro for running tasks in different
;;   execution contexts, including the high-performance persistent worker
;;   pool from `concur-pool.el`.
;;
;; - `concur:lisp-graph!`: A high-level macro for defining and executing
;;   a dependency graph of Lisp functions with maximum parallelism.
;;
;; - Async Iteration: `concur:sequence!` and `concur:parallel!` provide
;;   powerful iteration over collections with asynchronous functions.
;;
;; - Composition Macros: `concur:let-promise`, `concur:race!`, and others
;;   provide an ergonomic, declarative syntax for complex control flow.

;;; Code:

(require 'cl-lib)
(require 'async)
(require 'coroutines)

;; Core Concur modules
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-future)
(require 'concur-pool)
(require 'concur-graph)
(require 'concur-registry)
(require 'concur-combinators)
(require 'concur-semaphore)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization, Hooks, & Errors

(defgroup concur-async nil
  "High-level asynchronous primitives for Concur."
  :group 'concur)

(define-error 'concur-async-error "Concurrency async operation error." 'concur-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State & Helpers

(defun concur--apply-semaphore-wrapping (tasks semaphore)
  "Wrap each promise in TASKS with semaphore acquisition and release."
  (--map
   (lambda (task)
     (concur:chain (concur:semaphore-acquire semaphore)
       (:then (lambda (_) task))
       (:finally (lambda () (concur:semaphore-release semaphore)))))
   tasks))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Execution Strategy Helpers

(defun concur--async-create-task-wrapper (fn)
  "Create a wrapper lambda for a task to handle its lifecycle."
  (lambda (resolve-fn reject-fn)
    (condition-case err
        (funcall resolve-fn (funcall fn))
      (error (funcall reject-fn err)))))

(defun concur--async-run-in-deferred (task-wrapper cancel-token)
  "Execute a task in 'deferred' mode (run-at-time 0)."
  (concur:with-executor
      (lambda (resolve reject)
        (run-at-time 0 nil (lambda () (funcall task-wrapper resolve reject))))
    :cancel-token cancel-token))

(defun concur--async-run-in-thread (fn cancel-token)
  "Execute a task in 'thread' mode (native Emacs thread).
It runs the task in a background thread and uses a polling timer
on the main thread to check for the result."
  (concur:with-executor (lambda (resolve reject)
    (let ((mailbox (list nil)) timer)
      (make-thread
       (lambda ()
         (condition-case err
             (setcar mailbox (cons :success (funcall fn)))
           (error (setcar mailbox (cons :failure err)))))
       "concur-thread")
      ;; NOTE: This polling timer is a simple but potentially inefficient way
      ;; to get the result back to the main thread.
      (setq timer
            (run-at-time
             0.01 0.01
             (lambda ()
               (when-let ((result (car mailbox)))
                 (cancel-timer timer)
                 (pcase result
                   (`(:success . ,val) (funcall resolve val))
                   (`(:failure . ,err) (funcall reject err)))))))))
    :cancel-token cancel-token
    :mode :thread))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Main Task Execution

;;;###autoload
(cl-defun concur:start! (fn &key (mode 'deferred) name cancel-token
                             require form timeout priority)
  "Run FN asynchronously according to MODE and return a `concur-promise`.
This is the core functional primitive for running asynchronous tasks.

Arguments:
- `FN` (function or nil): The nullary function to execute asynchronously.
  Can be nil if `:form` is provided for `'async` mode.
- `:mode` (symbol): The execution mode.
  - `deferred` or `t` (default): Execute on an idle timer.
  - `async`: Execute in the persistent background Lisp worker pool.
  - `thread`: Execute in a native Emacs thread.
- `:name` (string, optional): A descriptive name for the task for debugging.
- `:cancel-token` (concur-cancel-token, optional): For cancellation.
- `:require` (list), `:form` (any), `:priority` (integer), `:timeout` (number):
  Options specifically for the `'async` (worker pool) mode.

Returns:
  (concur-promise) A promise that will settle with the result of `FN`."
  (let* ((promise-mode (if (memq mode '(async thread)) mode :deferred))
         (promise (concur:make-promise :cancel-token cancel-token
                                       :mode promise-mode)))

    (when (fboundp 'concur-register-promise)
      (concur-register-promise promise (or name "unnamed-task")))

    (pcase mode
      ((or 'deferred 't (pred null))
       (concur--async-run-in-deferred
        (concur--async-create-task-wrapper fn) cancel-token))
      ('async
       (concur-pool-submit-task (concur-pool-get-default) promise form
                                (or require nil)
                                :priority (or priority 50)
                                :timeout timeout))
      ('thread
       (concur--async-run-in-thread fn cancel-token))
      (_ (concur:reject promise
                        (concur:make-error :type 'concur-async-error
                                           :message "Unknown mode"))))
    promise))

;;;###autoload
(defmacro concur:async! (task-form &rest keys)
  "Run TASK-FORM asynchronously and return a promise.
This is a convenient macro wrapper around the core `concur:start!` function.

Arguments:
- `TASK-FORM` (form): The Lisp form to execute asynchronously.
- `KEYS` (plist): Options to pass to `concur:start!`, such as
  `:mode`, `:name`, `:cancel-token`, etc.

Returns:
  (concur-promise) A promise that will settle with the result of `TASK-FORM`."
  (declare (indent 1) (debug t))
  (let* ((mode (plist-get keys :mode))
         ;; For 'async mode, we pass the raw form. For others, we create a lambda.
         (fn-form (if (eq mode 'async) nil `(lambda () ,task-form)))
         (form-arg (if (eq mode 'async) `',task-form nil)))
    `(apply #'concur:start! ,fn-form :form ,form-arg (list ,@keys))))

;;;###autoload
(defmacro concur:deferred! (task-form &rest keys)
  "Run TASK-FORM asynchronously on an idle timer.
This is a convenient shorthand for `(concur:async! task-form :mode 'deferred ...)`.

Arguments:
- `TASK-FORM` (form): The Lisp form to execute.
- `KEYS` (plist): Options like `:name` and `:cancel-token`.

Returns:
  (concur-promise) A promise for the result of `TASK-FORM`."
  `(concur:async! ,task-form :mode 'deferred ,@keys))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Iteration and Mapping

;;;###autoload
(defmacro concur:sequence! (items-form &key fn semaphore)
  "Process ITEMS sequentially with async function FN.
Each call to `FN` begins only after the promise from the previous call has resolved.

Arguments:
- `ITEMS-FORM` (form): An expression that evaluates to the list of items.
- `:fn` (function): A function that takes one item and returns a promise.
- `:semaphore` (concur-semaphore, optional): A semaphore to acquire
  before processing each item.

Returns:
  (concur-promise) A promise that resolves with a list of all results."
  (declare (indent 2) (debug t))
  (unless fn (error "concur:sequence! requires the :fn keyword"))
  `(if ,semaphore
       (concur:map-series
        ,items-form
        (lambda (item)
          (concur:chain (concur:semaphore-acquire ,semaphore)
            (:then (lambda (_) (funcall ,fn item)))
            (:finally (lambda () (concur:semaphore-release ,semaphore))))))
     (concur:map-series ,items-form ,fn)))

;;;###autoload
(defmacro concur:parallel! (items-form &key fn semaphore)
  "Process ITEMS in parallel with async function FN.
This macro applies `FN` to all `ITEMS` concurrently. Concurrency can be
limited by providing a `:semaphore`.

Arguments:
- `ITEMS-FORM` (form): An expression evaluating to the list of items.
- `:fn` (function): An async function that takes one item.
- `:semaphore` (concur-semaphore, optional): If provided, limits
  concurrency to the semaphore's size.

Returns:
  (concur-promise) A promise that resolves with a list of all results."
  (declare (indent 2) (debug t))
  (unless fn (error "concur:parallel! requires the :fn keyword"))
  `(if ,semaphore
       (concur:map-pool ,items-form ,fn
                        :size (concur-semaphore-max-count ,semaphore))
     (concur:map-parallel ,items-form ,fn)))

;;;###autoload
(cl-defun concur:map-pool (items fn &key (size 4) cancel-token)
  "Process ITEMS using async FN, with a concurrency limit of SIZE.
This function creates a pool of workers (limited to `SIZE` concurrent
tasks) to process the `ITEMS` list.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async function that takes one item and returns a promise.
- `:size` (integer, optional): The maximum number of concurrent tasks.
- `:cancel-token` (concur-cancel-token, optional): Cancels the operation.

Returns:
  (concur-promise) A promise for the list of all results."
  (concur:with-executor (lambda (resolve reject)
    (if (null items)
        (funcall resolve '())
      (let* ((total (length items))
             (results (make-vector total nil))
             (item-queue (copy-sequence items))
             (in-flight 0)
             (completed 0)
             (error-occurred nil))
        (cl-labels
            ((process-next ()
               (unless error-occurred
                 (while (and (< in-flight size) item-queue)
                   (let* ((item (pop item-queue))
                          (index (- total (length item-queue) 1)))
                     (cl-incf in-flight)
                     (concur:then
                      (concur:resolved! (funcall fn item))
                      (lambda (res)
                        (aset results index res)
                        (cl-decf in-flight)
                        (cl-incf completed)
                        (if (= completed total)
                            (funcall resolve (cl-coerce results 'list))
                          (process-next)))
                      (lambda (err)
                        (unless error-occurred
                          (setq error-occurred t)
                          (funcall reject err)))))))))
          (process-next)))))
    :cancel-token cancel-token))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Composition and Flow Control

;;;###autoload
(defmacro concur:let-promise (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises in parallel.
This is analogous to `let`. All promise forms in `BINDINGS` are executed
concurrently. The `BODY` is executed only after all of them have
successfully resolved, with variables bound to the resolved values.

Arguments:
- `BINDINGS` (list): A list of `(variable promise-form)` pairs.
- `BODY` (forms): The Lisp forms to execute after all promises resolve.

Returns:
  (concur-promise) A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let ((vars (--map #'car bindings))
          (forms (--map #'cadr bindings)))
      `(concur:then (concur:all (list ,@forms))
                    (lambda (results)
                      (cl-destructuring-bind ,vars results ,@body))))))

;;;###autoload
(defmacro concur:let-promise* (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises sequentially.
This is analogous to `let*`. Each promise-form in `BINDINGS` is
awaited before the next one begins.

Arguments:
- `BINDINGS` (list): A list of `(variable promise-form)` pairs.
- `BODY` (forms): The Lisp forms to execute after all promises resolve.

Returns:
  (concur-promise) A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      `(concur:then ,form
                    (lambda (,var)
                      (concur:let-promise* ,(cdr bindings) ,@body))))))

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple async operations; settle with the first to finish.
The returned promise will resolve or reject as soon as the first of
the input `FORMS` resolves or rejects.

Arguments:
- `FORMS` (list): Forms, each evaluating to a promise.
- `:semaphore` (concur-semaphore, optional): If provided, each task
  must acquire the semaphore before it can be considered in the race.

Returns:
  (concur-promise) A new promise."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (concur:race (if semaphore
                        (concur--apply-semaphore-wrapping awaitables semaphore)
                      awaitables)))))

;;;###autoload
(defmacro concur:any! (&rest forms)
  "Return promise resolving with first of FORMS to resolve successfully.
If all input forms reject, the returned promise will reject
with an aggregate error.

Arguments:
- `FORMS` (list): Forms, each evaluating to a promise.
- `:semaphore` (concur-semaphore, optional): If provided, each task
  must acquire the semaphore before it can be considered.

Returns:
  (concur-promise) A promise that resolves with the value of the
  first successfully resolved promise in `FORMS`."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let* ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (concur:any (if semaphore
                       (concur--apply-semaphore-wrapping awaitables semaphore)
                     awaitables)))))

;;;###autoload
(defmacro concur:unwind-protect! (body-form &rest cleanup-forms)
  "Execute BODY-FORM and guarantee CLEANUP-FORMS run afterward.
This is the asynchronous equivalent of `unwind-protect`. The `BODY-FORM`
should evaluate to a promise. The `CLEANUP-FORMS` are executed after
the promise settles, regardless of whether it resolved or rejected.

Arguments:
- `BODY-FORM` (form): A form that evaluates to a promise.
- `CLEANUP-FORMS` (forms): The forms to execute upon settlement.

Returns:
  (concur-promise) A new promise that settles with the same outcome
  as `BODY-FORM`'s promise, but only after `CLEANUP-FORMS` have run."
  (declare (indent 1) (debug t))
  `(concur:finally ,body-form (lambda () ,@cleanup-forms)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Dependency Graphs

;;;###autoload
(defmacro concur:lisp-graph! (let-block &rest body)
  "Define and execute a dependency graph of Lisp tasks.
This is a convenience wrapper around `concur:task-graph!` pre-configured
to execute all tasks as Lisp forms in the background worker pool.

Each node in the `:let` block has the form: `(NAME (FORM &key DEPENDS-ON))`
- `NAME`: A symbol to name the node.
- `FORM`: The Lisp form to evaluate. Resolved values of dependencies
  are available as variables inside this form.
- `DEPENDS-ON`: A symbol or list of symbols naming dependencies.

Arguments:
- `LET-BLOCK` (form): `(:let ((node-def-1) ...))` defining the graph.
- `BODY` (list): The final target node symbol, and optionally `:show t`.

Returns:
  (concur-promise) A promise that resolves with the value of the target node."
  (declare (indent 1) (debug t))
  (let* ((user-nodes (cadr let-block))
         (wrapped-nodes (--map `(,(car it) (:lisp ,@(cdr it))) user-nodes))
         (wrapped-let-block `(:let ,wrapped-nodes))
         (lisp-executor
          '(lambda (form dep-alist)
             (concur:async! `(let ,dep-alist ,form) :mode 'async))))
    `(concur:task-graph! ,wrapped-let-block
       :executors (:lisp ,lisp-executor)
       ,@body)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Advanced & Python-like Equivalents

;;;###autoload
(defmacro concur:batch! (batch-handler-form
                         &key (size 10) (timeout-ms 50))
  "Define a batchable async function from a BATCH-HANDLER-FORM.
This macro is a function factory. It returns a new function that you can
call multiple times. It will queue up the arguments from each call and
fire a single, batched request using `BATCH-HANDLER-FORM` either when
the queue size reaches `SIZE` or when `TIMEOUT-MS` has passed.

Arguments:
- `BATCH-HANDLER-FORM` (form): A `(lambda (list-of-items) ...)`
  that must return a promise resolving to a list of results.
- `:size` (integer): The maximum number of items to collect before flushing.
- `:timeout-ms` (number): Milliseconds to wait before flushing an incomplete batch.

Returns:
  (function) A new function that takes one item and returns a
  promise for that item's individual result."
  (declare (indent 1) (debug t))
  (let ((queue (gensym)) (timer (gensym)) (handler (gensym)))
    `(let ((,queue nil) (,timer nil) (,handler ,batch-handler-form))
       (flet ((flush-batch ()
                (when ,queue
                  (let* ((batch (nreverse ,queue))
                         (items (mapcar #'car batch))
                         (callbacks (mapcar #'cdr batch)))
                    (setq ,queue nil)
                    (when ,timer (cancel-timer ,timer) (setq ,timer nil))
                    (concur:then (funcall ,handler items)
                                 (lambda (results)
                                   (cl-loop for res in results
                                            for (res-cb _rej) in callbacks
                                            do (funcall res-cb res)))
                                 (lambda (err)
                                   (cl-loop for (_res rej-cb) in callbacks
                                            do (funcall rej-cb err))))))))
         (lambda (item)
           (concur:with-executor
               (lambda (resolve reject)
                 (push (cons item (list resolve reject)) ,queue)
                 (when ,timer (cancel-timer ,timer))
                 (setq ,timer (run-at-time (/ (float ,timeout-ms) 1000.0)
                                           nil #'flush-batch))
                 (when (>= (length ,queue) ,size) (flush-batch)))))))))

(defun concur--map-async-internal (form-template func iterable
                                   &rest keys &key mode chunksize)
  "Internal helper for map/starmap async variants."
  (let* ((mode (or mode 'async))
         (chunksize (or chunksize 10))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          collect (cl-subseq iterable i end)
                          while (< end (length iterable)))))
    (concur:all
     (cl-loop for chunk in chunks for id from 0
              collect
              (apply #'concur:start! nil :mode mode
                     :form (macroexpand
                            `(let ((func ',func) (chunk ',chunk))
                               ,form-template))
                     :name (format "map-async-chunk-%d" id)
                     keys)))))

;;;###autoload
(cl-defun concur:apply-async! (func args &rest keys)
  "Call FUNC with ARGS in a background process asynchronously.
Analogous to Python's `multiprocessing.Pool.apply_async`.

Arguments:
- `FUNC` (symbol): The function to call in the background process.
- `ARGS` (list): A list of arguments to apply to `FUNC`.
- `KEYS` (plist): Options for `concur:start!`, plus `:callback` and
  `:error-callback` for attaching handlers to the result promise.

Returns:
  (concur-promise) A promise for the result of `(apply FUNC ARGS)`."
  (let* ((call-form `(apply ',func ',args))
         (callback (plist-get keys :callback))
         (error-callback (plist-get keys :error-callback))
         (promise (apply #'concur:start! nil :mode 'async :form call-form keys)))
    (when callback (concur:then promise callback))
    (when error-callback (concur:catch promise error-callback))
    promise))

;;;###autoload
(cl-defun concur:map-async! (func iterable &rest keys)
  "Parallel equivalent of `map`, running operations in background processes.
Analogous to Python's `multiprocessing.Pool.map_async`. It splits
`ITERABLE` into chunks and processes each chunk in a background process.

Arguments:
- `FUNC` (symbol): The function to apply to each item of `ITERABLE`.
- `ITERABLE` (list): The list of items to process.
- `KEYS` (plist): Options, see `concur:apply-async!`.

Returns:
  (concur-promise) A promise that resolves to a list of all results."
  (let ((promise (apply #'concur--map-async-internal
                        `(--map (funcall func it) chunk)
                        func iterable keys))
        (callback (plist-get keys :callback))
        (error-callback (plist-get keys :error-callback)))
    (when callback
      (concur:then promise (lambda (res) (funcall callback (apply #'append res)))))
    (when error-callback (concur:catch promise error-callback))
    promise))

;;;###autoload
(cl-defun concur:starmap-async! (func iterable &rest keys)
  "Like `concur:map-async!` but unpacks iterable elements as arguments.
Analogous to Python's `multiprocessing.Pool.starmap_async`.

Arguments:
- `FUNC` (symbol): The function to call.
- `ITERABLE` (list of lists): Each inner list is a set of arguments for `FUNC`.
- `KEYS` (plist): Options, see `concur:map-async!`.

Returns:
  (concur-promise) A promise that resolves to a list of all results."
  (let ((promise (apply #'concur--map-async-internal
                        `(mapcar (lambda (args) (apply func args)) chunk)
                        func iterable keys))
        (callback (plist-get keys :callback))
        (error-callback (plist-get keys :error-callback)))
    (when callback
      (concur:then promise (lambda (res) (funcall callback (apply #'append res)))))
    (when error-callback (concur:catch promise error-callback))
    promise))

(provide 'concur-async)
;;; concur-async.el ends here