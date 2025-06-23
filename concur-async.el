;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-async.el --- High-level async primitives for Emacs -*- lexical-binding: t; -*-

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

(require 'cl-lib)           ; For cl-loop, cl-incf, cl-decf, cl-coerce, cl-destructuring-bind
(require 'async)            ; For native Emacs threads (`make-thread`)
(require 'coroutines)       ; For `concur:await` context (via `yield!`)

;; Core Concur modules
(require 'concur-core)      ; For `concur-promise` types, `concur:make-promise`,
                            ; `concur:resolved!`, `concur:rejected!`, `concur:resolve`,
                            ; `concur:reject`, `concur:status`, `concur:value`,
                            ; `concur:error-value`, `concur:error-message`,
                            ; `concur:with-executor`, `concur:await`, `concur--log`
(require 'concur-chain)     ; For `concur:then`, `concur:catch`, `concur:finally`
(require 'concur-lock)      ; For `concur-lock` (though direct usage is minimal here)
(require 'concur-future)    ; For `concur:future-sleep` (used implicitly by :sleep)
(require 'concur-pool)      ; For `concur:pool-submit-task` (:mode 'async)
(require 'concur-graph)     ; For `concur:lisp-graph!` (underlying engine)
(require 'concur-registry)  ; For `concur-register-promise`
(require 'concur-combinators) ; For `concur:all`, `concur:race`, `concur:any`,
                              ; `concur:map-series`, `concur:map-parallel`, `concur:delay`,
                              ; `concur:retry`
(require 'concur-semaphore) ; For `concur:semaphore-acquire`, `concur:semaphore-release`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customization, Hooks, & Errors

(defgroup concur-async nil
  "High-level asynchronous primitives for Concur."
  :group 'concur)

(define-error 'concur-async-error
  "A generic error during an asynchronous operation in Concur."
  'concur-error)
(define-error 'concur-async-invalid-mode
  "An invalid execution mode was specified for an asynchronous task."
  'concur-async-error)

(defcustom concur-async-default-execution-mode 'deferred
  "The default execution mode for `concur:async!` and `concur:start!`.
  This determines where tasks are run by default if `:mode` is not
  explicitly specified.
  Possible values:
  - `deferred`: Run on Emacs's idle timer.
  - `async`: Run in the persistent background Lisp worker pool (`concur-pool`).
  - `thread`: Run in a native Emacs thread."
  :type '(choice (const :tag "Deferred (Idle Timer)" deferred)
                 (const :tag "Async (Worker Pool)" async)
                 (const :tag "Thread (Native Thread)" thread))
  :group 'concur-async)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal State & Helpers

(defun concur--apply-semaphore-wrapping (tasks semaphore)
  "Wrap each promise in TASKS with semaphore acquisition and release.
This function creates a new promise chain for each task. The new chain
first acquires the `SEMAPHORE`, then executes the `TASK` (which must
be a promise), and finally releases the `SEMAPHORE` in a `concur:finally`
block, ensuring the semaphore is released even if the task fails.

  Arguments:
  - `TASKS` (list): A list of `concur-promise` objects.
  - `SEMAPHORE` (concur-semaphore): The semaphore to use for concurrency control.

  Returns:
  - (list): A list of new `concur-promise` objects, each wrapped with
    semaphore logic."
  (concur--log :debug nil "Applying semaphore wrapping to %d tasks with %S."
               (length tasks) (concur-semaphore-name semaphore))
  (--map
   (lambda (task)
     (concur:chain (concur:semaphore-acquire semaphore)
       (:then (lambda (_) task)) ; Execute task after acquiring semaphore
       (:finally (lambda () (concur:semaphore-release semaphore)))))
   tasks))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Execution Strategy Helpers

(defun concur--async-create-task-wrapper (fn)
  "Create a wrapper lambda for a task `FN` to handle its lifecycle.
This wrapper executes the nullary function `FN` and calls `resolve-fn`
with its result on success, or `reject-fn` on error.

  Arguments:
  - `FN` (function): The nullary function (`lambda () ...`) to wrap.

  Returns:
  - (lambda): A `(lambda (resolve-fn reject-fn) ...)` function suitable
    for `concur:with-executor`."
  (lambda (resolve-fn reject-fn)
    (condition-case err
        (funcall resolve-fn (funcall fn))
      (error
       (concur--log :error nil "Synchronous task wrapper failed: %S." err)
       (funcall reject-fn err)))))

(defun concur--async-run-in-deferred (task-wrapper cancel-token)
  "Execute a task in 'deferred' mode using Emacs's idle timer (`run-at-time 0`).
This function uses `concur:with-executor` to create a promise for the task,
and then schedules the `TASK-WRAPPER` to run in the next available Emacs
idle cycle.

  Arguments:
  - `TASK-WRAPPER` (function): The `(lambda (resolve reject) ...)` function
    that performs the actual task execution.
  - `CANCEL-TOKEN` (concur-cancel-token, optional): The cancellation token
    linked to the task's promise.

  Returns:
  - (concur-promise): A promise that will settle with the task's result."
  (concur--log :debug nil "Running task in :deferred mode.")
  (concur:with-executor
      (lambda (resolve reject)
        (run-at-time 0 nil (lambda () (funcall task-wrapper resolve reject))))
    :cancel-token cancel-token))

(defun concur--async-run-in-thread (fn cancel-token)
  "Execute a task `FN` in 'thread' mode using a native Emacs thread.
This spawns a new Emacs thread to run `FN`. The result is communicated
back to the main thread via a mailbox, which is polled using a short
`run-at-time` timer.

  Arguments:
  - `FN` (function): The nullary function to execute in the background thread.
  - `CANCEL-TOKEN` (concur-cancel-token, optional): The cancellation token
    linked to the task's promise.

  Returns:
  - (concur-promise): A promise that will settle with the result of `FN`.

  Note: The polling mechanism is a simple way to get results from a background
  thread to the main thread without complex inter-thread messaging. For very
  high-frequency updates or low-latency needs, a more sophisticated pipe-based
  mechanism might be considered, but this provides a functional bridge."
  (concur--log :debug nil "Running task in :thread mode.")
  (concur:with-executor (lambda (resolve reject)
    (let ((mailbox (list nil)) ; Simple shared mailbox for result
          timer)
      (make-thread
       (lambda ()
         (condition-case err
             (setcar mailbox (cons :success (funcall fn)))
           (error (setcar mailbox (cons :failure err)))))
       "concur-thread")
      ;; Polling timer to check mailbox from main thread.
      (setq timer
            (run-at-time
             0.01 0.01 ; Poll every 10ms
             (lambda ()
               (when-let ((result (car mailbox)))
                 (concur--log :debug nil "Thread task result received from mailbox: %S."
                              result)
                 (cancel-timer timer)
                 (pcase result
                   (`(:success . ,val) (funcall resolve val))
                   (`(:failure . ,err) (funcall reject err)))))))))
    :cancel-token cancel-token
    :mode :thread)) ; Set promise mode to :thread for proper locking

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Main Task Execution

;;;###autoload
(cl-defun concur:start! (fn &key mode name cancel-token
                             require form timeout priority)
  "Run FN asynchronously according to MODE and return a `concur-promise`.
This is the core functional primitive for running asynchronous tasks.

  Arguments:
  - `FN` (function or nil): The nullary function to execute asynchronously.
    Can be `nil` if `:form` is provided (specifically for `'async` mode
    which evaluates the form directly in a worker process).
  - `:mode` (symbol, optional): The execution mode for the task:
    - `'deferred` (default): Execute on an Emacs idle timer.
    - `'async`: Execute in the persistent background Lisp worker pool
      (`concur-pool.el`). Requires `:form` to be provided.
    - `'thread`: Execute in a native Emacs thread.
    If `nil`, `concur-async-default-execution-mode` is used.
  - `:name` (string, optional): A descriptive name for the task for debugging.
  - `:cancel-token` (concur-cancel-token, optional): For cancellation.
  - `:require` (list, optional): A list of features for the worker to `require`.
    Options specifically for the `'async` (worker pool) mode.
  - `:form` (any, optional): The Lisp form to be evaluated by the worker.
    Required for `'async` mode when `FN` is `nil`.
  - `:priority` (integer, optional): Task priority for `concur-pool` (lower
    integer is higher priority). Options for `'async` mode.
  - `:timeout` (number, optional): Optional timeout in seconds for the task.
    Options for `'async` mode.

  Returns:
  - (concur-promise): A promise that will settle with the result of `FN`
    or `FORM`."
  (let* ((actual-mode (or mode concur-async-default-execution-mode)) 
         (promise-mode (if (memq actual-mode '(async thread)) actual-mode :deferred))
         (promise (concur:make-promise :cancel-token cancel-token
                                       :mode promise-mode
                                       :name name)))

    ;; Register the promise with the global registry for introspection.
    (when (fboundp 'concur-registry-register-promise)
      (concur-registry-register-promise promise name))

    (concur--log :info (concur-promise-id promise)
                 "Starting async task '%S' in mode %S." (or name fn) actual-mode)

    (pcase actual-mode
      ('deferred
       (concur--async-run-in-deferred
        (concur--async-create-task-wrapper fn) cancel-token))
      ('async
       (unless (fboundp 'concur-pool-get-default)
         (user-error "concur:start!: `concur-pool` not loaded for :async mode."))
       (unless form
         (user-error "concur:start!: :form is required for :async mode."))
       (concur:pool-submit-task (concur-pool-get-default) promise form
                                (or require nil)
                                :priority (or priority 50)
                                :timeout timeout))
      ('thread
       (unless (fboundp 'make-thread)
         (user-error "concur:start!: Emacs does not support native threads."))
       (unless fn
         (user-error "concur:start!: FN must be a function for :thread mode."))
       (concur--async-run-in-thread fn cancel-token))
      (_ (concur:reject promise
                        (concur:make-error :type 'concur-async-invalid-mode
                                           :message (format "Unknown mode: %S"
                                                            actual-mode)))))
    promise))

;;;###autoload
(defmacro concur:async! (task-form &rest keys)
  "Run TASK-FORM asynchronously and return a promise.
This is a convenient macro wrapper around the core `concur:start!` function.
It automatically wraps `TASK-FORM` in a lambda for `deferred` or `thread`
modes, or passes the raw form for `async` mode (for `concur-pool`).

  Arguments:
  - `TASK-FORM` (form): The Lisp form to execute asynchronously.
  - `KEYS` (plist): Options to pass to `concur:start!`, such as
    `:mode`, `:name`, `:cancel-token`, `:require`, `:priority`, `:timeout`.

  Returns:
  - (concur-promise): A promise that will settle with the result of `TASK-FORM`."
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
The `TASK-FORM` is wrapped in a lambda and executed in the next available
Emacs idle cycle.

  Arguments:
  - `TASK-FORM` (form): The Lisp form to execute.
  - `KEYS` (plist): Options like `:name` and `:cancel-token`.

  Returns:
  - (concur-promise): A promise for the result of `TASK-FORM`."
  (declare (indent 1) (debug t))
  `(concur:async! ,task-form :mode 'deferred ,@keys))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Iteration and Mapping

;;;###autoload
(defmacro concur:sequence! (items-form &key fn semaphore)
  "Process ITEMS sequentially with async function FN.
Each call to `FN` begins only after the promise from the previous call has resolved.
This ensures strict ordering and controlled resource usage. If a `SEMAPHORE`
is provided, it's acquired before each `FN` call and released afterward.

  Arguments:
  - `ITEMS-FORM` (form): An expression that evaluates to the list of items.
  - `:fn` (function): A function that takes one item and returns a promise.
  - `:semaphore` (concur-semaphore, optional): A semaphore to acquire
    before processing each item. This limits the \"active\" tasks, even in a
    sequential chain where the next task only starts after the previous one
    finishes.

  Returns:
  - (concur-promise): A promise that resolves with a list of all results."
  (declare (indent 2) (debug t))
  (unless fn (user-error "concur:sequence! requires the :fn keyword"))
  (unless (functionp fn)
    (user-error "concur:sequence!: FN must be a function: %S" fn))
  (when semaphore
    (unless (fboundp 'concur:semaphore-acquire)
      (user-error "concur:sequence!: :semaphore requires `concur-semaphore`.")))

  `(concur--log :info nil "Starting sequential processing of %S items."
                (length ,items-form))
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
limited by providing a `:semaphore` or implicitly by `concur:map-pool`.

  Arguments:
  - `ITEMS-FORM` (form): An expression evaluating to the list of items.
  - `:fn` (function): An async function that takes one item.
  - `:semaphore` (concur-semaphore, optional): If provided, limits
    concurrency to the semaphore's size by wrapping each `FN` call.

  Returns:
  - (concur-promise): A promise that resolves with a list of all results."
  (declare (indent 2) (debug t))
  (unless fn (user-error "concur:parallel! requires the :fn keyword"))
  (unless (functionp fn)
    (user-error "concur:parallel!: FN must be a function: %S" fn))
  (when semaphore
    (unless (fboundp 'concur:semaphore-acquire)
      (user-error "concur:parallel!: :semaphore requires `concur-semaphore`.")))

  `(concur--log :info nil "Starting parallel processing of %S items."
                (length ,items-form))
  `(if ,semaphore
       (concur:map-pool ,items-form ,fn
                        :size (concur-semaphore-max-count ,semaphore))
     (concur:map-parallel ,items-form ,fn)))

;;;###autoload
(cl-defun concur:map-pool (items fn &key (size 4) cancel-token)
  "Process ITEMS using async FN, with a concurrency limit of SIZE.
This function creates a pool of workers (limited to `SIZE` concurrent
tasks) to process the `ITEMS` list. Tasks are submitted to a concurrent
\"pool\" (managed internally by this function, not `concur-pool.el`)
and their results collected.

  Arguments:
  - `ITEMS` (list): The list of items to process.
  - `FN` (function): An async function that takes one item and returns a promise.
  - `:size` (integer, optional): The maximum number of concurrent tasks.
    Defaults to 4. Must be at least 1.
  - `:cancel-token` (concur-cancel-token, optional): A token to cancel
    the entire mapping operation prematurely.

  Returns:
  - (concur-promise): A promise for the list of all results."
  (unless (listp items)
    (user-error "concur:map-pool: ITEMS must be a list: %S" items))
  (unless (functionp fn)
    (user-error "concur:map-pool: FN must be a function: %S" fn))
  (unless (and (integerp size) (>= size 1))
    (user-error "concur:map-pool: :size must be a positive integer: %S" size))

  (concur--log :info nil "Mapping %d items with concurrency limit %d."
               (length items) size)

  (concur:with-executor 
    (lambda (resolve reject)
      (if (null items)
          (funcall resolve '()) ; Resolve with empty list for no items
        (let* ((total (length items))
              (results (make-vector total nil)) ; Pre-allocate for results
              (item-queue (copy-sequence items)) ; Use a queue for items
              (in-flight 0) ; Counter for currently running tasks
              (completed 0) ; Counter for completed tasks
              (error-occurred nil)) ; Flag to stop processing on first error

          (when cancel-token ; Setup cancellation for the whole map-pool
            (unless (fboundp 'concur:cancel-token-add-callback)
              (user-error "concur:map-pool: :cancel-token requires `concur-cancel`."))
            (concur:cancel-token-add-callback
            cancel-token
            (lambda ()
              (unless error-occurred
                (setq error-occurred t)
                (funcall reject (concur:make-error :type :cancelled
                                                    :message "Map-pool cancelled")))))))

          ;; Recursive helper to process next available tasks
          (cl-labels
              ((process-next ()
                (when (and (not error-occurred) ; Continue only if no error
                            (< completed total)) ; And not all tasks are done
                  ;; Fill up concurrency slots
                  (while (and (< in-flight size) ; Slots available
                              item-queue) ; And items remaining
                    (let* ((item (pop item-queue))
                            (index (- total (length item-queue) 1))) ; Original index
                      (cl-incf in-flight)
                      (concur--log :debug nil "Map-pool: Starting task for item %S (in-flight: %d)."
                                    item in-flight)
                      ;; Execute FN for the item, chain its outcome
                      (concur:then
                        (funcall fn item)
                        (lambda (res)
                          (concur--log :debug nil "Map-pool: Task for item %S completed (in-flight: %d)."
                                      item in-flight)
                          (aset results index res) ; Store result at original index
                          (cl-decf in-flight)
                          (cl-incf completed)
                          (if (= completed total)
                              (progn ; All tasks done, resolve.
                                (concur--log :info nil "Map-pool: All %d tasks completed." total)
                                (funcall resolve (cl-coerce results 'list)))
                            (process-next))) ; Schedule next batch if more tasks
                        (lambda (err) ; Task failed
                          (unless error-occurred
                            (setq error-occurred t) ; Mark error occurred
                            (concur--log :error nil "Map-pool: Task for item %S failed. Error: %S."
                                        item err)
                            (funcall reject err)))))))))
            (process-next)))))) ; Initial call to start processing

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Composition and Flow Control

;;;###autoload
(defmacro concur:let-promise (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises in parallel.
This macro is analogous to `let`. All promise forms in `BINDINGS` are executed
concurrently. The `BODY` is executed only after all of them have
successfully resolved, with variables bound to the resolved values.

  Arguments:
  - `BINDINGS` (list): A list of `(variable promise-form)` pairs.
  - `BODY` (forms): The Lisp forms to execute after all promises resolve.

  Returns:
  - (concur-promise): A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (unless (listp bindings)
    (user-error "concur:let-promise: BINDINGS must be a list of (VAR PROMISE-FORM) pairs: %S"
                bindings))
  (if (null bindings)
      `(concur:resolved! (progn ,@body)) ; No bindings, resolve immediately
    (let ((vars (--map #'car bindings))
          (forms (--map #'cadr bindings)))
      `(concur--log :debug nil "concur:let-promise: Resolving %d promises in parallel."
                    (length vars))
      `(concur:then (concur:all (list ,@forms)) ; Wait for all promises
                    (lambda (results)
                      (concur--log :debug nil "concur:let-promise: All promises resolved, executing body.")
                      ;; Destructure resolved values into variables
                      (cl-destructuring-bind ,vars results ,@body))))))

;;;###autoload
(defmacro concur:let-promise* (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises sequentially.
This macro is analogous to `let*`. Each promise-form in `BINDINGS` is
awaited before the next one begins.

  Arguments:
  - `BINDINGS` (list): A list of `(variable promise-form)` pairs.
  - `BODY` (forms): The Lisp forms to execute after all promises resolve.

  Returns:
  - (concur-promise): A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (unless (listp bindings)
    (user-error "concur:let-promise*: BINDINGS must be a list of (VAR PROMISE-FORM) pairs: %S"
                bindings))
  (if (null bindings)
      `(concur:resolved! (progn ,@body)) ; No bindings, resolve immediately
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      `(concur--log :debug nil "concur:let-promise*: Resolving promise for %S sequentially."
                    ',var)
      `(concur:then ,form ; Wait for current promise
                    (lambda (,var)
                      (concur--log :debug nil "concur:let-promise*: Promise for %S resolved, continuing."
                                   ',var)
                      (concur:let-promise* ,(cdr bindings) ,@body)))))) ; Recursively call for next binding

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple async operations; settle with the first to finish.
The returned promise will resolve or reject as soon as the first of
the input `FORMS` resolves or rejects. Concurrency can be optionally
limited by a semaphore.

  Arguments:
  - `FORMS` (list): Forms, each evaluating to a promise.
  - `:semaphore` (concur-semaphore, optional): If provided, each task
    must acquire the semaphore before it can be considered in the race.

  Returns:
  - (concur-promise): A new promise."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    (concur--log :info nil "concur:race!: Racing %d tasks (semaphore: %S)."
                 (length task-forms) sem-form)
    `(let ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (concur:race (if semaphore
                        (concur--apply-semaphore-wrapping awaitables semaphore)
                      awaitables)))))

;;;###autoload
(defmacro concur:any! (&rest forms)
  "Return promise resolving with first of FORMS to resolve successfully.
If all input forms reject, the returned promise will reject
with an `concur-error` of type `:aggregate-error`. Concurrency can be
optionally limited by a semaphore.

  Arguments:
  - `FORMS` (list): Forms, each evaluating to a promise.
  - `:semaphore` (concur-semaphore, optional): If provided, each task
    must acquire the semaphore before it can be considered.

  Returns:
  - (concur-promise): A promise that resolves with the value of the
    first successfully resolved promise in `FORMS`."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    (concur--log :info nil "concur:any!: Waiting for first success among %d tasks (semaphore: %S)."
                 (length task-forms) sem-form)
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
  - (concur-promise): A new promise that settles with the same outcome
    as `BODY-FORM`'s promise, but only after `CLEANUP-FORMS` have run."
  (declare (indent 1) (debug t))
  `(concur--log :debug nil "concur:unwind-protect!: Wrapping body with cleanup.")
  `(concur:finally ,body-form (lambda () ,@cleanup-forms)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Dependency Graphs

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
  - `BODY` (list): The rest of the forms, including:
    - The final target node symbol whose result is desired.
    - Optionally `:show t` to visualize the graph.

  Returns:
  - (concur-promise): A promise that resolves with the value of the target node."
  (declare (indent 1) (debug t))
  (unless (listp let-block)
    (user-error "concur:lisp-graph!: LET-BLOCK must be a list: %S" let-block))
  (let* ((user-nodes (cadr let-block))
         (wrapped-nodes (--map `(,(car it) (:lisp ,@(cdr it))) user-nodes))
         (wrapped-let-block `(:let ,wrapped-nodes))
         (lisp-executor
          '(lambda (form dep-alist)
             (concur--log :debug nil "Lisp graph executor: executing form %S." form)
             (concur:async! `(let ,dep-alist ,form) :mode 'async))))
    (concur--log :info nil "concur:lisp-graph!: Setting up Lisp task graph.")
    `(concur:task-graph! ,wrapped-let-block
       :executors (:lisp ,lisp-executor)
       ,@body)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Advanced & Python-like Equivalents

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
    that must return a promise resolving to a list of results. The results
    list must correspond one-to-one with the input `list-of-items`.
  - `:size` (integer, optional): The maximum number of items to collect
    before flushing. Defaults to 10. Must be a positive integer.
  - `:timeout-ms` (number, optional): Milliseconds to wait before flushing
    an incomplete batch. Defaults to 50ms. Must be a non-negative number.

  Returns:
  - (function): A new function that takes one item and returns a
    promise for that item's individual result."
  (declare (indent 1) (debug t))
  (unless (and (integerp size) (> size 0))
    (user-error "concur:batch!: :size must be a positive integer: %S" size))
  (unless (and (numberp timeout-ms) (>= timeout-ms 0))
    (user-error "concur:batch!: :timeout-ms must be a non-negative number: %S"
                timeout-ms))

  (let ((queue (gensym "batch-queue-"))
        (timer (gensym "batch-timer-"))
        (handler (gensym "batch-handler-"))
        (resolver (gensym "batch-resolver-"))
        (rejector (gensym "batch-rejector-")))
    `(let ((,queue nil) ; Stores `(item . (resolve . reject))` pairs
           (,timer nil)
           (,handler ,batch-handler-form))
       (concur--log :info nil "concur:batch!: Creating batcher function (size: %d, timeout: %dms)."
                    ,size ,timeout-ms)
       (flet ((flush-batch ()
                (when ,queue
                  (let* ((batch (nreverse ,queue)) ; Preserve original order
                         (items (--map #'car batch)) ; Extract items
                         (callbacks (--map #'cdr batch))) ; Extract (resolve . reject) pairs
                    (setq ,queue nil) ; Clear queue
                    (when ,timer (cancel-timer ,timer) (setq ,timer nil)) ; Clear timer
                    (concur--log :debug nil "concur:batch!: Flushing batch of %d items."
                                 (length items))
                    (concur:then (funcall ,handler items) ; Call user's batch handler
                                 (lambda (results)
                                   (concur--log :debug nil "concur:batch!: Batch handler resolved with %d results."
                                                (length results))
                                   (unless (= (length results) (length items))
                                     (concur--log :error nil "concur:batch!: Batch handler returned %d results for %d items. Mismatched."
                                                  (length results) (length items)))
                                   (cl-loop for res in results
                                            for (,resolver ,_rejector) in callbacks
                                            do (funcall ,resolver res)))
                                 (lambda (err)
                                   (concur--log :error nil "concur:batch!: Batch handler rejected: %S" err)
                                   (cl-loop for (,_resolver ,rejector) in callbacks
                                            do (funcall ,rejector err))))))))
         (lambda (item)
           (concur:with-executor
               (lambda (,resolver ,rejector)
                 (concur--log :debug nil "concur:batch!: Item %S received. Current queue length: %d."
                              item (length ,queue))
                 ;; Add item and its resolve/reject functions to the queue
                 (push (cons item (list ,resolver ,rejector)) ,queue)
                 (when ,timer (cancel-timer ,timer)) ; Reset existing timer
                 ;; Start new timeout timer
                 (setq ,timer (run-at-time (/ (float ,timeout-ms) 1000.0)
                                           nil #'flush-batch))
                 ;; Flush if queue size reaches limit
                 (when (>= (length ,queue) ,size) (flush-batch)))))))))

(defun concur--map-async-internal (form-template func iterable
                                   &rest keys &key mode chunksize)
  "Internal helper for map/starmap async variants.
This function splits the `ITERABLE` into `CHUNKSIZE`'d chunks and submits
each chunk for parallel processing using `concur:start!`.

  Arguments:
  - `FORM-TEMPLATE` (form): The template Lisp form to evaluate in the worker.
    It typically uses `func` and `chunk`.
  - `FUNC` (symbol): The function to be applied (passed to worker).
  - `ITERABLE` (list): The list of items to process.
  - `KEYS` (plist): Additional options for `concur:start!`.
  - `:mode` (symbol): Execution mode for `concur:start!`.
  - `:chunksize` (integer): Number of items per chunk.

  Returns:
  - (concur-promise): A promise that resolves to a list of lists (chunks' results)."
  (let* ((mode (or mode 'async))
         (chunksize (or chunksize 10))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          when (> end i) ; Only collect non-empty chunks
                          collect (cl-subseq iterable i end)
                          while (< end (length iterable)))))
    (concur--log :debug nil "concur--map-async-internal: Splitting %d items into %d chunks (size %d)."
                 (length iterable) (length chunks) chunksize)
    (concur:all
     (cl-loop for chunk in chunks for id from 0
              collect
              (concur--log :debug nil "concur--map-async-internal: Submitting chunk %d (size %d) for mode %S."
                           id (length chunk) mode)
              (apply #'concur:start! nil :mode mode
                     :form (macroexpand
                            `(let ((func ',func) (chunk ',chunk))
                               ,form-template))
                     :name (format "map-async-chunk-%d" id)
                     keys)))))

;;;###autoload
(cl-defun concur:apply-async! (func args &rest keys)
  "Call FUNC with ARGS in a background process asynchronously.
Analogous to Python's `multiprocessing.Pool.apply_async`. The function
runs in `async` mode (worker pool) by default.

  Arguments:
  - `FUNC` (symbol): The function to call in the background process.
  - `ARGS` (list): A list of arguments to apply to `FUNC`.
  - `KEYS` (plist): Options for `concur:start!`, plus `:callback` and
    `:error-callback` for attaching handlers to the result promise.

  Returns:
  - (concur-promise): A promise for the result of `(apply FUNC ARGS)`."
  (unless (functionp func)
    (user-error "concur:apply-async!: FUNC must be a function: %S" func))
  (concur--log :info nil "concur:apply-async!: Submitting %S with args %S."
               func args)
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
The function runs in `async` mode (worker pool) by default.

  Arguments:
  - `FUNC` (symbol): The function to apply to each item of `ITERABLE`.
  - `ITERABLE` (list): The list of items to process.
  - `KEYS` (plist): Options for `concur:start!`, plus `:callback` and
    `:error-callback`.

  Returns:
  - (concur-promise): A promise that resolves to a list of all results."
  (unless (functionp func)
    (user-error "concur:map-async!: FUNC must be a function: %S" func))
  (unless (listp iterable)
    (user-error "concur:map-async!: ITERABLE must be a list: %S" iterable))
  (concur--log :info nil "concur:map-async!: Mapping %d items with %S."
               (length iterable) func)
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
Each sub-list in `ITERABLE` is unpacked as arguments to `FUNC`.
The function runs in `async` mode (worker pool) by default.

  Arguments:
  - `FUNC` (symbol): The function to call.
  - `ITERABLE` (list of lists): Each inner list is a set of arguments for `FUNC`.
  - `KEYS` (plist): Options for `concur:start!`, plus `:callback` and
    `:error-callback`.

  Returns:
  - (concur-promise): A promise that resolves to a list of all results."
  (unless (functionp func)
    (user-error "concur:starmap-async!: FUNC must be a function: %S" func))
  (unless (listp iterable)
    (user-error "concur:starmap-async!: ITERABLE must be a list: %S" iterable))
  (concur--log :info nil "concur:starmap-async!: Mapping %d arg-lists with %S."
               (length iterable) func)
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