;;; concur-core.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;; This file defines the `concur-promise` data structure and the core operations
;; for creating, resolving, and rejecting promises. It lies at the heart of the
;; Concur library, implementing the state machine, callback scheduling, and
;; thread-safety primitives.
;;
;; Architectural Highlights:
;; - Promise/A+ Compliant Scheduling: Separates macrotasks (idle timer) and
;;   microtasks (immediate) for predictable execution order.
;; - AST-based Lexical Context Capture: To ensure callbacks work reliably
;;   when byte-compiled, handler functions are analyzed to capture their
;;   lexical environment. This context is then restored before execution.
;; - Thread-Safety and Concurrency Modes: `concur-lock` protects state;
;;   `mode` (`:deferred`, `:thread`, `:async`) determines lock type.
;; - Extensibility: `concur-normalize-awaitable-hook` integrates external
;;   awaitable objects.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 's)

(require 'concur-hooks)
(require 'concur-cancel)
(require 'concur-lock)
(require 'concur-ast)
(require 'concur-scheduler)
(require 'concur-microtask)
(require 'concur-registry)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations and Constants

(declare-function concur:finally "concur-chain" (promise callback-form))

(defvar yield--await-external-status-key nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization & Errors

(defgroup concur nil "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defcustom concur-log-value-max-length 100
  "Maximum length of a value/error string in log messages before truncation."
  :type 'integer
  :group 'concur)

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, signal a `concur-unhandled-rejection` error.
When a promise is rejected and has no rejection handlers
attached, this controls whether to ignore it or signal an error."
  :type 'boolean
  :group 'concur)

(defcustom concur-await-poll-interval 0.01
  "The polling interval (in seconds) for cooperative `concur:await` blocking."
  :type 'float
  :group 'concur)

(defcustom concur-await-default-timeout 10.0
  "Default timeout (in seconds) for `concur:await` if not specified.
If `nil`, `concur:await` will wait indefinitely by default."
  :type '(choice (float :min 0.0) (const :tag "Indefinite" nil))
  :group 'concur)

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
Used to build richer debugging information for `concur-error` objects.")

;; Define standard error types used by the library
(define-error 'concur-error "A generic error in the Concur library.")
(define-error 'concur-unhandled-rejection
  "A promise was rejected with no handler." 'concur-error)
(define-error 'concur-await-error
  "An error occurred while awaiting a promise." 'concur-error)
(define-error 'concur-cancel-error
  "A promise was cancelled." 'concur-error)
(define-error 'concur-timeout-error
  "An operation timed out." 'concur-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(cl-defstruct (concur-promise (:constructor %%make-promise))
  "Represents an asynchronous operation that can resolve or reject.
This is the central data structure of the library. Do not
manipulate its fields directly; use the `concur:*` functions.

Fields:
- `id` (symbol): A unique identifier (gensym) for logging and debugging.
- `result` (any): The value the promise resolved with.
- `error` (any): The reason the promise was rejected (typically a `concur-error`).
- `state` (symbol): The current state: `:pending`, `:resolved`, or `:rejected`.
- `callbacks` (list): List of `concur-callback-link` structs waiting to run.
- `cancel-token` (concur-cancel-token): Optional token for cancellation.
- `cancelled-p` (boolean): `t` if rejection was due to cancellation.
- `proc` (process): Optional external process to kill on cancellation.
- `lock` (concur-lock): A mutex protecting all fields from concurrent access.
- `mode` (symbol): Concurrency mode (`:deferred`, `:thread`, `:async`)."
  (id nil :type symbol)
  (result nil)
  (error nil)
  (state :pending :type (member :pending :resolved :rejected))
  (callbacks '() :type list)
  (cancel-token nil :type (or null concur-cancel-token))
  (cancelled-p nil :type boolean)
  (proc nil)
  (lock nil :type (or null concur-lock))
  (mode :deferred :type (member :deferred :thread :async)))

(cl-defstruct (concur-await-latch (:constructor %%make-await-latch))
  "Internal latch for the `concur:await` mechanism.
This acts as a shared flag between a waiting `await` call and the
promise callback that signals completion.

Fields:
- `signaled-p` (boolean or `timeout`): The flag indicating completion.
- `cond-var` (condition-variable): Condition variable for `:thread` mode waits."
  (signaled-p nil :type (or boolean (eql timeout)))
  (cond-var nil))

(cl-defstruct (concur-callback (:constructor %%make-callback))
  "An internal struct that wraps a callback function and its context.

Fields:
- `type` (symbol): The handler type, e.g., `:resolved`, `:rejected`, `:finally`.
- `fn` (function): The actual user-defined callback function.
- `promise` (concur-promise): The next promise in a chain to be settled.
- `context` (form): A form that `eval`s to the captured lexical context.
- `priority` (integer): Scheduling priority for macrotasks."
  (type nil :type symbol)
  (fn nil :type function)
  (promise nil :type (or null concur-promise))
  (context nil)
  (priority 50 :type integer))

(cl-defstruct (concur-callback-link (:constructor %%make-callback-link))
  "Represents one link in a promise chain, grouping callbacks.
A single call to `concur:then` can attach both a resolve and a
reject handler. This struct groups them for coherent processing.

Fields:
- `id` (symbol): A unique ID for debugging.
- `callbacks` (list): A list of `concur-callback` structs."
  (id nil :type symbol)
  (callbacks '() :type list))

(cl-defstruct (concur-error (:constructor %%make-concur-error))
  "A standardized error object for promise rejections.
Provides a consistent structure for error handling and introspection.

Fields:
- `type` (keyword): Keyword identifying the error (`:cancel`, `:timeout`, etc.).
- `message` (string): A human-readable error message.
- `cause` (any): The original error or reason that caused this error.
- `promise` (concur-promise): The promise that rejected (optional).
- `async-stack-trace` (string): The async call stack at time of rejection."
  (type :generic :type keyword)
  (message "An unspecific Concur error occurred." :type string)
  (cause nil)
  (promise nil :type (or null concur-promise))
  (async-stack-trace nil :type (or null string)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State and Schedulers

(defvar concur--macrotask-scheduler
  (concur-scheduler-create
   :name "concur-macrotask-scheduler"
   :comparator (lambda (cb1 cb2)
                 (< (concur-callback-priority cb1)
                    (concur-callback-priority cb2)))
   :process-fn #'concur--process-macrotask-batch-internal)
  "The global scheduler instance for macrotasks (deferred promise callbacks).")

(defun concur--schedule-macrotasks (callbacks-list)
  "Add a list of callbacks to the macrotask scheduler.
Ensures callbacks run asynchronously, preventing the 'Zalgo problem'."
  (--each callbacks-list
          (concur-scheduler-enqueue concur--macrotask-scheduler it)))

(defun concur--process-macrotask-batch-internal (scheduler)
  "Execute a batch of callbacks from the macrotask scheduler.
This function implements the 'Lock-Pop-Unlock-Execute' pattern to
ensure thread-safety and prevent deadlocks. It is the default
`process-fn` for the macrotask scheduler.

Arguments:
- `SCHEDULER` (concur-scheduler): The scheduler instance."
  (let (batch)
    ;; STEP 1 & 2: Lock the scheduler and Pop a batch of tasks.
    (concur:with-mutex! (concur-scheduler-lock scheduler)
      (setq batch (concur-scheduler-pop-batch scheduler)))

    ;; STEP 3 & 4: (Unlock happens automatically) Execute the batch.
    ;; This is done *outside* the mutex to prevent deadlocks if a callback
    ;; tries to enqueue another task on this same scheduler.
    (when batch
      (--each batch #'concur--execute-callback)
      ;; After a macrotask runs, the microtask queue must be drained.
      (concur-microtask-queue-drain))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Promise Lifecycle

(defun concur--settle-promise (promise result error is-cancellation)
  "The core internal function to settle a promise (resolve or reject).
This function is idempotent and thread-safe."
  (let ((settled-now nil))
    (concur:with-mutex! (concur-promise-lock promise)
      (when (eq (concur-promise-state promise) :pending)
        (let ((new-state (if error :rejected :resolved)))
          (setf (concur-promise-result promise) result)
          (setf (concur-promise-error promise) error)
          (setf (concur-promise-cancelled-p promise) is-cancellation)
          (setf (concur-promise-state promise) new-state)
          (setq settled-now t)
          (concur--trigger-callbacks-after-settle promise)
          (concur--kill-associated-process-if-cancelled promise))))
    (when settled-now
      (concur-registry-update-promise-state promise)))
  promise)

(defun concur--kill-associated-process-if-cancelled (promise)
  "If PROMISE was cancelled and has a process, kill it."
  (when (concur-promise-cancelled-p promise)
    (when-let ((proc (concur-promise-proc promise)))
      (when (process-live-p proc)
        (delete-process proc))
      (setf (concur-promise-proc promise) nil))))

(defun concur--trigger-callbacks-after-settle (promise)
  "Called once a promise settles to schedule its callbacks."
  (let ((callback-links (concur-promise-callbacks promise)))
    (setf (concur-promise-callbacks promise) nil)
    (concur--partition-and-schedule-callbacks callback-links)
    (concur--handle-unhandled-rejection-if-any promise callback-links)))

(defun concur--partition-and-schedule-callbacks (callback-links)
  "Partitions callbacks into microtasks and macrotasks, then schedules them."
  (let* ((all-callbacks (-flatten (--map (concur-callback-link-callbacks it)
                                         callback-links)))
         (microtasks (-filter (lambda (cb) (eq (concur-callback-type cb)
                                               :await-latch))
                                all-callbacks))
         (macrotasks (-filter (lambda (cb) (not (eq (concur-callback-type cb)
                                                    :await-latch)))
                                all-callbacks)))
    (when microtasks (concur-microtask-queue-add microtasks))
    (when macrotasks (concur--schedule-macrotasks macrotasks))))

(defun concur--handle-unhandled-rejection-if-any (promise callback-links)
  "If PROMISE was rejected with no handlers, signals an unhandled rejection."
  (when (and (eq (concur-promise-state promise) :rejected)
             (not (-some (lambda (cb) (eq (concur-callback-type cb) :rejected))
                         (-flatten (--map #'concur-callback-link-callbacks
                                          callback-links)))))
    (let ((error-obj (concur:make-error
                      :type :unhandled-rejection
                      :message (format "Unhandled promise rejection: %s"
                                       (concur-format-value-or-error
                                        (concur-promise-error promise)))
                      :cause (concur-promise-error promise) :promise promise)))
      (run-hook-with-args 'concur-unhandled-rejection-hook promise error-obj)
      (when concur-throw-on-promise-rejection
        (signal 'concur-unhandled-rejection
                (list (concur:error-message error-obj) error-obj))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Callback and Context Management

(defun concur--merge-contexts (existing-context captured-vars-alist)
  "Merge an existing context with captured variables into a new hash table."
  (let ((merged-ht (make-hash-table :test 'eq)))
    (cond ((hash-table-p existing-context)
           (maphash (lambda (k v) (puthash k v merged-ht)) existing-context))
          ((listp existing-context) ; alist
           (--each existing-context (puthash (car it) (cdr it) merged-ht))))
    (when (listp captured-vars-alist)
      (--each captured-vars-alist (puthash (car it) (cdr it) merged-ht)))
    merged-ht))

(defun concur--execute-callback (callback)
  "Executes a single callback, handling context evaluation and errors.
This function restores the lexical environment of the callback by `let`-binding
the variables captured by the AST analysis. This is critical for robustness,
especially with byte-compilation."
  (let* ((target-promise (concur-callback-promise callback))
         (handler (concur-callback-fn callback))
         (type (concur-callback-type callback))
         (context-alist (eval (concur-callback-context callback)))
         (origin-promise (gethash 'origin-promise context-alist))
         (input-value (if (eq type :rejected)
                          (concur-promise-error origin-promise)
                        (concur-promise-result origin-promise))))
    (condition-case err
        (let ,(mapcar (lambda (p) `(,(car p) ,(cdr p))) context-alist)
          (pcase type
            ((or :resolved :rejected :tap)
             (concur-chain-or-settle-promise
              target-promise (funcall handler input-value)))
            (:finally
             (concur-chain-or-settle-promise
              target-promise (funcall handler input-value))
             (if (concur-promise-error origin-promise)
                 (concur:reject target-promise (concur-promise-error origin-promise))
               (concur:resolve target-promise (concur-promise-result origin-promise))))
            (:await-latch (funcall handler input-value))))
      (error (concur:reject target-promise
                            (concur:make-error
                             :type :callback-error
                             :message (format "Callback failed: %S" err)
                             :cause err))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: `await` Implementation and Other Utilities

(defun concur--await-blocking-cooperative (latch promise timer)
  "Implements cooperative blocking for `await` using `sit-for`."
  (when-let (timeout-val (and timer (timer--initial-delay timer)))
    (setf (timer--function timer)
          (lambda ()
            (when (not (concur-await-latch-signaled-p latch))
              (setf (concur-await-latch-signaled-p latch) 'timeout))))
    (add-timer timer))
  (while (not (concur-await-latch-signaled-p latch))
    (sit-for concur-await-poll-interval)))

(defun concur--await-blocking-thread (latch promise timer)
  "Implements true thread blocking for `await` using a condition variable."
  (let* ((lock (concur-promise-lock promise))
         (cond-var (make-condition-variable (concur-lock-mutex lock))))
    (setf (concur-await-latch-cond-var latch) cond-var)
    (when timer (add-timer timer))
    (concur:with-mutex! lock
      (while (not (concur-await-latch-signaled-p latch))
        (condition-wait cond-var)))))

(defun concur--await-latch-signaler-callback ()
  "The callback function that signals an await latch upon promise settlement."
  (lambda (_value-or-error context-ht)
    (let* ((latch (gethash 'latch context-ht))
           (promise (gethash 'target-promise context-ht)))
      (when (not (eq (concur-await-latch-signaled-p latch) 'timeout))
        (setf (concur-await-latch-signaled-p latch) t)
        (when-let (cond-var (concur-await-latch-cond-var latch))
          (concur:with-mutex! (concur-promise-lock promise)
            (condition-notify cond-var)))))))

(defun concur--await-blocking (promise timeout)
  "Central dispatcher for `await`. Blocks cooperatively or via thread
based on the promise's `mode`."
  (if (not (eq (concur:status promise) :pending))
      (if-let ((err (concur:error-value promise)))
          (signal 'concur-await-error (list (concur:error-message err) err))
        (concur:value promise))

    (let ((latch (%%make-await-latch))
          (timer (and timeout (make-timer #'ignore))))
      (unwind-protect
          (progn
            (concur-attach-callbacks
             promise
             (%%make-callback
              :type :await-latch
              :fn (concur--await-latch-signaler-callback)
              :promise promise
              :context `',(let ((ht (make-hash-table)))
                            (puthash 'latch latch ht)
                            (puthash 'target-promise promise ht)
                            ht)))
            (if (eq (concur-promise-mode promise) :thread)
                (concur--await-blocking-thread latch promise timer)
              (concur--await-blocking-cooperative latch promise timer))

            (if (eq (concur-await-latch-signaled-p latch) 'timeout)
                (signal 'concur-timeout-error
                        (list (format "Await timed out for %s"
                                      (concur:format-promise promise))))
              (if-let ((err (concur:error-value promise)))
                  (signal 'concur-await-error
                          (list (concur:error-message err) err))
                (concur:value promise))))
        (when timer (cancel-timer timer))))))

(defun concur-current-async-stack-string ()
  "Format `concur--current-async-stack` into a readable string."
  (when concur--current-async-stack
    (mapconcat #'identity (reverse concur--current-async-stack) "\n↳ ")))

(defun concur-determine-strongest-mode (promises-list &optional default-mode)
  "Determine the strongest concurrency mode among a list of promises.
A stronger mode implies a more thread-safe underlying mutex. This is
important for maintaining thread-safety across promise chains.
Order of strength: `:async` > `:thread` > `:deferred`.
Plain values are treated as if they yield a `:deferred` promise.

Arguments:
- `promises-list`: A list of `concur-promise` objects or plain values.
- `default-mode`: The mode to return if `promises-list` is empty or
  contains only plain values. Defaults to `:deferred`.

Returns:
  (symbol) The strongest mode found (one of `:async`, `:thread`, `:deferred`)."
  (cl-loop with strongest-found = (or default-mode :deferred)
           for p in promises-list
           do (let* ((promise (if (concur-promise-p p) p
                                (concur:resolved! p :mode :deferred)))
                     (p-mode (concur-promise-mode promise)))
                (cond
                 ;; If we find :async, it's the strongest. Return immediately.
                 ((eq p-mode :async) (cl-return :async))
                 ;; If :thread, it's strongest unless we already found :async.
                 ((eq p-mode :thread)
                  (unless (eq strongest-found :async)
                    (setq strongest-found :thread)))))
           ;; If the loop completes, return the strongest mode found.
           finally (return strongest-found)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Construction and State Transition

;;;###autoload
(cl-defun concur:make-promise (&key (mode :deferred) name cancel-token)
  "Create a new, pending `concur-promise`.
This is the main entry point for creating a promise that you will
manually resolve or reject later.

Arguments:
- `:MODE` (symbol, optional): Concurrency mode (`:deferred`, `:thread`, `:async`).
  `:deferred` (default): Safe for main thread, non-blocking ops.
  `:thread`: Safe for use across multiple Emacs threads.
- `:NAME` (string, optional): A descriptive name for debugging and registry.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): Token to link for cancellation.

Returns:
  (concur-promise) A new promise in the `:pending` state."
  (let* ((p (%%make-promise
             :id (gensym "promise-")
             :mode mode
             :lock (concur:make-lock (format "p-lock-%s" (make-symbol ""))
                                     :mode mode)
             :cancel-token cancel-token)))
    (concur-registry-register-promise p name)
    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token (lambda () (concur:cancel p))))
    p))

;;;###autoload
(defun concur:resolve (promise result)
  "Resolve a PROMISE with a given RESULT.
If RESULT is another promise, the original PROMISE will adopt its
state (a process known as chaining), per the Promises/A+ spec.
This operation is idempotent; it has no effect if the promise is not pending.

Arguments:
- `PROMISE` (concur-promise): The promise to resolve.
- `RESULT` (any): The value to resolve the promise with.

Returns:
  (concur-promise) The original `PROMISE`."
  (concur-chain-or-settle-promise promise result))

(defun concur-chain-or-settle-promise (promise value)
  "The internal implementation of the Promises/A+ resolution procedure."
  (let ((normalized-value (if (concur-promise-p value) value
                            (run-hook-with-args-until-success
                             'concur-normalize-awaitable-hook value value))))
    (cond
     ((eq promise normalized-value)
      (concur--settle-promise
       promise nil
       (concur:make-error :type :type-error
                          :message "A promise cannot be resolved with itself.")
       nil))
     ((concur-promise-p normalized-value)
      (concur:then normalized-value
                   (lambda (res) (concur-chain-or-settle-promise promise res))
                   (lambda (err) (concur:reject promise err))))
     (t (concur--settle-promise promise value nil nil))))
  promise)

;;;###autoload
(defun concur:reject (promise error)
  "Reject a PROMISE with a given ERROR.
This operation is idempotent. The provided `error` is standardized
into a `concur-error` struct for consistent handling.

Arguments:
- `PROMISE` (concur-promise): The promise to reject.
- `ERROR` (any): The reason for the rejection.

Returns:
  (concur-promise) The original `PROMISE`."
  (let* ((is-cancellation (and (concur-error-p error)
                               (eq (concur-error-type error) :cancel)))
         (final-error (if (concur-error-p error) error
                        (concur:make-error
                         :type (if is-cancellation :cancel :generic)
                         :message (format "%s" error)
                         :cause error
                         :promise promise))))
    (when (and concur--current-async-stack
               (not (concur-error-async-stack-trace final-error)))
      (setf (concur-error-async-stack-trace final-error)
            (concur-current-async-stack-string)))
    (concur--settle-promise promise nil final-error is-cancellation)))

;;;###autoload
(cl-defun concur:resolved! (value &key (mode :deferred))
  "Create and return a new promise that is already resolved with VALUE.

Arguments:
- `VALUE` (any): The value to resolve the new promise with.
- `:MODE` (symbol, optional): Concurrency mode for the promise.

Returns:
  (concur-promise) A new promise in the `:resolved` state."
  (let ((p (concur:make-promise :mode mode)))
    (concur:resolve p value)
    p))

;;;###autoload
(cl-defun concur:rejected! (error &key (mode :deferred))
  "Create and return a new promise that is already rejected with ERROR.

Arguments:
- `ERROR` (any): The error to reject the new promise with.
- `:MODE` (symbol, optional): Concurrency mode for the promise.

Returns:
  (concur-promise) A new promise in the `:rejected` state."
  (let ((p (concur:make-promise :mode mode)))
    (concur:reject p error)
    p))

;;;###autoload
(defun concur:cancel (promise &optional reason)
  "Cancel a pending PROMISE.
This rejects the promise with a cancellation error. If the promise has an
associated external process, it will also be killed.

Arguments:
- `PROMISE` (concur-promise): The promise to cancel.
- `REASON` (string, optional): A descriptive reason for the cancellation.

Returns:
  (concur-promise) The original `PROMISE`."
  (when (eq (concur:status promise) :pending)
    (concur:reject
     promise
     (concur:make-error :type :cancel
                        :message (or reason "Promise cancelled")))))

;;;###autoload
(cl-defun concur:make-error (&rest args &key type message cause promise)
  "Create a new `concur-error` struct.
A convenient way to create standardized error objects for rejections.

Arguments:
- `ARGS` (plist): Keyword arguments matching the `concur-error` struct fields.

Returns:
  (concur-error) A new error struct."
  (apply #'%%make-concur-error
         :async-stack-trace (concur-current-async-stack-string)
         args))

;;;###autoload
(cl-defmacro concur:with-executor (executor-fn-form &rest opts &key mode &environment env)
  "Define and execute an async block that controls a new promise.
This is a primary entry point for creating promises from imperative
code. It robustly captures the lexical environment of the executor
lambda to ensure it works correctly when byte-compiled.

Arguments:
- `EXECUTOR-FN-FORM` (lambda): A lambda of `(lambda (resolve reject) ...)`.
- `OPTS` (plist): Options, including:
  - `:MODE` (symbol, optional): The concurrency mode for the new promise.
  - `:CANCEL-TOKEN` (concur-cancel-token, optional): Token for cancellation.

Returns:
  (concur-promise) A new promise controlled by the executor."
  (declare (indent 1) (debug t))
  (let* ((promise-sym (gensym "promise-"))
         (analysis (concur-ast-analysis executor-fn-form env))
         (callable (concur-ast-analysis-result-expanded-callable-form analysis))
         (context-form (concur-ast-make-captured-vars-form
                        (concur-ast-analysis-result-free-vars-list analysis))))
    `(let ((,promise-sym (concur:make-promise ,@opts)))
       (condition-case err
           (let ((context ,context-form))
             (let ,(mapcar (lambda (v) `(,v (gethash ',v context)))
                           (concur-ast-analysis-result-free-vars-list analysis))
               (funcall ,callable
                        (lambda (value) (concur:resolve ,promise-sym value))
                        (lambda (error) (concur:reject ,promise-sym error)))))
         (error (concur:reject
                 ,promise-sym
                 (concur:make-error :type :executor-error
                                    :message (format "Executor failed: %S" err)
                                    :cause err))))
       ,promise-sym)))

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
Its behavior depends on the context:
1.  **Inside a `concur:async` coroutine:** It yields control to the scheduler.
2.  **Outside a coroutine:** It blocks based on the promise's `mode`.
    - `:deferred`: Blocks Emacs cooperatively (UI remains responsive).
    - `:thread`: Blocks the current thread using a condition variable.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
- `TIMEOUT` (number, optional): Seconds to wait before signaling a
  `concur:timeout-error`. Uses `concur-await-default-timeout` if omitted.

Returns:
  (any) The resolved value of the promise. Signals an error if
  the promise is rejected or times out."
  (declare (indent 1) (debug t))
  `(let ((p ,promise-form))
     (if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
         (if (eq (concur:status p) :pending)
             (yield--internal-throw-form p ',yield--await-external-status-key)
           (if-let ((err (concur:error-value p)))
               (signal 'concur-await-error (list (concur:error-message err) err))
             (concur:value p)))
       (concur--await-blocking p (or ,timeout concur-await-default-timeout)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Introspection

(defun concur-format-value-or-error (value)
  "Formats a value or error for concise logging, truncating if necessary."
  (let* ((max-len concur-log-value-max-length)
         (str (cond ((concur-error-p value)
                     (format "[%s] %s" (upcase (symbol-name
                                                (concur-error-type value)))
                             (concur-error-message value)))
                    ((stringp value) value)
                    (t (format "%S" value)))))
    (if (> (length str) max-len)
        (concat (substring str 0 max-len) "...")
      str)))

;;;###autoload
(defun concur:status (promise)
  "Return current state of a PROMISE (`:pending`, `:resolved`, `:rejected`)."
  (concur-promise-state promise))

;;;###autoload
(defun concur:pending-p (promise)
  "Return non-nil if PROMISE is pending."
  (eq (concur:status promise) :pending))

;;;###autoload
(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has resolved successfully."
  (eq (concur:status promise) :resolved))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE was rejected."
  (eq (concur:status promise) :rejected))

;;;###autoload
(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE was cancelled."
  (concur-promise-cancelled-p promise))

;;;###autoload
(defun concur:value (promise)
  "Return resolved value of PROMISE, or nil if not resolved. Non-blocking."
  (when (eq (concur:status promise) :resolved)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return error of PROMISE if rejected, else nil. Non-blocking."
  (when (eq (concur:status promise) :rejected)
    (concur-promise-error promise)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return human-readable message from a promise's error or an error object."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (if (concur-error-p err) (concur-error-message err)
      (format "%s" err))))

;;;###autoload
(defun concur:format-promise (p)
  "Return human-readable string representation of a promise."
  (if (not (concur-promise-p p)) (format "%S" p)
    (let* ((id (concur-promise-id p))
           (mode (concur-promise-mode p))
           (status (concur:status p))
           (name (concur-registry-get-promise-name p (symbol-name id))))
      (pcase status
        (:pending (format "#<Promise %s (%s) %s: pending>" name id mode))
        (:resolved (format "#<Promise %s (%s) %s: resolved with %s>" name id mode
                           (concur-format-value-or-error (concur:value p))))
        (:rejected (format "#<Promise %s (%s) %s: rejected with %s>" name id mode
                           (concur-format-value-or-error (concur:error-value p))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Low-Level Primitives for Library Authors (e.g., for concur-chain.el)

(defun concur-attach-callbacks (promise &rest callbacks)
  "Attach a set of callbacks to a PROMISE. Low-level primitive.
If the promise is already settled, it schedules the callbacks for
asynchronous execution immediately. If pending, it adds callbacks
to the promise's list to run later."
  (let* ((non-nil-callbacks (-filter #'identity callbacks))
         (link (%%make-callback-link
                :id (gensym "link-")
                :callbacks non-nil-callbacks)))
    (concur:with-mutex! (concur-promise-lock promise)
      (if (eq (concur-promise-state promise) :pending)
          (push link (concur-promise-callbacks promise))
        (concur--partition-and-schedule-callbacks (list link))))))

(cl-defun concur-make-resolved-callback (handler-fn target-promise
                                         &key context captured-vars)
  "Create a `concur-callback` for a resolved handler. Low-level primitive."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (puthash 'origin-promise (concur-callback-promise target-promise) final-context)
    (%%make-callback :type :resolved :fn handler-fn
                     :promise target-promise
                     :context `',final-context)))

(cl-defun concur-make-rejected-callback (handler-fn target-promise
                                         &key context captured-vars)
  "Create a `concur-callback` for a rejected handler. Low-level primitive."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (puthash 'origin-promise (concur-callback-promise target-promise) final-context)
    (%%make-callback :type :rejected :fn handler-fn
                     :promise target-promise
                     :context `',final-context)))

(provide 'concur-core)
;;; concur-core.el ends here