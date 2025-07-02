;;; concur-flow.el --- High-Level Asynchronous Flow Control -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a suite of high-level asynchronous primitives that
;; build upon the foundational `concur-promise` system. It aims to make
;; complex asynchronous workflows easy to write and reason about.
;;
;; Core Features:
;; - `concur:start`: A powerful "router" function for running tasks in
;;   different execution contexts (deferred, threads, or worker pool).
;; - `concur:let` & `concur:let*`: Ergonomic, promise-aware versions of `let`.
;; - `concur:if`: A promise-aware conditional macro.
;; - `concur:batch!`: A function factory for batching multiple operations
;;   into a single asynchronous call (Dataloader pattern).

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lisp)
(require 'concur-graph)
(require 'concur-combinators)
(require 'concur-semaphore)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-flow-error "Generic error in high-level async op." 'concur-error)
(define-error 'concur-flow-invalid-mode "Invalid execution mode specified." 'concur-flow-error)

(defcustom concur-flow-default-execution-mode 'deferred
  "The default execution mode for `concur:start`.
This determines where tasks run if `:mode` is not specified.
- `deferred`: Run on Emacs's idle timer (main thread).
- `async`: Run in the persistent background worker pool.
- `thread`: Run in a native Emacs thread."
  :type '(choice (const :tag "Deferred (Idle Timer)" deferred)
                 (const :tag "Async (Worker Pool)" async)
                 (const :tag "Thread (Native Thread)" thread))
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--flow-run-in-thread (fn promise)
  "Execute task `FN` in a native Emacs thread.
This uses the efficient pipe-based signaling mechanism from `concur-core.el`
to communicate the result back to the main thread without polling.

Arguments:
- `FN` (function): The nullary function to execute in the thread.
- `PROMISE` (concur-promise): The promise to settle with the result."
  (make-thread
   (lambda ()
     (condition-case err
         (concur:resolve promise (funcall fn))
       (error (concur:reject promise err))))
   (format "concur-thread-%S" (concur-promise-id promise))))

(defun concur--flow-apply-semaphore-wrapping (tasks semaphore)
  "Wrap each promise in `TASKS` with semaphore acquisition and release.

Arguments:
- `TASKS` (list): A list of promises.
- `SEMAPHORE` (concur-semaphore): The semaphore to use.

Returns:
- `(list)`: A new list of wrapped promises."
  (mapcar
   (lambda (task)
     (concur:chain (concur:semaphore-acquire semaphore)
       (:then (lambda (_) task))
       (:finally (lambda () (concur:semaphore-release semaphore)))))
   tasks))

(defun concur--flow-map-async-internal (form-template func iterable &rest keys)
  "Internal helper for map/starmap async variants."
  (let* ((mode (or (plist-get keys :mode) 'async))
         (chunksize (or (plist-get keys :chunksize) 10))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          when (> end i) collect (cl-subseq iterable i end)
                          while (< end (length iterable)))))
    (concur:all
     (cl-loop for chunk in chunks
              collect
              (apply #'concur:start nil :mode mode
                     :form `(let ((func ',func) (chunk ',chunk))
                              ,form-template)
                     (cl-copy-list keys))))))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Core Task Execution

;;;###autoload
(cl-defun concur:start (fn &key (mode concur-flow-default-execution-mode)
                              name cancel-token vars priority)
  "Run `FN` asynchronously according to `MODE` and return a `concur-promise`.
This is the core functional primitive for running async tasks. It acts
as a router, dispatching work to the appropriate backend.

Arguments:
- `FN` (function): The nullary function `(lambda () ...)` to execute.
- `:MODE` (symbol, optional): The execution mode for the task.
  - `'deferred`: Execute on an Emacs idle timer.
  - `'async`: Execute in the persistent worker pool (`concur-pool.el`).
  - `'thread`: Execute in a native Emacs thread.
- `:NAME` (string, optional): A descriptive name for the task.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): For cancellation.
- `:VARS` (alist, optional): `let`-bindings for the worker (`:async` mode).
- `:PRIORITY` (integer, optional): Task priority (`:async` mode).

Returns:
- `(concur-promise)`: A promise that will settle with the result of `FN`."
  (unless (functionp fn) (error "FN must be a function: %S" fn))
  (let ((promise (concur:make-promise :name name :cancel-token cancel-token
                                      :mode mode)))
    (concur--log :info (concur-promise-id promise)
                 "Starting task '%S' in mode %S." (or name "unnamed") mode)
    (pcase mode
      ('deferred
       (concur:with-executor (resolve reject)
         (run-at-time 0 nil (lambda ()
                              (condition-case err (funcall resolve (funcall fn))
                                (error (funcall reject err)))))))
      ('async
       (unless (fboundp 'concur:lisp-submit-task)
         (error "`concur-lisp` not loaded for :async mode."))
       (concur:chain (concur:lisp-submit-task (concur--lisp-pool-get-default)
                                              `(funcall ,fn)
                                              :vars vars
                                              :priority (or priority 50))
                     (:then (lambda (res) (concur:resolve promise res)))
                     (:catch (lambda (err) (concur:reject promise err)))))
      ('thread
       (unless (fboundp 'make-thread)
         (error "This Emacs does not support native threads."))
       (concur--flow-run-in-thread fn promise))
      (_ (concur:reject promise
                        (concur:make-error
                         :type 'concur-flow-invalid-mode
                         :message (format "Unknown mode: %S" mode)))))
    promise))

;;;###autoload
(defmacro concur:async! (task-form &rest keys)
  "Run `TASK-FORM` asynchronously and return a promise.
This is a convenient macro wrapper for `concur:start`.

Arguments:
- `TASK-FORM` (form): The Lisp form to execute asynchronously.
- `KEYS` (plist): Options for `concur:start`, such as `:mode`, `:name`.

Returns:
- `(concur-promise)`: A promise for the result of `TASK-FORM`."
  (declare (indent 1) (debug t))
  `(apply #'concur:start (lambda () ,task-form) (list ,@keys)))

;;;###autoload
(defmacro concur:deferred! (task-form &rest keys)
  "Run `TASK-FORM` asynchronously on an idle timer.
A shorthand for `(concur:async! task-form :mode 'deferred ...)`.

Arguments:
- `TASK-FORM` (form): The Lisp form to execute.
- `KEYS` (plist): Options like `:name` and `:cancel-token`.

Returns:
- (concur-promise): A promise for the result of `TASK-FORM`."
  (declare (indent 1) (debug t))
  `(concur:async! ,task-form :mode 'deferred ,@keys))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Iteration and Mapping

;;;###autoload
(defun concur:sequence! (items fn)
  "Process `ITEMS` sequentially with async function `FN`.
Each call to `FN` begins only after the promise from the previous
call has resolved.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): A function that takes one item and returns a promise.

Returns:
- `(concur-promise)`: A promise that resolves with a list of all results."
  (concur:map-series items fn))

;;;###autoload
(cl-defun concur:parallel! (items fn &key (concurrency 8))
  "Process `ITEMS` in parallel with async function `FN`.
Applies `FN` to `ITEMS` concurrently, with the number of parallel
operations limited by `:concurrency`.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async function that takes one item and returns a promise.
- `:CONCURRENCY` (integer): The maximum number of tasks to run at once.

Returns:
- `(concur-promise)`: A promise that resolves with a list of all results."
  (concur:map-parallel items fn :concurrency concurrency))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise-Aware Conditionals and Bindings

;;;###autoload
(defmacro concur:if (condition-promise then-form &optional else-form)
  "Run `THEN-FORM` or `ELSE-FORM` based on the result of `CONDITION-PROMISE`.
This is the asynchronous equivalent of `if`. It waits for `CONDITION-PROMISE`
to resolve, and if the result is non-nil, evaluates `THEN-FORM`;
otherwise it evaluates `ELSE-FORM`.

Arguments:
- `CONDITION-PROMISE` (form): A form evaluating to a promise for a boolean.
- `THEN-FORM` (form): The form to execute if the condition is true.
- `ELSE-FORM` (form, optional): The form to execute if the condition is false.

Returns:
- `(concur-promise)`: A promise for the result of the executed form."
  (declare (indent 2) (debug t))
  `(concur:then ,condition-promise
                (lambda (result)
                  (if result ,then-form ,else-form))))

;;;###autoload
(defmacro concur:let (bindings &rest body)
  "Execute `BODY` with `BINDINGS` resolved from promises in parallel.
This is the asynchronous equivalent of `let`. All promise forms in
`BINDINGS` are executed concurrently. The `BODY` is executed only
after all of them have successfully resolved.

Arguments:
- `BINDINGS` (list): A list of `(variable promise-form)` pairs.
- `BODY` (forms): The Lisp forms to execute.

Returns:
- `(concur-promise)`: A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (unless (listp bindings) (error "BINDINGS must be a list: %S" bindings))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let ((vars (mapcar #'car bindings))
          (forms (mapcar #'cadr bindings)))
      `(concur:then (concur:all (list ,@forms))
                    (lambda (results)
                      (cl-destructuring-bind ,vars results ,@body))))))

;;;###autoload
(defmacro concur:let* (bindings &rest body)
  "Execute `BODY` with `BINDINGS` resolved from promises sequentially.
This is the asynchronous equivalent of `let*`. Each promise-form in
`BINDINGS` is awaited before the next one begins, and its result is
available to subsequent binding forms.

Arguments:
- `BINDINGS` (list): A list of `(variable promise-form)` pairs.
- `BODY` (forms): The Lisp forms to execute.

Returns:
- `(concur-promise)`: A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (unless (listp bindings) (error "BINDINGS must be a list: %S" bindings))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      `(concur:then ,form
                    (lambda (,var)
                      (concur:let* ,(cdr bindings) ,@body))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Advanced Flow Control

;;;###autoload
(defmacro concur:all! (&rest forms)
  "Wait for all async operations in FORMS to resolve successfully.

If any operation rejects, the returned promise will immediately
reject with that error. Otherwise, it resolves with a list of
the results from all operations, in their original order.

Arguments:
- `FORMS` (list): Forms, each evaluating to a promise.
- `:SEMAPHORE` (concur-semaphore, optional): If provided, each task must
  acquire the semaphore before it can start.

Returns:
- `(concur-promise)`: A promise that resolves with a list of results."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (concur:all (if semaphore
                       (concur--flow-apply-semaphore-wrapping awaitables semaphore)
                     awaitables)))))

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple async operations; settle with the first to finish.

Arguments:
- `FORMS` (list): Forms, each evaluating to a promise.
- `:SEMAPHORE` (concur-semaphore, optional): If provided, each task must
  acquire the semaphore before it can be considered in the race.

Returns:
- `(concur-promise)`: A new promise."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (concur:race (if semaphore
                        (concur--flow-apply-semaphore-wrapping awaitables semaphore)
                      awaitables)))))

;;;###autoload
(defmacro concur:any! (&rest forms)
  "Return promise resolving with first of FORMS to resolve successfully.

If all input forms reject, the returned promise will reject.

Arguments:
- `FORMS` (list): Forms, each evaluating to a promise.
- `:semaphore` (concur-semaphore, optional): If provided, each task
  must acquire the semaphore before it can be considered.

Returns:
- (concur-promise): A promise for the value of the first successful promise."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let* ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (concur:any (if semaphore
                       (concur--flow-apply-semaphore-wrapping awaitables semaphore)
                     awaitables)))))

;;;###autoload
(defmacro concur:select! (&rest clauses)
  "Race multiple operations and execute a body for the first one that completes.
Waits for the first promise in any `CLAUSES` to resolve, then executes
the corresponding body. All other operations are immediately cancelled.

Each clause must be of the form: `((VAR PROMISE-FORM) &rest BODY)`.

Arguments:
- `CLAUSES` (rest): A list of clauses to race against each other.

Returns:
- `(concur-promise)`: A promise for the result of the winning clause's body."
  (declare (indent 0) (debug t))
  (let ((master-promise (gensym "master-promise-"))
        (cancel-token (gensym "cancel-token-"))
        (has-won (gensym "has-won-"))
        (lock (gensym "select-lock-")))
    `(let ((,master-promise (concur:make-promise))
           (,cancel-token (concur:make-cancel-token))
           (,has-won nil)
           (,lock (concur:make-lock "select-lock")))
       ,@(mapcar
          (lambda (clause)
            (let* ((binding (car clause)) (var (car binding)) (form (cadr binding))
                   (body (cdr clause)) (child-promise (gensym "child-promise-")))
              `(let ((,child-promise (concur:async! ,form :cancel-token ,cancel-token)))
                 (concur:then
                  ,child-promise
                  (lambda (,var)
                    (let (winner-p)
                      (concur:with-mutex! ,lock
                        (unless ,has-won (setq ,has-won t winner-p t)))
                      (when winner-p
                        (concur:cancel-token-cancel ,cancel-token)
                        (concur:chain (progn ,@body)
                          (:then (lambda (res) (concur:resolve ,master-promise res)))
                          (:catch (lambda (err) (concur:reject ,master-promise err)))))))
                  (lambda (err)
                    (let (winner-p)
                      (concur:with-mutex! ,lock
                        (unless ,has-won (setq ,has-won t winner-p t)))
                      (when winner-p
                        (concur:cancel-token-cancel ,cancel-token)
                        (concur:reject ,master-promise err))))))))
          clauses)
       ,master-promise)))

;;;###autoload
(defmacro concur:unwind-protect! (body-form &rest cleanup-forms)
  "Execute `BODY-FORM` and guarantee `CLEANUP-FORMS` run afterward.
This is the asynchronous equivalent of `unwind-protect`.

Arguments:
- `BODY-FORM` (form): A form that evaluates to a promise.
- `CLEANUP-FORMS` (forms): The forms to execute upon settlement.

Returns:
- `(concur-promise)`: A new promise that settles with the same outcome as
  `BODY-FORM`'s promise, but only after `CLEANUP-FORMS` have run."
  (declare (indent 1) (debug t))
  `(concur:finally ,body-form (lambda () ,@cleanup-forms)))

;;;###autoload
(defmacro concur:batch! (batch-handler-form &key (size 10) (timeout-ms 50))
  "Create a function that batches multiple calls into a single async request.
This macro is a function factory (an implementation of the Dataloader
pattern). It returns a new function that you can call many times. It
will queue items and fire a single, batched request using
`BATCH-HANDLER-FORM` when the queue size reaches `SIZE` or when
`TIMEOUT-MS` has passed.

Arguments:
- `BATCH-HANDLER-FORM` (form): A `(lambda (list-of-items) ...)` that must
  return a promise resolving to a list of results, one for each input item.
- `:SIZE` (integer, optional): Max number of items to collect before flushing.
- `:TIMEOUT-MS` (number, optional): Milliseconds to wait before flushing.

Returns:
- (function): A new function that takes one item and returns a promise for
  that item's individual result."
  (declare (indent 1) (debug t))
  (let ((queue (gensym "batch-queue-"))
        (timer (gensym "batch-timer-"))
        (handler (gensym "batch-handler-")))
    `(let ((,queue nil) (,timer nil) (,handler ,batch-handler-form))
       (flet ((flush-batch ()
                (when ,queue
                  (let* ((batch (nreverse ,queue))
                         (items (mapcar #'car batch))
                         (promises (mapcar #'cdr batch)))
                    (setq ,queue nil)
                    (when ,timer (cancel-timer timer) (setq ,timer nil))
                    (concur:then (funcall ,handler items)
                                 (lambda (results)
                                   (cl-loop for res in results
                                            for p in promises
                                            do (concur:resolve p res)))
                                 (lambda (err)
                                   (cl-loop for p in promises
                                            do (concur:reject p err))))))))
         (lambda (item)
           (let ((p (concur:make-promise)))
             (push (cons item p) ,queue)
             (when ,timer (cancel-timer timer))
             (setq timer (run-at-time (/ (float ,timeout-ms) 1000.0)
                                       nil #'flush-batch))
             (when (>= (length ,queue) ,size) (flush-batch))
             p))))))

;;;###autoload
(cl-defun concur:apply-async! (func args &rest keys)
  "Call FUNC with ARGS in a background process asynchronously.

Analogous to Python's `multiprocessing.Pool.apply_async`. Runs in the
worker pool (`:mode 'async`) by default.

Arguments:
- `FUNC` (symbol): The function to call in the background process.
- `ARGS` (list): A list of arguments to apply to `FUNC`.
- `KEYS` (plist): Options for `concur:start`, plus `:callback` and
  `:error-callback` for attaching handlers to the result promise.

Returns:
- (concur-promise): A promise for the result of `(apply FUNC ARGS)`."
  (let* ((call-form `(apply ',func ',args))
         (callback (plist-get keys :callback))
         (error-callback (plist-get keys :error-callback))
         (promise (apply #'concur:start nil :mode 'async :form call-form keys)))
    (when callback (concur:then promise callback))
    (when error-callback (concur:catch promise error-callback))
    promise))

;;;###autoload
(cl-defun concur:map-async! (func iterable &rest keys)
  "Parallel equivalent of `map`, running operations in background processes.

Analogous to Python's `multiprocessing.Pool.map_async`. Splits
`ITERABLE` into chunks and processes them in the worker pool.

Arguments:
- `FUNC` (symbol): The function to apply to each item of `ITERABLE`.
- `ITERABLE` (list): The list of items to process.
- `KEYS` (plist): Options for `concur:start`, plus `:callback` and
  `:error-callback`.

Returns:
- (concur-promise): A promise that resolves to a list of all results."
  (let ((promise (apply #'concur--flow-map-async-internal
                        `(--map (funcall func it) chunk)
                        func iterable keys))
        (callback (plist-get keys :callback))
        (error-callback (plist-get keys :error-callback)))
    (concur:then
     promise
     (lambda (res)
       (let ((final-res (apply #'append res)))
         (when callback (funcall callback final-res))
         final-res))
     error-callback)))

;;;###autoload
(cl-defun concur:starmap-async! (func iterable &rest keys)
  "Like `concur:map-async!` but unpacks iterable elements as arguments.

Analogous to Python's `multiprocessing.Pool.starmap_async`.
Each sub-list in `ITERABLE` is unpacked as arguments to `FUNC`.

Arguments:
- `FUNC` (symbol): The function to call.
- `ITERABLE` (list of lists): Each inner list is a set of arguments for `FUNC`.
- `KEYS` (plist): Options for `concur:start`, plus `:callback` and
  `:error-callback`.

Returns:
- (concur-promise): A promise that resolves to a list of all results."
  (let ((promise (apply #'concur--flow-map-async-internal
                        `(mapcar (lambda (args) (apply func args)) chunk)
                        func iterable keys))
        (callback (plist-get keys :callback))
        (error-callback (plist-get keys :error-callback)))
    (concur:then
     promise
     (lambda (res)
       (let ((final-res (apply #'append res)))
         (when callback (funcall callback final-res))
         final-res))
     error-callback)))

(provide 'concur-flow)
;;; concur-flow.el ends here

