;;; concur-core.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the fundamental `concur-promise` data structure and
;; the core operations for creating, resolving, and rejecting promises. It
;; lies at the heart of the Concur library, implementing the state machine,
;; callback scheduling, and thread-safety primitives.
;;
;; Architectural Highlights:
;; - Promise/A+ Compliant Scheduling: Separates macrotasks (for `.then`
;;   callbacks, run on an idle timer) and microtasks (for `await`, run
;;   immediately) to ensure a responsive and predictable execution order.
;;
;; - Native Closure Support: Callbacks are standard lexical closures,
;;   eliminating the need for complex and fragile AST analysis.
;;
;; - Thread-Safety and Concurrency Modes: `concur-lock` protects state;
;;   `mode` (`:deferred`, `:thread`) determines lock type.
;;
;; - True Thread-Safe Signaling: For promises in `:thread` mode, a dedicated
;;   pipe and process sentinel are used. This allows background threads to
;;   safely and efficiently schedule callbacks on the main Emacs thread without
;;   polling.
;;
;; - Extensibility: `concur-normalize-awaitable-hook` allows third-party
;;   libraries to integrate their own awaitable objects.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 's)
(require 'json)

(require 'concur-log)
(require 'concur-lock)
(require 'concur-scheduler)
(require 'concur-microtask)
(require 'concur-registry)
(require 'coroutines)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward Declarations & Global Context

(declare-function concur-cancel-token-p "concur-cancel")
(declare-function concur-cancel-token-add-callback "concur-cancel")
(declare-function concur-registry-get-promise-by-id "concur-registry")
(declare-function concur-registry-register-promise "concur-registry")
(declare-function concur-registry-update-promise-state "concur-registry")
(declare-function concur-registry-register-resource-hold "concur-registry")
(declare-function concur-registry-release-resource-hold "concur-registry")
(declare-function concur-registry-get-promise-name "concur-registry")

(defvar concur--coroutine-yield-throw-tag nil
  "Internal variable for `coroutines.el` integration with `concur:await`.
This is used by `concur:await` to yield control within a coroutine
via a `throw` to a known tag.")

(defvar concur--current-promise-context nil
  "Dynamically bound to the promise currently being processed.
This is used by an executor or callback handler and is useful for
resource tracking and contextual debugging.")

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
Used to build richer debugging information on promise rejection,
providing context for `concur-error` objects.")

(defvar concur--unhandled-rejections-queue '()
  "A list (acting as a queue) of unhandled promise rejections.
These `concur-error` objects are stored for later inspection, allowing
monitoring without necessarily halting Emacs for every unhandled error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Constants, Customization, and Errors

(defgroup concur nil "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defcustom concur-log-value-max-length 100
  "Maximum length of a value/error string in log messages before truncation."
  :type 'integer
  :group 'concur)

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, signal a `concur-unhandled-rejection` error.
When a promise is rejected and has no rejection handlers attached,
this controls whether to ignore it or signal an error. Set to `nil`
to suppress automatic errors for unhandled rejections."
  :type 'boolean
  :group 'concur)

(defcustom concur-await-poll-interval 0.01
  "The polling interval (in seconds) for `concur:await` blocking."
  :type 'float
  :group 'concur)

(defcustom concur-await-default-timeout 10.0
  "Default timeout (in seconds) for `concur:await` if not specified.
If `nil`, `concur:await` will wait indefinitely by default."
  :type '(choice (float :min 0.0) (const :tag "Indefinite" nil))
  :group 'concur)

(defcustom concur-resolve-callbacks-begin-hook nil
  "Hook run when a batch of promise callbacks begins execution."
  :type 'hook
  :group 'concur)

(defcustom concur-resolve-callbacks-end-hook nil
  "Hook run when a batch of promise callbacks finishes execution."
  :type 'hook
  :group 'concur)

(defcustom concur-unhandled-rejection-hook nil
  "Hook run when a promise is rejected and no rejection handler is attached."
  :type 'hook
  :group 'concur)

(defcustom concur-normalize-awaitable-hook nil
  "Hook run to normalize arbitrary awaitable objects into `concur-promise`s."
  :type 'hook
  :group 'concur)

(define-error 'concur-error "A generic error in the Concur library.")
(define-error 'concur-unhandled-rejection
  "A promise was rejected with no handler." 'concur-error)
(define-error 'concur-await-error
  "An error occurred while awaiting a promise." 'concur-error)
(define-error 'concur-cancel-error "A promise was cancelled." 'concur-error)
(define-error 'concur-timeout-error "An operation timed out." 'concur-error)
(define-error 'concur-type-error
  "An invalid type was encountered." 'concur-error)
(define-error 'concur-executor-error
  "An error occurred within a promise executor function." 'concur-error)
(define-error 'concur-callback-error
  "An error occurred within a promise callback handler (then/catch/finally)."
  'concur-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct Definitions

(cl-defstruct (concur-promise (:constructor %%make-promise) (:copier nil))
  "Represents an asynchronous operation that can resolve or reject.
This is the central data structure of the library. Do not
manipulate its fields directly; use the `concur:*` functions.

Fields:
- `id` (symbol): A unique identifier (`gensym`) for logging and debugging.
- `result` (any): The value the promise resolved with.
- `error` (concur-error or nil): The reason the promise was rejected.
- `state` (symbol): The current state: `:pending`, `:resolved`, or `:rejected`.
- `callbacks` (list): A list of `concur-callback-link` structs.
- `cancel-token` (concur-cancel-token, optional): For cancellation.
- `cancelled-p` (boolean): `t` if the promise was rejected due to cancellation.
- `proc` (process or nil): An optional associated external process object.
- `lock` (concur-lock): A mutex protecting all fields from concurrent access.
- `mode` (symbol): The concurrency mode (`:deferred`, `:thread`, or `:async`)."
  (id nil :type symbol)
  (result nil :type t)
  (error nil :type (or null concur-error))
  (state :pending :type (member :pending :resolved :rejected))
  (callbacks nil :type list)
  (cancel-token nil :type (or null concur-cancel-token))
  (cancelled-p nil :type boolean)
  (proc nil :type (or null process))
  (lock nil :type (or null concur-lock))
  (mode :deferred :type (member :deferred :thread :async)))

(cl-defstruct (concur-await-latch (:constructor %%make-await-latch)
                                  (:copier nil))
  "Internal latch for the `concur:await` mechanism.
This acts as a shared flag between a waiting `concur:await` call
and the promise callback that signals completion.

Fields:
- `signaled-p` (boolean or `timeout`): The flag indicating completion.
- `cond-var` (condition-variable or nil): For efficient blocking in threads."
  (signaled-p nil :type (or boolean (eql timeout)))
  (cond-var nil))

(cl-defstruct (concur-callback (:constructor %%make-callback) (:copier nil))
  "An internal struct that encapsulates a callback function.
The handler function is a standard Emacs Lisp closure which automatically
captures its lexical environment when it is created.

Fields:
- `type` (symbol): Type of handler: `:resolved`, `:rejected`, `:await-latch`.
- `handler-fn` (function): The actual closure object to be executed.
- `promise-id` (symbol): ID of the *target* promise, i.e., the promise
  settled by this handler's result.
- `source-promise-id` (symbol): ID of the *source* promise, i.e., the
  promise whose result is the input to this handler.
- `priority` (integer): Execution priority (lower is higher)."
  (type nil :type (member :resolved :rejected :await-latch))
  (handler-fn nil :type function)
  (promise-id nil :type symbol)
  (source-promise-id nil :type symbol)
  (priority 50 :type integer))

(cl-defstruct (concur-callback-link (:constructor %%make-callback-link)
                                    (:copier nil))
  "Represents one link in a promise chain, grouping related callbacks.
A single call to `concur:then` attaches both a resolve and a
reject handler. This struct groups them for coherent processing.

Fields:
- `id` (symbol): A unique ID for debugging this link.
- `callbacks` (list): A list of `concur-callback` structs."
  (id nil :type symbol)
  (callbacks nil :type list))

(cl-defstruct (concur-error (:constructor %%make-concur-error) (:copier nil))
  "A standardized error object for promise rejections.
This provides a consistent structure for error handling, allowing for
richer introspection than a simple string or Lisp error condition.

Fields:
- `type` (keyword): Keyword identifying the error (`:cancel`, `:timeout`).
- `message` (string): A human-readable error message.
- `cause` (any): The original Lisp error or reason that triggered this.
- `promise` (concur-promise or nil): The promise instance that rejected.
- `async-stack-trace` (string or nil): Formatted async/Lisp backtrace.
- `cmd` (string or nil): If process-related, the command that was run.
- `args` (list or nil): If process-related, the command arguments.
- `cwd` (string or nil): If process-related, the working directory.
- `exit-code` (integer or nil): If process-related, the process exit code.
- `signal` (string or nil): If process-related, the signal that killed it.
- `process-status` (symbol or nil): If process-related, the process status.
- `stdout` (string or nil): If process-related, collected stdout.
- `stderr` (string or nil): If process-related, collected stderr."
  (type :generic :type keyword)
  (message "An unspecific Concur error occurred." :type string)
  (cause nil)
  (promise nil)
  (async-stack-trace nil :type (or null string))
  (cmd nil :type (or string null))
  (args nil :type (or list null))
  (cwd nil :type (or string null))
  (exit-code nil :type (or integer null))
  (signal nil :type (or string null))
  (process-status nil :type (or symbol null))
  (stdout nil :type (or string null))
  (stderr nil :type (or string null)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; True Thread-Safe Signaling Mechanism
;;
;; This mechanism solves a core problem: how can a native Emacs Lisp thread
;; (created with `make-thread`) safely tell the main Emacs thread to execute
;; a callback? The main thread owns the UI and most data structures, so direct
;; manipulation from a background thread is unsafe.
;;
;; The strategy is to use a file descriptor (a pipe) that the main thread
;; can listen to. We create a dummy, no-op external process whose only job is
;; to have its standard I/O connected to our pipe. A `sentinel` function is
;; attached to this process. This sentinel runs on the main Emacs event loop
;; whenever there is activity on the pipe.
;;
;; When a background thread needs to schedule a callback, it simply writes the
;; ID of the settled promise to the pipe. The sentinel on the main thread wakes
;; up, reads the ID, and safely executes the promise's callbacks.

(defvar concur--thread-callback-pipe nil
  "A pipe used by background threads to send callbacks to the main thread.")

(defvar concur--thread-callback-sentinel-process nil
  "A dummy process whose sentinel listens to `concur--thread-callback-pipe`.")

(defun concur--thread-callback-dispatcher (promise-id)
  "Send a promise ID to be executed on the main Emacs thread via a pipe."
  (when (and concur--thread-callback-pipe
             (process-live-p concur--thread-callback-sentinel-process))
    (process-send-string
     concur--thread-callback-sentinel-process
     (format "%s\n" (json-encode `(:id ,promise-id))))))

(defun concur--process-settled-on-main (promise-id)
  "Look up a promise by ID and trigger its callbacks on the main thread."
  (if-let ((promise (concur-registry-get-promise-by-id promise-id)))
      (let ((callbacks (concur-promise-callbacks promise)))
        (setf (concur-promise-callbacks promise) nil)
        (concur--trigger-callbacks-after-settle promise callbacks))
    (concur--log :warn nil "Main-thread cb: couldn't find promise ID %S"
                 promise-id)))

(defun concur--thread-callback-sentinel (process event)
  "The sentinel that reads and executes callbacks from background threads."
  (when (string-match-p "output" event)
    (with-current-buffer (process-buffer process)
      (let ((json-object-type 'plist))
        (dolist (line (s-split "\n" (buffer-string) t))
          (when-let* ((payload (ignore-errors (json-read-from-string line)))
                      (id (plist-get payload :id)))
            (concur--process-settled-on-main id))))
      (erase-buffer))))

(defun concur--init-thread-signaling ()
  "Initialize the pipe and sentinel for cross-thread communication."
  (when (and (fboundp 'make-thread) (not concur--thread-callback-pipe))
    (setq concur--thread-callback-pipe
          (make-pipe-process :name "concur-thread-pipe"))
    (setq concur--thread-callback-sentinel-process
          (make-process
           :name "concur-thread-sentinel"
           :command '("sleep" "infinity")
           :connection-type 'pipe :noquery t :coding 'utf-8
           :stderr (process-contact concur--thread-callback-pipe :stderr)
           :stdout (process-contact concur--thread-callback-pipe :stdin)))
    (set-process-sentinel concur--thread-callback-sentinel-process
                          #'concur--thread-callback-sentinel)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal State and Schedulers

(defvar concur--macrotask-scheduler nil
  "The global scheduler instance for macrotasks (deferred promise callbacks).")

(defun concur--init-macrotask-queue ()
  "Initialize the global macrotask scheduler if it doesn't exist."
  (unless concur--macrotask-scheduler
    (setq concur--macrotask-scheduler
          (concur-scheduler-create
           :name "concur-macrotask-scheduler"
           :priority-fn #'concur-callback-priority
           :process-fn
           (lambda (batch)
             (when batch
               (concur--log :debug nil "Processing %d macrotasks." (length batch))
               (run-hook-with-args 'concur-resolve-callbacks-begin-hook nil batch)
               (dolist (item batch) (concur-execute-callback item))
               (run-hook-with-args 'concur-resolve-callbacks-end-hook nil batch)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Core Promise Lifecycle

(defun concur--settle-promise (promise result error is-cancellation)
  "The core internal function to settle a promise (resolve or reject).
This function is idempotent and thread-safe.

Arguments:
- `promise` (concur-promise): The promise to settle.
- `result` (any): The value to resolve the promise with.
- `error` (concur-error or nil): The error to reject the promise with.
- `is-cancellation` (boolean): `t` if the settlement is due to cancellation.

Returns:
- `(concur-promise)`: The `promise` that was settled."
  ;; Spec 2.1: A promise must be in one of three states: pending, fulfilled, or rejected.
  ;; Spec 2.1.2: When fulfilled, a promise must not transition to any other state.
  ;; Spec 2.1.3: When rejected, a promise must not transition to any other state.
  (let ((settled-now nil) (callbacks-to-run '()))
    (concur:with-mutex! (concur-promise-lock promise)
      (when (eq (concur-promise-state promise) :pending)
        (setq settled-now t)
        (setf (concur-promise-result promise) result)
        (setf (concur-promise-error promise) error)
        (setf (concur-promise-state promise) (if error :rejected :resolved))
        (setf (concur-promise-cancelled-p promise) is-cancellation)
        ;; Spec 2.2.6: `then` may be called multiple times on the same promise.
        ;; Spec 2.2.6.1: If `promise` is fulfilled, all respective `onFulfilled` callbacks
        ;; must execute in the order of their originating calls to `then`.
        ;; Spec 2.2.6.2: If `promise` is rejected, all respective `onRejected` callbacks
        ;; must execute in the order of their originating calls to `then`.
        ;; By clearing and scheduling, we ensure one-time execution and order.
        (setq callbacks-to-run (concur-promise-callbacks promise))
        (setf (concur-promise-callbacks promise) nil)))

    (when settled-now
      ;; Determine execution context for callbacks.
      ;; Spec 2.2.4: `onFulfilled` or `onRejected` must not be called until the
      ;; execution context stack contains only platform code. (Emacs idle timer/thread for macrotasks)
      (if (and (eq (concur-promise-mode promise) :thread)
               (fboundp 'main-thread)
               (not (equal (current-thread) (main-thread))))
          ;; If in a thread, dispatch to main thread for UI safety.
          (concur--thread-callback-dispatcher (concur-promise-id promise))
        ;; Otherwise, execute in the current thread (typically main).
        (progn
          (concur--trigger-callbacks-after-settle promise callbacks-to-run)
          (when is-cancellation (concur--kill-associated-process promise))))
      ;; Update the global registry.
      (when (fboundp 'concur-registry-update-promise-state)
        (concur-registry-update-promise-state promise))))
  promise)

(defun concur--kill-associated-process (promise)
  "If PROMISE has an associated external process, kill it.
Arguments:
- `promise` (concur-promise): The promise whose process should be killed.
Returns:
- `nil`."
  (when-let ((proc (concur-promise-proc promise)))
    (when (process-live-p proc)
      (concur--log :debug (concur-promise-id promise)
                   "Killing associated process %S." proc)
      (ignore-errors (delete-process proc)))
    (setf (concur-promise-proc promise) nil)))

(defun concur--deferred-rejection-check (promise callback-links)
  "Run the unhandled rejection check for PROMISE via an idle timer.
Arguments:
- `promise` (concur-promise): The promise that settled.
- `callback-links` (list): The original list of callback links."
  ;; Spec 2.2.7.2: If `onRejected` is not a function, it must be ignored.
  ;; Spec 2.2.7.3: If `onRejected` is a function, it must be called after
  ;; `promise` is rejected, with `promise`'s rejection reason as its first argument.
  ;; The unhandled rejection check happens after all handlers have potentially run.
  (concur--handle-unhandled-rejection-if-any promise callback-links))

(defun concur--trigger-callbacks-after-settle (promise callback-links)
  "Called once a promise settles to schedule its callbacks.
This function selects the appropriate callbacks (:resolved or :rejected)
based on the promise's final state and schedules them for execution. This
is critical for Promise/A+ compliance.

Arguments:
- `promise` (concur-promise): The promise that has settled.
- `callback-links` (list): A list of `concur-callback-link` objects."
  (let* ((all-callbacks (-flatten (mapcar #'concur-callback-link-callbacks
                                          callback-links)))
         (state (concur-promise-state promise))
         (type-to-run (if (eq state :resolved) :resolved :rejected))
         (callbacks-to-run
          (-filter (lambda (cb)
                     (let ((type (concur-callback-type cb)))
                       ;; Spec 2.2.7.1: If `onFulfilled` is not a function, it must be ignored.
                       ;; Spec 2.2.7.2: If `onRejected` is not a function, it must be ignored.
                       ;; The filtering ensures only relevant callbacks are scheduled.
                       ;; Special types like :await-latch run on any settlement.
                       (or (eq type type-to-run) (eq type :await-latch))))
                   all-callbacks)))
    (concur--partition-and-schedule-callbacks callbacks-to-run))

  ;; Spec 2.2.4: `onFulfilled` or `onRejected` must not be called until the
  ;; execution context stack contains only platform code. (Idle timer for deferral)
  ;; This ensures microtask/macrotask separation.
  (when (eq (concur-promise-state promise) :rejected)
    (run-with-idle-timer 0 nil #'concur--deferred-rejection-check
                         promise callback-links)))

(defun concur--partition-and-schedule-callbacks (callbacks)
  "Partitions callbacks into microtasks and macrotasks, then schedules them.
Arguments:
- `callbacks` (list): A flat list of `concur-callback` objects to schedule."
  ;; This implements a basic microtask/macrotask queue segregation.
  (let* ((microtasks
          (-filter (lambda (cb) (eq (concur-callback-type cb) :await-latch))
                   callbacks))
         (macrotasks
          (-drop-while (lambda (cb)
                         (eq (concur-callback-type cb) :await-latch))
                       callbacks)))
    ;; Microtasks execute immediately (or as soon as possible after current script).
    (when microtasks (concur:schedule-microtasks microtasks))
    ;; Macrotasks execute in subsequent event loop turns (e.g., idle timer).
    (when macrotasks
      (dolist (cb macrotasks)
        (concur:scheduler-enqueue concur--macrotask-scheduler cb)))))

(defun concur--handle-unhandled-rejection-if-any (promise callback-links)
  "If PROMISE was rejected with no handlers, signals an unhandled rejection.
Arguments:
- `promise` (concur-promise): The promise that settled.
- `callback-links` (list): The callback links that were attached."
  ;; This ensures that unhandled rejections are not silently swallowed.
  ;; This is part of a robust promise implementation, though not a direct
  ;; Promise/A+ requirement (which focuses more on handler invocation).
  (when (and (eq (concur-promise-state promise) :rejected)
             (not (-some (lambda (link)
                           (-some (lambda (cb)
                                    (eq (concur-callback-type cb) :rejected))
                                  (concur-callback-link-callbacks link)))
                         callback-links)))
    (let ((error-obj
           (concur:make-error
            :type :unhandled-rejection
            :message (format "Unhandled rejection: %s"
                             (concur:error-message
                              (concur-promise-error promise)))
            :cause (concur-promise-error promise) :promise promise)))
      (concur--log :warn (concur-promise-id promise)
                   "Unhandled promise rejection: %S" error-obj)
      (push error-obj concur--unhandled-rejections-queue)
      (run-hook-with-args 'concur-unhandled-rejection-hook promise error-obj)
      (when concur-throw-on-promise-rejection
        (signal 'concur-unhandled-rejection
                (list (concur:error-message error-obj) error-obj))))))

(defun concur-current-async-stack-string ()
  "Format `concur--current-async-stack` into a readable string.
Returns:
- `(string or nil)`: The formatted async stack trace, or `nil` if empty."
  (when concur--current-async-stack
    (mapconcat #'identity (reverse concur--current-async-stack) "\n↳ ")))

(defun concur-execute-callback (callback)
  "Executes a stored callback with its source promise's result.
This function is called by the schedulers. It retrieves the source
and target promises from the registry by their IDs, then invokes
the handler closure with the appropriate arguments (value for
resolved, error for rejected).

Arguments:
- `callback` (concur-callback): The callback struct to execute.

Returns:
- `nil`. The return value of the handler settles the *next* promise
  in a chain, which is handled within the closure itself."
  (condition-case-unless-debug err
      (let* ((handler-fn (concur-callback-handler-fn callback))
             (source-promise (concur-registry-get-promise-by-id
                              (concur-callback-source-promise-id callback)))
             ;; Get the target promise that the handler will settle.
             (target-promise (concur-registry-get-promise-by-id
                              (concur-callback-promise-id callback)))
             (arg-value (if (concur:rejected-p source-promise)
                            (concur:error-value source-promise)
                          (concur:value source-promise))))

        (unless (functionp handler-fn)
          (error "Invalid callback handler stored in promise: %S" handler-fn))

        ;; --- Argument Dispatch Logic (Promises/A+ Spec 2.2.5) ---
        ;; This section ensures that `onFulfilled` and `onRejected` are called
        ;; as functions with `value` or `reason` as their first argument.
        ;; For internal Concur design, :resolved and :rejected handlers are
        ;; specifically wrappers designed to take (target-promise value/error).
        (pcase (concur-callback-type callback)
          ((or :resolved :rejected)
           ;; These are the internal wrappers from `concur:then`
           ;; which are defined to accept 2 arguments: (target-promise value/error).
           (funcall handler-fn target-promise arg-value))
          (:await-latch
           ;; This is the internal await latch callback, defined for 1 argument.
           (funcall handler-fn arg-value))
          (_
           ;; Fallback for any other unexpected type, or for future types.
           ;; This case should ideally not be hit for core functionality.
           (concur--log :warn (concur-promise-id target-promise)
                        "Unknown callback type %S for handler. Attempting 1-arg funcall."
                        (concur-callback-type callback))
           (funcall handler-fn arg-value))))
        ;; --- End Argument Dispatch Logic ---
    (error
     (let* ((target-promise (concur-registry-get-promise-by-id
                             (concur-callback-promise-id callback)))
            (err-msg (format "Callback failed: %s" (car-safe err))))
       (concur--log :error (concur-promise-id target-promise) "%s" err-msg)
       (concur:reject
        target-promise
        (concur:make-error :type :callback-error
                           :message err-msg
                           :cause err
                           :promise target-promise))))))

(defun concur-attach-callbacks (promise &rest callbacks)
  "Attach a set of callbacks to a PROMISE.
Arguments:
- `promise` (concur-promise): The promise to attach callbacks to.
- `callbacks` (rest `concur-callback`): A list of `concur-callback` structs.
Returns:
- `(concur-promise)`: The original `promise`."
  ;; Spec 2.2.6: `then` may be called multiple times on the same promise.
  ;; If the promise is still pending, add callbacks to its list.
  ;; If already settled, schedule them immediately.
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error
            (list "concur-attach-callbacks expected a promise" promise)))
  (let* ((non-nil-callbacks (-filter #'identity callbacks))
         (link (%%make-callback-link :id (gensym "link-")
                                     :callbacks non-nil-callbacks)))
    (concur:with-mutex! (concur-promise-lock promise)
      (if (eq (concur-promise-state promise) :pending)
          (push link (concur-promise-callbacks promise))
        ;; If already settled, schedule callbacks asynchronously now.
        ;; Spec 2.2.6.1 & 2.2.6.2: All handlers must execute in order.
        (concur--trigger-callbacks-after-settle promise (list link)))))
  promise)

(defun concur-attach-then-callbacks (source-promise target-promise on-resolved on-rejected)
  "The internal function for attaching `then` callbacks.
It links a SOURCE-PROMISE to a TARGET-PROMISE via the handlers."
  (let ((source-id (concur-promise-id source-promise))
        (target-id (concur-promise-id target-promise)))
    (concur-attach-callbacks
     source-promise
     (when on-resolved
       (%%make-callback :type :resolved
                        :handler-fn on-resolved
                        :priority 50
                        :promise-id target-id
                        :source-promise-id source-id))
     (when on-rejected
       (%%make-callback :type :rejected
                        :handler-fn on-rejected
                        :priority 50
                        :promise-id target-id
                        :source-promise-id source-id)))
    source-promise))

(defun concur--await-blocking (promise timeout)
  "The cooperative blocking implementation for `concur:await`.

Arguments:
- `promise` (concur-promise): The promise to await.
- `timeout` (number or nil): Max seconds to wait.

Returns:
  The resolved value of the promise. Signals an error on
  rejection/timeout."
  ;; Use a named block to allow for non-local return on success.
  (cl-block concur--await-blocking
    ;; --- Early Exit Optimization ---
    (when (not (eq (concur:status promise) :pending))
      (if-let ((err (concur:error-value promise)))
          (signal 'concur-await-error (list (concur:error-message err) err))
        (cl-return-from concur--await-blocking (concur:value promise))))

    ;; --- Setup for Blocking Wait ---
    (let ((latch (%%make-await-latch))
          (timer nil))

      (unwind-protect
          (progn
            ;; Attach a high-priority callback to signal the latch.
            (let* ((id (concur-promise-id promise))
                   (latch-signaler-fn
                    (lambda (_val-or-err)
                      (setf (concur-await-latch-signaled-p latch) t)
                      (when-let ((cv (concur-await-latch-cond-var latch)))
                        (condition-notify cv))))
                   (latch-callback (%%make-callback
                                    :type :await-latch
                                    :priority 0
                                    :handler-fn latch-signaler-fn
                                    :promise-id id
                                    :source-promise-id id)))
              (concur-attach-callbacks promise latch-callback))

            ;; Set up a timer to race against the promise.
            (when timeout
              (setq timer
                    (run-at-time
                     timeout nil
                     (lambda ()
                       (unless (concur-await-latch-signaled-p latch)
                         (setf (concur-await-latch-signaled-p latch)
                               'timeout))))))

            ;; --- Blocking/Yielding Mechanism ---
            (if (eq (concur-promise-mode promise) :thread)
                ;; For native threads, use a condition variable.
                (let* ((lock (concur-promise-lock promise))
                       (cond-var (make-condition-variable
                                  (concur-lock-native-mutex lock))))
                  (setf (concur-await-latch-cond-var latch) cond-var)
                  ;; The `with-mutex!` macro acquires the native mutex.
                  (concur:with-mutex! lock
                    (while (not (concur-await-latch-signaled-p latch))
                      ;; FIX: `condition-wait` takes only the condition
                      ;; variable as its argument in this API version.
                      (condition-wait cond-var))))
              ;; For the main thread, use cooperative polling.
              (while (not (concur-await-latch-signaled-p latch))
                (sit-for concur-await-poll-interval)))

            ;; --- Determine Final Outcome ---
            (cond
             ((eq (concur-await-latch-signaled-p latch) 'timeout)
              (signal 'concur-timeout-error
                      (list (format "Await timed out for %S"
                                    (concur:format-promise promise)))))
             ((concur:rejected-p promise)
              (signal 'concur-await-error
                      (list (concur:error-message promise)
                            (concur:error-value promise))))
             (t
              (concur:value promise))))

        ;; --- Cleanup ---
        (when timer (cancel-timer timer))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Promise Construction and State Transition

;;;###autoload
(cl-defun concur:make-promise (&key
                               (mode :deferred)
                               name
                               cancel-token
                               parent-promise)
  "Create a new, pending `concur-promise`.
Arguments:
- `:mode` (symbol): Concurrency mode (`:deferred`, `:thread`, or `:async`).
- `:name` (string): A descriptive name for debugging and registry.
- `:cancel-token` (concur-cancel-token): An optional cancel token.
- `:parent-promise` (concur-promise): The promise that created this one.
Returns:
- `(concur-promise)`: A new promise in the `:pending` state."
  (let* ((id (gensym (or name "promise-")))
         (lock-mode (if (eq mode :thread) :thread :deferred))
         (p (%%make-promise
             :id id :mode mode
             :lock (concur:make-lock (format "promise-lock-%S" id)
                                     :mode lock-mode)
             :cancel-token cancel-token)))
    (when (fboundp 'concur-registry-register-promise)
      (concur-registry-register-promise p (or name (symbol-name id))
                                        :parent-promise parent-promise))
    (when (and cancel-token (fboundp 'concur-cancel-token-add-callback))
      (concur-cancel-token-add-callback
       cancel-token (lambda () (concur:cancel p))))
    p))

;;;###autoload
(defun concur:resolve (promise value)
  "Resolve a PROMISE with a given VALUE.
This implements the Promises/A+ Resolution Procedure (Spec 2.3).
If VALUE is a promise (a 'thenable'), the original PROMISE will adopt its state.
This operation is idempotent.

Arguments:
- `promise` (concur-promise): The promise to resolve.
- `value` (any): The value to resolve the promise with.

Returns:
- `(concur-promise)`: The original `promise`."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
  ;; Spec 2.3.1: A promise cannot be resolved with itself.
  (if (eq promise value)
      (concur:reject
       promise (concur:make-error
                :type :type-error
                :message "Promise cannot resolve with itself: cycle detected."))
    (let ((normalized-value
           (if (eq (type-of value) 'concur-promise)
               value
             (run-hook-with-args-until-success
              'concur-normalize-awaitable-hook value))))
      ;; Spec 2.3.2: If value is a promise (or thenable normalized to one), adopt its state.
      (if (eq (type-of normalized-value) 'concur-promise)
          (progn
            (concur--log :debug (concur-promise-id promise)
                         "Chaining to promise %S (Spec 2.3.2)."
                         (concur-promise-id normalized-value))
            ;; Spec 2.3.2.1: If `value` is pending, `promise` must remain pending
            ;; until `value` is fulfilled or rejected.
            ;; Spec 2.3.2.2: If/when `value` is fulfilled, fulfill `promise` with the same value.
            ;; Spec 2.3.2.3: If/when `value` is rejected, reject `promise` with the same reason.
            (concur-attach-then-callbacks
                      normalized-value ; The source promise we're listening to.
                      promise          ; The target promise to settle.
                      (lambda (_target-p res) (concur:resolve promise res))
                      (lambda (_target-p err) (concur:reject promise err))))
        ;; Spec 2.3.3: If value is an object or function (not a promise), it might be a "thenable".
        ;; This step is implicitly handled by `concur-normalize-awaitable-hook`.
        ;; If it's not a promise and not a recognized thenable, then:
        ;; Spec 2.3.4: If value is not an object or function, fulfill `promise` with `value`.
        (concur--settle-promise promise value nil nil))))
  promise)

;;;###autoload
(defun concur:reject (promise error)
  "Reject a PROMISE with a given ERROR.
Arguments:
- `promise` (concur-promise): The promise to reject.
- `error` (any): The reason for the rejection. Will be wrapped in a
  `concur-error` struct if it isn't one already.
Returns:
- `(concur-promise)`: The original `promise`."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
  ;; Spec 2.1.3: When rejected, a promise must transition to a rejected state with a reason.
  ;; Spec 2.1.3.1: It must not transition to any other state.
  ;; Spec 2.1.3.2: It must have a reason, which must not change.
  (let* ((is-cancellation (and (eq (type-of error) 'concur-error)
                               (eq (concur-error-type error) :cancel)))
         (final-error
          (if (eq (type-of error) 'concur-error)
              error
            (concur:make-error
             :type (if is-cancellation :cancel :generic)
             :message (if (stringp error) error (format "%S" error))
             :cause error :promise promise))))
    (when (and concur--current-async-stack
               (not (concur-error-async-stack-trace final-error)))
      (setf (concur-error-async-stack-trace final-error)
            (concur-current-async-stack-string)))
    (concur--log :debug (concur-promise-id promise)
                 "Rejecting with error: %S" final-error)
    (concur--settle-promise promise nil final-error is-cancellation)))

;;;###autoload
(defun concur:resolved! (value &rest keys)
  "Create and return a new promise that is already resolved with VALUE.
Arguments:
- `value` (any): The value for the new promise.
- `keys` (plist): Options for `concur:make-promise` like `:mode` and `:name`.
Returns:
- `(concur-promise)`: A new promise in the `:resolved` state."
  (let ((p (apply #'concur:make-promise keys)))
    (concur:resolve p value)))

;;;###autoload
(defun concur:rejected! (error &rest keys)
  "Create and return a new promise that is already rejected with ERROR.
Arguments:
- `error` (any): The error for the new promise.
- `keys` (plist): Options for `concur:make-promise` like `:mode` and `:name`.
Returns:
- `(concur-promise)`: A new promise in the `:rejected` state."
  (let ((p (apply #'concur:make-promise keys)))
    (concur:reject p error)))

;;;###autoload
(defun concur:cancel (promise &optional reason)
  "Cancel a pending PROMISE.
Arguments:
- `promise` (concur-promise): The promise to cancel.
- `reason` (string, optional): A message explaining the cancellation.
Returns:
- `nil`."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
  (when (eq (concur:status promise) :pending)
    (concur--log :info (concur-promise-id promise)
                 "Cancelling (Reason: %s)." (or reason "N/A"))
    (concur:reject promise
                   (concur:make-error
                    :type :cancel
                    :message (or reason "Promise cancelled")
                    :promise promise))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;    
;;; Error Handling & Serialization

(defun concur:make-error (&rest user-args)
  "Create a new `concur-error` struct, capturing contextual information.

This function intelligently builds an error object. If the `:cause`
is another `concur-error`, its properties are inherited. Explicitly
provided arguments in `USER-ARGS` always take precedence.

Arguments:
- `USER-ARGS` (plist): Key-value pairs for `concur-error` fields.

Returns:
- A new, populated `concur-error` struct."
  (let* ((cause (plist-get user-args :cause))
         (args (copy-sequence user-args))
         (defaults
          `(:message "An unspecific Concur error occurred."
            :async-stack-trace ,(concur-current-async-stack-string))))
    ;; 1. Inherit fields from cause if it's a concur-error
    (when (concur-error-p cause)
      (dolist (slot '(type message stderr))
        (let* ((key (intern (format ":%s" slot)))
               (val (funcall (intern (format "concur-error-%s" slot)) cause)))
          ;; Only inherit if the user hasn't provided an override
          (when (and val (not (plist-member args key)))
            (setq args (plist-put args key val))))))
    ;; 2. Apply defaults for any fields that are still missing
    (setq args (append args defaults))
    ;; 3. Construct the final error object
    (apply #'%%make-concur-error args)))

(defun concur:serialize-error (err)
  "Serialize a `concur-error` struct into a plist.

This plist can then be safely encoded as JSON for IPC.

Arguments:
- `ERR` (concur-error): The error object to serialize.

Returns:
- A plist representation of the error."
  (cl-loop with slots = '(type message cause promise async-stack-trace stderr)
           for slot-name in slots
           for value = (funcall (intern (format "concur-error-%s" slot-name)) err)
           when value
           collect (intern (format ":%s" slot-name))
           collect value))

(defun concur:deserialize-error (plist)
  "Deserialize a plist back into a `concur-error` struct.

Arguments:
- `PLIST`: A property list created by `concur:serialize-error`.

Returns:
- A new `concur-error` struct."
  (apply #'%%make-concur-error plist))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Promise Status and Value Introspection

;;;###autoload
(defun concur:status (promise)
  "Return current state of a PROMISE without blocking.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (symbol): The state (`:pending`, `:resolved`, or `:rejected`)."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
  (concur-promise-state promise))

;;;###autoload
(defun concur:pending-p (promise)
  "Return non-nil if PROMISE is pending.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (boolean): `t` if pending, `nil` otherwise."
  (eq (concur:status promise) :pending))

;;;###autoload
(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has resolved successfully.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (boolean): `t` if resolved, `nil` otherwise."
  (eq (concur:status promise) :resolved))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE was rejected.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (boolean): `t` if rejected, `nil` otherwise."
  (eq (concur:status promise) :rejected))

;;;###autoload
(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE was cancelled.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (boolean): `t` if cancelled, `nil` otherwise."
  (concur-promise-cancelled-p promise))

;;;###autoload
(defun concur:value (promise)
  "Return resolved value of PROMISE, or nil if not resolved. Non-blocking.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (any): The resolved value, or `nil` if not in the `:resolved` state."
  (when (concur:resolved-p promise)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return error of PROMISE if rejected, else nil. Non-blocking.
Arguments:
- `promise` (concur-promise): The promise to inspect.
Returns:
- (concur-error or nil): The rejection error object, or `nil`."
  (when (concur:rejected-p promise)
    (concur-promise-error promise)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return human-readable message from a promise's error or an error object.
Arguments:
- `promise-or-error` (concur-promise or concur-error): The item to inspect.
Returns:
- (string): A descriptive error message."
  (let ((err (if (eq (type-of promise-or-error) 'concur-promise)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (if (eq (type-of err) 'concur-error)
        (concur-error-message err)
      (format "%S" err))))

;;;###autoload
(defun concur:format-promise (p)
  "Return human-readable string representation of a promise.
Arguments:
- `p` (concur-promise): The promise to format.
Returns:
- (string): A descriptive string including ID, mode, state, and name."
  (unless (eq (type-of p) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" p)))
  (let* ((id (concur-promise-id p))
         (mode (concur-promise-mode p))
         (status (concur:status p))
         (name (if (fboundp 'concur-registry-get-promise-name)
                   (concur-registry-get-promise-name p (symbol-name id))
                 (symbol-name id))))
    (pcase status
      (:pending (format "#<Promise %s (%s) %s: pending>" name id mode))
      (:resolved
       (format "#<Promise %s (%s) %s: resolved with %s>" name id mode
               (s-truncate concur-log-value-max-length
                           (format "%S" (concur:value p)))))
      (:rejected
       (format "#<Promise %s (%s) %s: rejected with %s>" name id mode
               (s-truncate concur-log-value-max-length
                           (concur:error-message p)))))))

(defun concur-unhandled-rejections-count ()
  "Return the number of unhandled promise rejections currently queued.
Returns:
- `(integer)`: The count of unhandled rejections."
  (length concur--unhandled-rejections-queue))

(defun concur-get-unhandled-rejections ()
  "Return and clear the list of all currently tracked unhandled rejections.
Returns:
- `(list)`: A list of `concur-error` objects, oldest first."
  (prog1 (nreverse concur--unhandled-rejections-queue)
    (setq concur--unhandled-rejections-queue '())))

(defun concur-has-unhandled-rejections-p ()
  "Return non-nil if there are any unhandled promise rejections queued.
Returns:
- `(boolean)`: `t` if unhandled rejections exist, `nil` otherwise."
  (not (null concur--unhandled-rejections-queue)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Attaching Callbacks & Awaiting

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
If called within a `coroutine`, it will yield instead of blocking.
Otherwise, it blocks the thread (cooperatively on main thread).

Arguments:
- `promise-form` (form): A form that evaluates to a `concur-promise`.
- `timeout` (number, optional): Seconds to wait before timing out. Defaults to
  `concur-await-default-timeout`.

Returns:
- The resolved value of the promise.

Signals:
- `concur-await-error` if the promise rejects.
- `concur-timeout-error` if the timeout is exceeded.
- `concur-type-error` if `promise-form` doesn't yield an awaitable."
  (declare (indent 1) (debug t))
  `(let* ((p-val ,promise-form)
          (p (run-hook-with-args-until-success
              'concur-normalize-awaitable-hook p-val)))
     (unless p (setq p p-val))

     (unless (eq (type-of p) 'concur-promise)
       (signal 'concur-type-error
               (list "await expected a promise or awaitable" p)))

     (if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
         (if (eq (concur:status p) :pending)
             (yield--internal-throw-form
              p ',concur--coroutine-yield-throw-tag)
           (if-let ((err (concur:error-value p)))
               (signal 'concur-await-error
                       (list (concur:error-message err) err))
             (concur:value p)))
       (concur--await-blocking p (or ,timeout
                                     concur-await-default-timeout)))))

;;;###autoload
(defmacro concur:with-executor (executor-fn-form &rest opts)
  "Run an asynchronous block with a user-supplied EXECUTOR-FN-FORM.
The executor function is a lambda `(lambda (resolve reject) ...)` where
`resolve` and `reject` are functions that control the returned promise.

Arguments:
- `executor-fn-form` (form): The lambda to execute.
- `opts` (plist): A plist passed to `concur:make-promise`.

Returns:
- `(concur-promise)`: A new promise controlled by the executor."
  (declare (indent 1) (debug t))
  (let* ((promise-sym (gensym "promise-"))
         (resolve-sym (gensym "resolve-"))
         (reject-sym (gensym "reject-")))
    `(let* ((,promise-sym (apply #'concur:make-promise ',opts))
            (,resolve-sym (lambda (v) (concur:resolve ,promise-sym v)))
            (,reject-sym  (lambda (e) (concur:reject  ,promise-sym e))))
       (let ((concur-resource-tracking-function
              (lambda (action resource)
                (pcase action
                  (:acquire (concur-registry-register-resource-hold
                             ,promise-sym resource))
                  (:release (concur-registry-release-resource-hold
                             ,promise-sym resource))))))
         (condition-case err
             (progn
               (concur--log :debug (concur-promise-id ,promise-sym)
                            "Executing executor for promise.")
               ;; Spec 2.3.3: `resolve` or `reject` must be called at most once.
               ;; The executor function will be invoked with `resolve` and `reject` functions.
               (funcall ,executor-fn-form ,resolve-sym ,reject-sym))
           (error
            (let ((err-msg (format "Executor failed: %S" err)))
              (concur--log :error (concur-promise-id ,promise-sym) "%s" err-msg)
              (concur:reject
               ,promise-sym
               (concur:make-error :type :executor-error
                                  :message err-msg :cause err
                                  :promise ,promise-sym))))))
       ,promise-sym)))

;; Initialize critical infrastructure on library load.
(concur--init-thread-signaling)
(concur--init-macrotask-queue)

(provide 'concur-core)
;;; concur-core.el ends here