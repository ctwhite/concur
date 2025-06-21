;;; concur-core.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;; This file defines the fundamental `concur-promise` data structure and
;; the core operations for creating, resolving, and rejecting promises. It
;; lies at the heart of the Concur library, implementing the state machine,
;; callback scheduling, and thread-safety primitives.
;;
;; Architectural Highlights:
;; - Promise/A+ Compliant Scheduling: Separates macrotasks (idle timer) and
;;   microtasks (immediate) for predictable execution order.
;; - AST-based Lexical Context Capture: To ensure callbacks work reliably
;;   when byte-compiled, handler functions are analyzed to capture their
;;   lexical environment. This context is then restored before execution.
;; - Thread-Safety and Concurrency Modes: `concur-lock` protects state;
;;   `mode` (`:deferred`, `:thread`) determines lock type. `await` behavior
;;   is adapted based on the execution context (thread vs. main).
;; - True Thread-Safe Signaling: For promises operating in `:thread` mode, a
;;   dedicated pipe and process sentinel are used. This allows background
;;   threads to safely and efficiently schedule callbacks on the main Emacs
;;   thread without polling, ensuring that UI-bound operations execute in the
;;   correct context.
;; - Extensibility: `concur-normalize-awaitable-hook` integrates external
;;   awaitable objects.

;;; Code:

(require 'cl-lib)            ; Common Lisp extensions for struct, loop, etc.
(require 'dash)              ; Utility functions like `--each`, `--map`, `-filter`
(require 's)                  ; String manipulation functions

(require 'concur-log)       ; Custom hooks for extensibility
(require 'concur-cancel)      ; Cancellation token and related logic
(require 'concur-lock)
(require 'concur-semaphore)   ; For semaphore integration
(require 'concur-ast)         ; For analyzing and capturing lexical environments
(require 'concur-scheduler)   ; Generalized task scheduler (for macrotasks)
(require 'concur-microtask)   ; Microtask queue (for immediate execution)
(require 'concur-registry)    ; Promise registry for introspection

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:finally "concur-chain" (promise callback-form))
(declare-function concur-registry-get-promise-name "concur-registry"
                  (promise &optional default))
(declare-function concur-registry-register-promise "concur-registry"
                  (promise name &key parent-promise))
(declare-function concur-registry-update-promise-state "concur-registry" (promise))
(declare-function concur-registry-register-resource-hold "concur-registry"
                  (promise resource))
(declare-function concur-registry-release-resource-hold "concur-registry"
                  (promise resource))

(defvar yield--await-external-status-key nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants, Customization, and Errors

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

(defcustom concur-resolve-callbacks-begin-hook nil
  "Hook run when a batch of promise callbacks begins execution.

Arguments:
- PROMISE (`concur-promise`): The promise that settled.
- CALLBACKS (list of `concur-callback`): The callbacks being processed."
  :type 'hook
  :group 'concur)

(defcustom concur-resolve-callbacks-end-hook nil
  "Hook run when a batch of promise callbacks finishes execution.

Arguments:
- PROMISE (`concur-promise`): The promise that settled.
- CALLBACKS (list of `concur-callback`): The callbacks that were processed."
  :type 'hook
  :group 'concur)

(defcustom concur-unhandled-rejection-hook nil
  "Hook run when a promise is rejected and no rejection handler is attached.
This hook runs *before* `concur-throw-on-promise-rejection` takes effect.

Arguments:
- PROMISE (`concur-promise`): The promise that was rejected.
- ERROR (any): The error object itself."
  :type 'hook
  :group 'concur)

(defcustom concur-normalize-awaitable-hook nil
  "Hook run to normalize arbitrary awaitable objects into `concur-promise`s.
Functions added to this hook should accept one argument (the awaitable object)
and return a `concur-promise` if they can normalize it, or `nil` otherwise.
Handlers are run in order until one succeeds.
Example: `(add-hook 'concur-normalize-awaitable-hook #'concur-future-normalize-future)`."
  :type 'hook
  :group 'concur)

(defvar concur--current-promise-context nil
  "Dynamically bound to the promise currently being processed by an executor
or callback handler. Useful for resource tracking and contextual debugging.")

(defvar concur--macrotask-scheduler nil
  "The global scheduler instance for macrotasks.
This is an instance of `concur-scheduler`, responsible for
processing deferred promise callbacks via an idle timer.")

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
Used to build richer debugging information on promise rejection,
providing context for `concur-error` objects.")

(defvar concur--unhandled-rejections-queue '()
  "A list (acting as a queue) of unhandled promise rejections that occurred.
These `concur-error` objects are stored for later inspection, allowing
monitoring without necessarily halting Emacs for every unhandled error.")

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
  (cancel-token nil :type (or null (satisfies concur-cancel-token-p)))
  (cancelled-p nil :type boolean)
  (proc nil)
  (lock nil :type (or null (satisfies concur-lock-p)))
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
  (promise nil :type (or null (satisfies concur-promise-p)))
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
  (promise nil :type (or null (satisfies concur-promise-p)))
  (async-stack-trace nil :type (or null string)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State and Schedulers

(defun concur--init-macrotask-queue ()
  "Initialize the global macrotask scheduler if it doesn't exist."
  (unless concur--macrotask-scheduler
    (setq concur--macrotask-scheduler
          (concur-scheduler-create
           :name "concur--macrotask-scheduler"
           :comparator (lambda (cb1 cb2)
                         (< (concur-callback-priority cb1)
                            (concur-callback-priority cb2)))
           :process-fn #'concur--process-macrotask-batch-internal))))
(concur--init-macrotask-queue)

(defun concur--schedule-macrotasks (callbacks-list)
  "Add a list of callbacks to the macrotask scheduler.
Ensures callbacks run asynchronously, preventing the 'Zalgo problem'.
;; Promises/A+ Spec 2.2.4: `onFulfilled` or `onRejected` must not be
;; called until the execution context stack contains only platform code."
  (dolist (cb callbacks-list)
    (concur-scheduler-enqueue concur--macrotask-scheduler cb)))

(defun concur--process-macrotask-batch-internal (scheduler)
  "Execute a batch of callbacks from the macrotask scheduler."
  (let ((batch (concur-scheduler-pop-batch scheduler)))
    (when batch
      (--each batch #'concur-execute-callback)
      (concur-microtask-queue-drain))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Core Promise Lifecycle

(defun concur--settle-promise (promise result error is-cancellation)
  "The core internal function to settle a promise (resolve or reject).
This function is idempotent and thread-safe.
;; Promises/A+ Spec 2.1: A promise must be in one of three states:
;; pending, fulfilled, or rejected.
;; Promises/A+ Spec 2.1.2 & 2.1.3: When fulfilled or rejected, a promise
;; must not transition to any other state."
  (let ((settled-now nil))
    (concur:with-mutex! (concur-promise-lock promise)
      ;; The core idempotency check: only proceed if still pending.
      (when (eq (concur-promise-state promise) :pending)
        (let ((new-state (if error :rejected :resolved)))
          (setf (concur-promise-result promise) result)
          (setf (concur-promise-error promise) error)
          (setf (concur-promise-cancelled-p promise) is-cancellation)
          (setf (concur-promise-state promise) new-state)
          (setq settled-now t)
          (concur--trigger-callbacks-after-settle promise)
          (when is-cancellation
            (concur--kill-associated-process promise)))))
    (when settled-now
      (when (fboundp 'concur-registry-update-promise-state)
        (concur-registry-update-promise-state promise))))
  promise)

(defun concur--kill-associated-process (promise)
  "If PROMISE has an associated process, kill it."
  (when-let ((proc (concur-promise-proc promise)))
    (when (process-live-p proc)
      (delete-process proc))
    (setf (concur-promise-proc promise) nil)))

(defun concur--trigger-callbacks-after-settle (promise)
  "Called once a promise settles to schedule its callbacks."
  (let ((callback-links (concur-promise-callbacks promise)))
    ;; Promises/A+ Spec 2.2.2.3 & 2.2.3.3: Callbacks must not be called more
    ;; than once. Clearing the list ensures this.
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
             (not (-some (lambda (link)
                           (-some (lambda (cb) (eq (concur-callback-type cb)
                                                   :rejected))
                                  (concur-callback-link-callbacks link)))
                         callback-links)))
    (let ((error-obj (concur:make-error
                      :type :unhandled-rejection
                      :message (format "Unhandled promise rejection: %s"
                                       (concur-format-value-or-error
                                        (concur-promise-error promise)))
                      :cause (concur-promise-error promise)
                      :promise promise)))
      (push error-obj concur--unhandled-rejections-queue)
      (run-hook-with-args 'concur-unhandled-rejection-hook promise error-obj)
      (when concur-throw-on-promise-rejection
        (signal 'concur-unhandled-rejection
                (list (concur:error-message error-obj) error-obj))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal: Callback and Context Management

(defun concur-current-async-stack-string ()
  "Format `concur--current-async-stack` into a readable string."
  (when concur--current-async-stack
    (mapconcat #'identity (reverse concur--current-async-stack) "\n↳ ")))

(defun concur--merge-contexts (existing-context captured-vars-alist)
  "Merge contexts into a new hash table."
  (let ((merged-ht (make-hash-table :test 'eq)))
    (cond ((hash-table-p existing-context)
           (maphash (lambda (k v) (puthash k v merged-ht)) existing-context))
          ((listp existing-context)
           (--each existing-context (puthash (car it) (cdr it) merged-ht))))
    (when (listp captured-vars-alist)
      (--each captured-vars-alist (puthash (car it) (cdr it) merged-ht)))
    merged-ht))

(defun concur-execute-callback (callback)
  "Executes a single callback, handling context evaluation and errors."
  (let* ((origin-promise (concur-callback-promise callback))
         (handler (concur-callback-fn callback))
         (type (concur-callback-type callback))
         (target-promise (concur-callback-promise callback))
         (context (eval (concur-callback-context callback)))
         (let-bindings
          (let (bindings)
            (maphash #'(lambda (k v) (push `(,k ',v) bindings)) context)
            bindings)))
    (let ((concur--current-promise-context target-promise))
      (let ((concur-resource-tracking-function
             (lambda (action resource)
               (pcase action
                 (:acquire (concur-registry-register-resource-hold
                            target-promise resource))
                 (:release (concur-registry-release-resource-hold
                            target-promise resource))))))
        (condition-case err
            (let ((result (concur-promise-result origin-promise))
                  (error (concur-promise-error origin-promise)))
              (pcase type
                (:resolved
                 (when (not error)
                   (concur-chain-or-settle-promise
                    target-promise (funcall handler result))))
                (:rejected
                 (when error
                   (concur-chain-or-settle-promise
                    target-promise (funcall handler error))))
                (:finally
                 (let ((res (funcall handler)))
                   (if error
                       (concur:reject target-promise error)
                     (concur-chain-or-settle-promise target-promise res))))
                (:await-latch
                 (funcall handler nil context))))
          (error
           (concur:reject
            target-promise
            (concur:make-error :type :callback-error
                               :message (format "Callback failed: %S" err)
                               :cause err :promise origin-promise))))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal `await` Implementation

(defun concur--await-latch-signaler-function (_value context-ht)
  "Internal function for :await-latch callbacks."
  (let* ((latch (gethash 'latch context-ht))
         (promise (gethash 'target-promise context-ht)))
    (when (and latch (not (eq (concur-await-latch-signaled-p latch) 'timeout)))
      (setf (concur-await-latch-signaled-p latch) t)
      (when-let (cond-var (concur-await-latch-cond-var latch))
        (concur:with-mutex! (concur-promise-lock promise)
          (condition-notify cond-var))))))

(cl-defun concur--make-await-latch-callback (latch target-promise)
  "Create a `concur-callback` for an `await` latch."
  (let ((context (make-hash-table)))
    (puthash 'latch latch context)
    (puthash 'target-promise target-promise context)
    (%%make-callback :type :await-latch
                     :fn #'concur--await-latch-signaler-function
                     :promise target-promise
                     :context `',context)))

(defun concur--await-blocking (promise timeout)
  "The cooperative blocking implementation for `concur:await`.
This function is the heart of synchronous-style waiting. It handles
the full lifecycle of a blocking `await` call outside a coroutine.

Arguments:
- `PROMISE` (concur-promise): The promise to wait for.
- `TIMEOUT` (number, optional): Maximum seconds to wait."
  ;; Step 1: Handle the trivial case where the promise is already settled.
  ;; This avoids all the overhead of setting up latches and timers.
  (when (not (eq (concur:status promise) :pending))
    (if-let ((err (concur:error-value promise)))
        ;; If it was rejected, signal a standard `concur-await-error`.
        (signal 'concur-await-error (list (concur:error-message err) err))
      ;; If it was resolved, just return the value.
      (return-from concur--await-blocking (concur:value promise))))

  ;; Step 2: For a pending promise, set up the blocking machinery.
  (let ((latch (%%make-await-latch))
        (timer nil))
    ;; `unwind-protect` is crucial to ensure the timeout timer is always
    ;; cancelled, preventing it from firing after the await has completed.
    (unwind-protect
        (progn
          ;; Step 2a: Attach a high-priority microtask callback to the promise.
          ;; This callback's only job is to signal our latch when the promise settles.
          (concur-attach-callbacks
           promise (concur--make-await-latch-callback latch promise))

          ;; Step 2b: If a timeout was specified, create and start a timer.
          ;; The timer will signal the latch with the special 'timeout value.
          (when timeout
            (setq timer (run-at-time timeout nil
                                     #'(lambda ()
                                         (setf (concur-await-latch-signaled-p latch)
                                               'timeout)))))

          ;; Step 2c: Choose the blocking strategy based on the promise's mode.
          (if (eq (concur-promise-mode promise) :thread)
              ;; For `:thread` mode, use a real condition variable for efficient
              ;;, true thread blocking.
              (let ((cond-var (make-condition-variable
                               (concur-promise-lock promise))))
                (setf (concur-await-latch-cond-var latch) cond-var)
                (concur:with-mutex! (concur-promise-lock promise)
                  (while (not (concur-await-latch-signaled-p latch))
                    (condition-wait cond-var))))
            ;; For `:deferred` mode, use a cooperative polling loop. `sit-for`
            ;; yields control to Emacs, allowing other events to process.
            (while (not (concur-await-latch-signaled-p latch))
              (sit-for concur-await-poll-interval)))

          ;; Step 3: The loop has exited. Check the latch to see why.
          (if (eq (concur-await-latch-signaled-p latch) 'timeout)
              ;; The timer fired first.
              (signal 'concur-timeout-error
                      (list (format "Await for %s timed out"
                                    (concur:format-promise promise))))
            ;; The promise settled. Check if it resolved or rejected.
            (if-let ((err (concur:error-value promise)))
                (signal 'concur-await-error
                        (list (concur:error-message err) err))
              (concur:value promise))))
      ;; Final cleanup step of `unwind-protect`.
      (when timer (cancel-timer timer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Construction and State Transition

;;;###autoload
(cl-defun concur:make-promise (&key (mode :deferred) name cancel-token parent-promise)
  "Create a new, pending `concur-promise`.
This is the main entry point for creating a promise that you will
manually resolve or reject later.

Arguments:
- `:MODE` (symbol, optional): Concurrency mode (`:deferred`, `:thread`).
  `:deferred` (default): Safe for main thread, non-blocking ops.
  `:thread`: Safe for use across multiple Emacs threads. Settlement
    from a background thread will be safely dispatched to the main thread.
- `:NAME` (string, optional): A descriptive name for debugging and registry.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): Token to link for cancellation.
- `:PARENT-PROMISE` (concur-promise, optional): The promise that created this one.

Returns:
  (concur-promise) A new promise in the `:pending` state."
  (let* ((p (%%make-promise
             :id (gensym "promise-")
             :mode mode
             :lock (concur:make-lock nil :mode mode)
             :cancel-token cancel-token)))
    (when (fboundp 'concur-registry-register-promise)
      (concur-registry-register-promise p
                                      (or name (symbol-name (concur-promise-id p)))
                                      :parent-promise parent-promise))
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
  "Resolve PROMISE with VALUE, implementing the Promise/A+ resolution procedure.
;; Promises/A+ Spec 2.3: The Promise Resolution Procedure.
This function encapsulates the logic for handling resolutions with
`thenable` values, ensuring compliance."
  (let ((normalized-value (if (concur-promise-p value)
                              value
                            (run-hook-with-args-until-success
                             'concur-normalize-awaitable-hook value value))))
    (cond
     ;; Promises/A+ Spec 2.3.1: If promise and x refer to the same object,
     ;; reject promise with a `TypeError` as the reason.
     ((eq promise normalized-value)
      (concur--settle-promise
       promise nil
       (concur:make-error :type :type-error
                          :message "A promise cannot be resolved with itself.")
       nil))
     ;; Promises/A+ Spec 2.3.2: If x is a promise, adopt its state.
     ((concur-promise-p normalized-value)
      (concur-attach-callbacks
       normalized-value
       (concur-make-resolved-callback
        (lambda (res-val) (concur-chain-or-settle-promise promise res-val))
        promise)
       (concur-make-rejected-callback
        (lambda (rej-err) (concur:reject promise rej-err))
        promise)))
     ;; Promises/A+ Spec 2.3.3: Otherwise, fulfill promise with x.
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
This is a convenient factory function for immediately resolved promises.

Arguments:
- `VALUE` (any): The value to resolve the new promise with.
- `:MODE` (symbol, optional): Concurrency mode for the promise's internal lock.

Returns:
  (concur-promise) A new promise in the `:resolved` state."
  (let ((p (concur:make-promise :mode mode)))
    (concur:resolve p value)
    p))

;;;###autoload
(cl-defun concur:rejected! (error &key (mode :deferred))
  "Create and return a new promise that is already rejected with ERROR.
This is a convenient factory function for immediately rejected promises.

Arguments:
- `ERROR` (any): The error to reject the new promise with.
- `:MODE` (symbol, optional): Concurrency mode for the promise's internal lock.

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
    (concur:reject promise
                   (concur:make-error :type :cancel
                                      :message (or reason "Promise cancelled")))))

;;;###autoload
(cl-defun concur:make-error (&rest args &key type message cause promise)
  "Create a new `concur-error` struct.
This function provides a convenient way to create standardized error objects
for consistent rejection reasons across the Concur library.

Arguments:
- `ARGS` (plist): Keyword arguments matching the `concur-error` struct fields.
- `:TYPE` (keyword): A keyword identifying the error type. Defaults to `:generic`.
- `:MESSAGE` (string): A human-readable error message.
- `:CAUSE` (any, optional): The original error/reason (if wrapping another).
- `:PROMISE` (`concur-promise`, optional): The promise associated with error.

Returns:
  (concur-error) A new error struct."
  (apply #'%%make-concur-error
         :async-stack-trace (concur-current-async-stack-string)
         args))

;;;###autoload
(cl-defmacro concur:with-executor (executor-fn-form &rest opts
                                   &key (mode :deferred) cancel-token &environment env)
  "Define and execute an async block that controls a new promise.
This is a primary entry point for creating promises from imperative code. It
robustly captures the lexical environment of the executor lambda to ensure it
works correctly when byte-compiled. It also establishes context for resource
tracking, linking primitives used inside to the new promise.

Arguments:
- `EXECUTOR-FN-FORM` (lambda): A lambda of the form `(lambda (resolve reject) ...)`.
- `OPTS` (plist): Options passed to `concur:make-promise` (e.g., `:name`).
- `:MODE` (symbol, optional): Concurrency mode for the new promise.
- `:CANCEL-TOKEN` (`concur-cancel-token`, optional): For cancellation.

Returns:
- (concur-promise): A new promise controlled by the executor."
  (declare (indent 1) (debug t))
  ;; Step 1: Analyze the executor lambda to find its free variables.
  ;; This is crucial for capturing the lexical context.
  (let* ((promise (gensym "promise-"))
         (analysis (concur-ast-analysis executor-fn-form env))
         (callable (concur-ast-analysis-result-expanded-callable-form analysis))
         (context-form (concur-ast-make-captured-vars-form
                        (concur-ast-analysis-result-free-vars-list analysis))))
    `(let ((,promise (concur:make-promise :mode ,mode :cancel-token ,cancel-token
                                          ,@opts)))
       ;; Step 2: Dynamically bind a tracking function. Any `concur` primitive
       ;; used inside the executor will call this hook to register its
       ;; resource (e.g., a lock) with the new promise.
       (let ((concur-resource-tracking-function
              (lambda (action resource)
                (pcase action
                  (:acquire (concur-registry-register-resource-hold
                             ,promise resource))
                  (:release (concur-registry-release-resource-hold
                             ,promise resource))))))
         ;; Step 3: Execute the user's code inside a `condition-case` to
         ;; catch any synchronous errors during initialization.
         (condition-case err
             (let ((context ,context-form))
               ;; Step 3a: Re-establish the lexical environment by `let`-binding
               ;; the captured variables before calling the user's function.
               (let ,(mapcar (lambda (v) `(,v (gethash ',v context)))
                             (concur-ast-analysis-result-free-vars-list
                              analysis))
                 ;; Step 3b: Call the user's function with `resolve` and `reject` handlers.
                 (funcall ,callable
                          (lambda (value) (concur:resolve ,promise value))
                          (lambda (error) (concur:reject ,promise error)))))
           (error
            ;; If the executor itself throws an error, reject the promise.
            (concur:reject
             ,promise
             (concur:make-error :type :executor-error
                                :message (format "Executor failed: %S" err)
                                :cause err :promise ,promise))))
         ;; Step 4: Return the new promise immediately.
         ,promise))))

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
This provides a way to write asynchronous code in a more sequential style.

Its behavior depends on the context:
1.  **Outside a coroutine:** It blocks based on the promise's `mode`.
    - `:deferred`: Blocks Emacs cooperatively (UI remains responsive).
    - `:thread`: Blocks the current thread using a condition variable.
2.  **Inside a `concur:async` coroutine:** It yields control to the
    coroutine scheduler, resuming only after the awaited promise settles.

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
- `TIMEOUT` (number, optional): Seconds to wait before signaling a
  `concur:timeout-error` error (only applies outside coroutines).
  If `nil`, waits indefinitely. If omitted, uses `concur-await-default-timeout`.

Returns:
  (any) The resolved value of the promise. Signals an error if
  the promise is rejected or times out."
  (declare (indent 1) (debug t))
  `(let ((p ,promise-form))
     (if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
         ;; In a coroutine context, yield instead of blocking.
         (if (eq (concur:status p) :pending)
             (yield--internal-throw-form p ',yield--await-external-status-key)
           (if-let ((err (concur:error-value p)))
               (signal 'concur-await-error (list (concur:error-message err) err))
             (concur:value p)))
       ;; Outside a coroutine, block synchronously.
       (concur--await-blocking p (or ,timeout concur-await-default-timeout)))))

;;;###autoload
(defmacro concur:from-callback (fetch-fn-form)
  "Wrap a traditional callback-based async function into a `concur-promise`.
This is a bridge for older APIs that use the `(lambda (result error) ...)`
pattern, integrating them seamlessly into the Promise system.

Arguments:
- `FETCH-FN-FORM` (form): A form that evaluates to a function. This
  function is called with a single argument: the `(result error)` callback.

Returns:
  (concur-promise) A promise that resolves or rejects when
  the underlying callback is invoked."
  (declare (indent 1) (debug t))
  `(concur:with-executor
       (lambda (resolve reject)
         (funcall ,fetch-fn-form
                  (lambda (result error)
                    (if error
                        (funcall reject error)
                      (funcall resolve result)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Promise Introspection & Unhandled Rejection API

;;;###autoload
(defun concur:status (promise)
  "Return current state of a PROMISE without blocking.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (symbol) The current state (`:pending`, `:resolved`, or `:rejected`)."
  (unless (concur-promise-p promise)
    (error "Invalid promise object: %S" promise))
  (concur-promise-state promise))

;;;###autoload
(defun concur:pending-p (promise)
  "Return non-nil if PROMISE is pending.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (boolean) `t` if pending, `nil` otherwise."
  (eq (concur:status promise) :pending))

;;;###autoload
(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has resolved successfully.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (boolean) `t` if resolved, `nil` otherwise."
  (eq (concur:status promise) :resolved))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE was rejected.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (boolean) `t` if rejected, `nil` otherwise."
  (eq (concur:status promise) :rejected))

;;;###autoload
(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE was cancelled.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (boolean) `t` if cancelled, `nil` otherwise."
  (concur-promise-cancelled-p promise))

;;;###autoload
(defun concur:value (promise)
  "Return resolved value of PROMISE, or nil if not resolved. Non-blocking.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (any) The resolved value, or `nil`."
  (when (eq (concur:status promise) :resolved)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return error of PROMISE if rejected, else nil. Non-blocking.
Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
Returns:
  (any) The rejection error, or `nil`."
  (when (eq (concur:status promise) :rejected)
    (concur-promise-error promise)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return human-readable message from a promise's error or an error object.
Arguments:
- `PROMISE-OR-ERROR` (concur-promise or any): Promise or error object.
Returns:
  (string) A descriptive error message."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (if (concur-error-p err) (concur-error-message err)
      (format "%s" err))))

;;;###autoload
(defun concur:format-promise (p)
  "Return human-readable string representation of a promise.
This function leverages the promise registry for descriptive names.

Arguments:
- `P` (concur-promise): The promise to format.

Returns:
  (string) A descriptive string including ID, mode, state, and name."
  (if (not (concur-promise-p p))
      (format "%S" p)
    (let* ((id (concur-promise-id p))
           (mode (concur-promise-mode p))
           (status (concur:status p))
           (name (if (fboundp 'concur-registry-get-promise-name)
                     (concur-registry-get-promise-name p (symbol-name id))
                   (symbol-name id))))
      (pcase status
        (:pending (format "#<Promise %s (%s) %s: pending>" name id mode))
        (:resolved (format "#<Promise %s (%s) %s: resolved with %s>" name id mode
                           (concur-format-value-or-error (concur:value p))))
        (:rejected (format "#<Promise %s (%s) %s: rejected with %s>" name id mode
                           (concur-format-value-or-error
                            (concur:error-value p))))))))

(defun concur-unhandled-rejections-count ()
  "Return the number of unhandled promise rejections currently queued.
Returns:
  (integer) The count of unhandled rejections."
  (length concur--unhandled-rejections-queue))

(defun concur-get-unhandled-rejections ()
  "Return a list of all currently tracked unhandled promise rejections.
This function clears the internal queue after returning the list.
Returns:
  (list) A list of `concur-error` objects."
  (prog1 (nreverse concur--unhandled-rejections-queue)
    (setq concur--unhandled-rejections-queue '())))

(defun concur-has-unhandled-rejections-p ()
  "Return non-nil if there are any unhandled promise rejections queued.
Returns:
  (boolean) `t` if unhandled rejections exist, `nil` otherwise."
  (not (null concur--unhandled-rejections-queue)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Low-Level Primitives for Library Authors

(defun concur-attach-callbacks (promise &rest callbacks)
  "Attach a set of callbacks to a PROMISE.
This is a low-level primitive intended for macro authors or
advanced use. For general use, prefer `concur:then`.

Arguments:
- `PROMISE` (concur-promise): The promise to attach callbacks to.
- `CALLBACKS` (rest `concur-callback`): A list of `concur-callback` structs.

Returns:
  The original `PROMISE`."
  (let* ((non-nil-callbacks (-filter #'identity callbacks))
         (link (%%make-callback-link :id (gensym "link-")
                                     :callbacks non-nil-callbacks)))
    (concur:with-mutex! (concur-promise-lock promise)
      (if (eq (concur-promise-state promise) :pending)
          ;; Promises/A+ Spec 2.2.6: `then` may be called multiple times on the
          ;; same promise.
          (push link (concur-promise-callbacks promise))
        ;; If already settled, schedule the callbacks now.
        (concur--partition-and-schedule-callbacks (list link)))))
  promise)

(cl-defun concur-make-resolved-callback
    (handler-fn target-promise &key context captured-vars)
  "Create a `concur-callback` struct for a resolved handler.
Arguments:
- `HANDLER-FN` (function): The success handler function.
- `TARGET-PROMISE` (concur-promise): The promise this callback will settle.
- `:CONTEXT` (list): An alist of context variables to merge.
- `:CAPTURED-VARS` (list): An alist of captured vars from AST analysis.
Returns:
  (concur-callback) A new callback struct."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (puthash 'origin-promise target-promise final-context)
    (%%make-callback :type :resolved :fn handler-fn
                     :promise target-promise
                     :context `',final-context)))

(cl-defun concur-make-rejected-callback
    (handler-fn target-promise &key context captured-vars)
  "Create a `concur-callback` struct for a rejected handler.
Arguments:
- `HANDLER-FN` (function): The failure handler function.
- `TARGET-PROMISE` (concur-promise): The promise this callback will settle.
- `:CONTEXT` (list): An alist of context variables to merge.
- `:CAPTURED-VARS` (list): An alist of captured vars from AST analysis.
Returns:
  (concur-callback) A new callback struct."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (puthash 'origin-promise target-promise final-context)
    (%%make-callback :type :rejected :fn handler-fn
                     :promise target-promise
                     :context `',final-context)))

(provide 'concur-core)
;;; concur-core.el ends here
