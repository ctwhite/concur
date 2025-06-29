;;; concur-core.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file defines the `concur-promise`, the fundamental data structure
;; of the Concur library. It implements the core logic for creating, resolving,
;; and rejecting promises, adhering closely to the Promise/A+ specification.
;;
;; Architectural Highlights:
;; - Promise/A+ Compliant: Implements the promise resolution procedure, state
;;   machine, and asynchronous callback scheduling required by the spec.
;; - Thread-Safety: All promise state mutations are protected by a `concur-lock`,
;;   allowing promises to be safely settled from background threads.
;; - Concurrency Modes: Promises can operate in different modes (`:deferred`,
;;   `:thread`) which determine the type of lock used and how callbacks are
;;   scheduled, enabling safe interaction with the main Emacs thread.
;; - Extensibility: A hook-based system (`concur-normalize-awaitable-hook`)
;;   allows for seamless integration with other asynchronous constructs.
;; - Rich Error Handling: A standardized `concur-error` struct provides
;;   detailed contextual information for rejected promises, including
;;   asynchronous stack traces.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 's)

(require 'concur-log)
(require 'concur-lock)
(require 'concur-scheduler)
(require 'concur-microtask)
(require 'concur-registry)
(require 'coroutines)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward Declarations

(declare-function concur:then "concur-chain")
(declare-function concur-cancel-token-p "concur-cancel")
(declare-function concur-cancel-token-add-callback "concur-cancel")
(declare-function concur-registry-get-promise-by-id "concur-registry")
(declare-function concur-registry-register-promise "concur-registry")
(declare-function concur-registry-update-promise-state "concur-registry")
(declare-function concur-registry-register-resource-hold "concur-registry")
(declare-function concur-registry-release-resource-hold "concur-registry")
(declare-function concur-registry-get-promise-name "concur-registry")
(declare-function concur:schedule-microtasks "concur-microtask")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Group & Customization Variables

(defgroup concur nil "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defcustom concur-log-value-max-length 100
  "Maximum length of a value/error string in log messages before truncation."
  :type 'integer
  :group 'concur)

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, signal a `concur-unhandled-rejection` error.
When a promise is rejected and has no rejection handlers attached,
this controls whether to signal an error immediately. If `nil`,
unhandled rejections are queued for later inspection without
halting execution."
  :type 'boolean
  :group 'concur)

(defcustom concur-await-poll-interval 0.01
  "The polling interval (in seconds) for `concur:await` blocking.
This applies when awaiting on the main thread, defining the frequency
of the cooperative, non-blocking wait loop."
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
  "Hook to normalize arbitrary objects into `concur-promise`s.
Functions on this hook receive one argument (the object to check)
and should return a `concur-promise` if they can handle it, or `nil`."
  :type 'hook
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Error Definitions

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
  "An error occurred within a promise callback." 'concur-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Data Structures

(cl-defstruct (concur-promise (:constructor %%make-promise) (:copier nil))
  "Represents the eventual result of an asynchronous operation.
This is the central data structure of the library. Its fields
should not be manipulated directly; use the public API functions.

Fields:
- `id` (symbol): A unique identifier for logging and debugging.
- `result` (any): The final value of a resolved promise.
- `error` (concur-error): The final error of a rejected promise.
- `state` (symbol): The current state: `:pending`, `:resolved`, or `:rejected`.
- `callbacks` (list): A list of `concur-callback-link` structs.
- `cancel-token` (concur-cancel-token, optional): For cancellation.
- `cancelled-p` (boolean): `t` if rejection was due to cancellation.
- `proc` (process or nil): An optional associated external process.
- `lock` (concur-lock): A mutex protecting fields from concurrent access.
- `mode` (symbol): Concurrency mode (`:deferred`, `:thread`, or `:async`)."
  id result error (state :pending) callbacks cancel-token cancelled-p proc lock
  (mode :deferred))

(cl-defstruct (concur-callback (:constructor %%make-callback) (:copier nil))
  "An internal struct encapsulating a callback function and its context.

Fields:
- `type` (symbol): The type of handler: `:resolved`, `:rejected`, `:await-latch`.
- `handler-fn` (function): The closure to be executed.
- `target-promise` (concur-promise): The promise to be settled by this handler.
- `source-promise` (concur-promise): The promise providing input.
- `priority` (integer): Execution priority (lower is higher)."
  type handler-fn target-promise source-promise (priority 50))

(cl-defstruct (concur-callback-link (:constructor %%make-callback-link)
                                    (:copier nil))
  "Groups related callbacks from a single `then` call.

Fields:
- `id` (symbol): A unique ID for debugging this link.
- `callbacks` (list): A list of `concur-callback` structs."
  id callbacks)

(cl-defstruct (concur-error (:constructor %%make-concur-error) (:copier nil))
  "A standardized error object for rich, introspectable promise rejections.

Fields:
- `type` (keyword): A keyword identifying the error category.
- `message` (string): A human-readable error message.
- `cause` (any): The original Lisp error or reason for this error.
- `promise` (concur-promise): The promise that rejected.
- `async-stack-trace` (string): A formatted async/Lisp backtrace.
- `...` (any): Additional fields for process-related errors."
  (type :generic) message (cause nil) promise async-stack-trace cmd args cwd
  exit-code signal process-status stdout stderr)

(cl-defstruct (concur-await-latch (:constructor %%make-await-latch)
                                  (:copier nil))
  "Internal latch for the `concur:await` blocking mechanism.
This acts as a shared flag between a waiting call and the promise
callback that signals completion.

Fields:
- `signaled-p` (boolean or `timeout`): The flag indicating completion.
- `cond-var` (condition-variable): For efficient blocking in threads."
  signaled-p cond-var)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Global State & Context

(defvar concur--coroutine-yield-throw-tag nil
  "Internal variable for `coroutines.el` integration.
Used by `concur:await` to yield control via a `throw`.")

(defvar concur--current-promise-context nil
  "Dynamically bound to the promise currently being processed.")

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.")

(defvar concur--unhandled-rejections-queue '()
  "A list of unhandled `concur-error` objects for later inspection.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Thread-Safe Signaling Mechanism

(defvar concur--thread-callback-pipe nil
  "A pipe used by background threads to notify the main thread.")

(defvar concur--thread-callback-sentinel-process nil
  "A dummy process whose sentinel listens to `concur--thread-callback-pipe`.")

(defun concur--thread-callback-dispatcher (promise-id)
  "Send a promise ID to be executed on the main Emacs thread via a pipe.
This function is safe to call from any background thread.

Arguments:
- `promise-id` (symbol): The ID of the promise that has settled.

Returns:
- `nil`."
  (when (and concur--thread-callback-pipe
             (process-live-p concur--thread-callback-sentinel-process))
    (process-send-string
     concur--thread-callback-sentinel-process
     (format "(concur--process-settled-on-main '%S)\n" promise-id))))

(defun concur--process-settled-on-main (promise-id)
  "Look up a promise by ID and trigger its callbacks.
This function is always executed on the main thread via the sentinel.

Arguments:
- `promise-id` (symbol): The ID of the settled promise."
  (if-let ((promise (concur-registry-get-promise-by-id promise-id)))
      (let ((callbacks-to-run (concur-promise-callbacks promise)))
        (setf (concur-promise-callbacks promise) nil) ; Prevent re-execution.
        (concur--trigger-callbacks-after-settle promise callbacks-to-run)
        (when (concur-promise-cancelled-p promise)
          (concur--kill-associated-process promise)))
    (concur--log :warn nil "Main-thread cb: couldn't find promise ID %S."
                 promise-id)))

(defun concur--thread-callback-sentinel (process event)
  "The sentinel that reads and evaluates callbacks from background threads.

Arguments:
- `process` (process): The sentinel process object.
- `event` (string): The event string (e.g., \"output\")."
  (when (string-match-p "output" event)
    (with-current-buffer (process-buffer process)
      (dolist (line (s-split "\n" (buffer-string) t))
        (ignore-errors (eval (read line))))
      (erase-buffer))))

(defun concur--init-thread-signaling ()
  "Initialize the pipe and sentinel for cross-thread communication."
  (when (and (fboundp 'make-thread) (not concur--thread-callback-pipe))
    (concur--log :debug nil "Initializing thread signaling mechanism.")
    (setq concur--thread-callback-pipe
          (make-pipe-process :name "concur-thread-pipe"))
    (setq concur--thread-callback-sentinel-process
          (make-process
           :name "concur-thread-sentinel"
           :command (list (executable-find "emacs") "--batch" "-l" "-"
                          "--eval" "(while t (sleep-for 3600))")
           :connection-type 'pipe :noquery t :coding 'utf-8
           :stderr (process-contact concur--thread-callback-pipe :stderr)
           :stdout (process-contact concur--thread-callback-pipe :stdin)))
    (set-process-sentinel concur--thread-callback-sentinel-process
                          #'concur--thread-callback-sentinel)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Callback Scheduling

(defvar concur--macrotask-scheduler nil
  "The global scheduler for macrotasks (standard promise callbacks).")

(defun concur--init-macrotask-queue ()
  "Initialize the global macrotask scheduler if it doesn't exist."
  (unless concur--macrotask-scheduler
    (setq concur--macrotask-scheduler
          (concur-scheduler-create
           :name "concur-macrotask-scheduler"
           :process-fn #'concur--process-macrotask-batch
           :priority-fn #'concur-callback-priority))))

(defun concur--process-macrotask-batch (batch)
  "Execute a BATCH of callbacks from the macrotask scheduler.

Arguments:
- `batch` (list): A list of `concur-callback` objects to execute."
  (when batch
    (concur--log :debug nil "Processing %d macrotasks." (length batch))
    (run-hook-with-args 'concur-resolve-callbacks-begin-hook batch)
    (dolist (item batch) (concur-execute-callback item))
    (run-hook-with-args 'concur-resolve-callbacks-end-hook batch)))

(defun concur--schedule-macrotasks (callbacks)
  "Add a list of callbacks to the macrotask scheduler.

Arguments:
- `callbacks` (list): A list of `concur-callback` objects to schedule."
  (dolist (cb callbacks)
    (concur:scheduler-enqueue concur--macrotask-scheduler cb)))

(defun concur--partition-and-schedule-callbacks (callbacks)
  "Partitions callbacks into microtasks and macrotasks, then schedules them.
Microtasks (like `await` latches) must run immediately, while standard
callbacks (macrotasks) run on the next tick of the event loop.

Arguments:
- `callbacks` (list): A flat list of `concur-callback` objects to schedule."
  (let ((microtasks (-filter (lambda (cb)
                               (eq (concur-callback-type cb) :await-latch))
                             callbacks))
        (macrotasks (-filter (lambda (cb)
                               (not (eq (concur-callback-type cb)
                                        :await-latch)))
                             callbacks)))
    (when microtasks (concur:schedule-microtasks microtasks))
    (when macrotasks (concur--schedule-macrotasks macrotasks))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Core Promise Lifecycle & State Machine

(defun concur--settle-promise (promise result error is-cancellation)
  "The core internal function to settle a promise (resolve or reject).
This function is idempotent and thread-safe. Once a promise is settled,
subsequent calls have no effect.

Arguments:
- `promise` (concur-promise): The promise to settle.
- `result` (any): The resolution value (if not rejecting).
- `error` (concur-error): The rejection error (if not resolving).
- `is-cancellation` (boolean): `t` if this is due to cancellation.

Returns:
- `(concur-promise)`: The `promise` that was settled."
  (let (settled-now callbacks-to-run)
    (concur:with-mutex! (concur-promise-lock promise)
      ;; Promise/A+ Spec 2.1: A promise must be in one of three states.
      ;; This `when` block ensures the transition from :pending is atomic.
      (when (eq (concur-promise-state promise) :pending)
        (setq settled-now t)
        (setf (concur-promise-result promise) result)
        (setf (concur-promise-error promise) error)
        (setf (concur-promise-state promise) (if error :rejected :resolved))
        (setf (concur-promise-cancelled-p promise) is-cancellation)
        (setq callbacks-to-run (concur-promise-callbacks promise))
        (setf (concur-promise-callbacks promise) nil))) ; Clear callbacks inside lock

    (when settled-now
      (if (and (eq (concur-promise-mode promise) :thread)
               (fboundp 'main-thread) (not (eq (current-thread) (main-thread))))
          (concur--thread-callback-dispatcher (concur-promise-id promise))
        (progn
          (concur--trigger-callbacks-after-settle promise callbacks-to-run)
          (when is-cancellation (concur--kill-associated-process promise))))
      (when (fboundp 'concur-registry-update-promise-state)
        (concur-registry-update-promise-state promise))))
  promise)

(defun concur--trigger-callbacks-after-settle (promise callback-links)
  "Selects and schedules the appropriate callbacks after a promise settles.
This function is critical for Promise/A+ compliance, ensuring that only
the correct callbacks (:resolved or :rejected) are executed.

Arguments:
- `promise` (concur-promise): The promise that has settled.
- `callback-links` (list): A list of `concur-callback-link` objects."
  (let* ((state (concur-promise-state promise))
         (type-to-run (if (eq state :resolved) :resolved :rejected))
         (all-callbacks (-flatten
                         (mapcar #'concur-callback-link-callbacks
                                 callback-links)))
         (callbacks-to-run
          (-filter (lambda (cb)
                     (let ((type (concur-callback-type cb)))
                       (or (eq type type-to-run)
                           (eq type :await-latch))))
                   all-callbacks)))
    ;; Promise/A+ Spec 2.2.4: Callbacks must not be called before the
    ;; execution context stack is empty. Our schedulers ensure this.
    (concur--partition-and-schedule-callbacks callbacks-to-run))

  ;; Check for unhandled rejections asynchronously.
  (when (eq (concur-promise-state promise) :rejected)
    (run-with-idle-timer
     0 nil #'concur--handle-unhandled-rejection-if-any promise callback-links)))

(defun concur-execute-callback (callback)
  "Executes a stored callback with its source promise's result or error.
This is the heart of the callback execution logic, called by schedulers.

Arguments:
- `callback` (concur-callback): The callback struct to execute.

Returns:
- `nil`. The return value of the handler settles the *next* promise in the
  chain, which is handled internally."
  (condition-case-unless-debug err
      (let* ((handler-fn (concur-callback-handler-fn callback))
             (source-promise (concur-callback-source-promise callback))
             (target-promise (concur-callback-target-promise callback))
             (arg (if (concur:rejected-p source-promise)
                      (concur:error-value source-promise)
                    (concur:value source-promise))))
        (unless (functionp handler-fn)
          (error "Invalid callback handler stored: %S" handler-fn))
        (funcall handler-fn arg))
    (error
     (let* ((target-promise (concur-callback-target-promise callback))
            (err-msg (format "Callback failed: %s" (car-safe err))))
       (concur--log :error (concur-promise-id target-promise) "%s" err-msg)
       (concur:reject
        target-promise
        (concur:make-error :type :callback-error :message err-msg
                           :cause err :promise target-promise))))))

(defun concur-attach-callbacks (promise &rest callbacks)
  "Attach a list of `concur-callback` structs to a PROMISE.
If the promise is already settled, the callbacks are scheduled immediately.

Arguments:
- `promise` (concur-promise): The promise to attach callbacks to.
- `callbacks` (rest `concur-callback`): The callbacks to attach.

Returns:
- `(concur-promise)`: The original `promise`."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
  (let* ((non-nil-callbacks (-filter #'identity callbacks))
         (link (%%make-callback-link :id (gensym "link-")
                                     :callbacks non-nil-callbacks)))
    (concur:with-mutex! (concur-promise-lock promise)
      (if (eq (concur-promise-state promise) :pending)
          (push link (concur-promise-callbacks promise))
        ;; If already settled, trigger asynchronously now.
        (concur--trigger-callbacks-after-settle promise (list link)))))
  promise)

(defun concur-attach-then-callbacks (source-promise target-promise
                                     on-resolved on-rejected)
  "The internal function for attaching `then` callbacks.
It links a SOURCE-PROMISE to settle a TARGET-PROMISE via the handlers.

Arguments:
- `source-promise` (concur-promise): The promise providing the input.
- `target-promise` (concur-promise): The promise to be settled by the handlers.
- `on-resolved` (function): The success handler.
- `on-rejected` (function): The failure handler.

Returns:
- `(concur-promise)`: The `source-promise`."
  (concur-attach-callbacks
   source-promise
   (when on-resolved
     (concur-make-resolved-callback on-resolved target-promise
                                    :source-promise source-promise))
   (when on-rejected
     (concur-make-rejected-callback on-rejected target-promise
                                    :source-promise source-promise))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: `await` Implementation

(defun concur--await-blocking (promise timeout)
  "The cooperative blocking implementation for `concur:await`.
This should not be called directly. Use the `concur:await` macro.

Arguments:
- `promise` (concur-promise): The promise to await.
- `timeout` (number or nil): Maximum seconds to wait.

Returns:
- The resolved value of the promise.

Signals:
- `concur-await-error` on rejection or `concur-timeout-error` on timeout."
  ;; Optimization: If promise is already settled, return immediately.
  (unless (eq (concur:status promise) :pending)
    (if-let ((err (concur:error-value promise)))
        (signal 'concur-await-error (list (concur:error-message err) err))
      (return-from concur--await-blocking (concur:value promise))))

  ;; Setup for blocking wait.
  (let ((latch (%%make-await-latch))
        (timer nil))
    (unwind-protect
        (progn
          ;; Attach a high-priority "microtask" callback to signal the latch.
          (concur-attach-callbacks
           promise (concur--make-await-latch-callback latch promise))
          ;; Setup a timer to race against the promise settlement.
          (when timeout
            (setq timer
                  (run-at-time
                   timeout nil
                   (lambda ()
                     (unless (concur-await-latch-signaled-p latch)
                       (setf (concur-await-latch-signaled-p latch)
                             'timeout))))))
          ;; Block or poll until the latch is signaled.
          (if (eq (concur-promise-mode promise) :thread)
              (let* ((lock (concur-promise-lock promise))
                     (cv (make-condition-variable
                          (concur-lock-native-mutex lock))))
                (setf (concur-await-latch-cond-var latch) cv)
                (concur:with-mutex! lock
                  (while (not (concur-await-latch-signaled-p latch))
                    (condition-wait cv))))
            (while (not (concur-await-latch-signaled-p latch))
              (sit-for concur-await-poll-interval))))
      ;; Cleanup the timer.
      (when timer (cancel-timer timer)))

    ;; Evaluate the final result after unblocking.
    (cond
     ((eq (concur-await-latch-signaled-p latch) 'timeout)
      (signal 'concur-timeout-error
              (list (format "Await timed out for %s"
                            (concur:format-promise promise)))))
     ((concur:rejected-p promise)
      (signal 'concur-await-error
              (list (concur:error-message promise)
                    (concur:error-value promise))))
     (t
      (concur:value promise)))))

(defun concur--make-await-latch-callback (latch promise)
  "Create a callback that signals an `await` LATCH.
This is a high-priority microtask to unblock `await` calls immediately.

Arguments:
- `latch` (concur-await-latch): The latch to signal.
- `promise` (concur-promise): The promise this latch is attached to.

Returns:
- `(concur-callback)`: A high-priority callback struct."
  (let ((latch-signaler-fn
         (lambda (_val-or-err)
           (setf (concur-await-latch-signaled-p latch) t)
           (when-let ((cv (concur-await-latch-cond-var latch)))
             (condition-notify cv)))))
    (%%make-callback
     :type :await-latch :priority 0
     :handler-fn latch-signaler-fn
     :target-promise promise
     :source-promise promise)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Helpers and Utilities

(defun concur--kill-associated-process (promise)
  "If PROMISE has an associated process, kill it.

Arguments:
- `promise` (concur-promise): The promise whose process should be killed."
  (when-let ((proc (concur-promise-proc promise)))
    (when (process-live-p proc)
      (concur--log :debug (concur-promise-id promise)
                   "Killing associated process %S." proc)
      (ignore-errors (delete-process proc)))
    (setf (concur-promise-proc promise) nil)))

(defun concur--handle-unhandled-rejection-if-any (promise callback-links)
  "If PROMISE was rejected with no handlers, signals an unhandled rejection.

Arguments:
- `promise` (concur-promise): The rejected promise.
- `callback-links` (list): The original list of callback links."
  (when (and (eq (concur-promise-state promise) :rejected)
             (not (-any? (lambda (link)
                           (-any? (lambda (cb)
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
- `(string or nil)`: The formatted async stack trace, or `nil`."
  (when concur--current-async-stack
    (mapconcat #'identity (reverse concur--current-async-stack) "\n↳ ")))

(cl-defun concur-make-resolved-callback (handler-fn target-promise
                                         &key source-promise (priority 50) type)
  "Create a `concur-callback` struct for a resolved handler.

Arguments:
- `handler-fn` (function): The closure to execute on success.
- `target-promise` (concur-promise): The promise to settle.
- `:source-promise` (concur-promise): The input promise.
- `:priority` (integer): Execution priority.
- `:type` (symbol): Callback type, defaults to `:resolved`.

Returns:
- `(concur-callback)`: A new callback struct."
  (%%make-callback :type (or type :resolved)
                   :handler-fn handler-fn
                   :priority priority
                   :target-promise target-promise
                   :source-promise source-promise))

(cl-defun concur-make-rejected-callback (handler-fn target-promise
                                         &key source-promise (priority 50) type)
  "Create a `concur-callback` struct for a rejected handler.

Arguments: See `concur-make-resolved-callback`.
Returns:
- `(concur-callback)`: A new callback struct."
  (%%make-callback :type (or type :rejected)
                   :handler-fn handler-fn
                   :priority priority
                   :target-promise target-promise
                   :source-promise source-promise))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Promise Construction

;;;###autoload
(cl-defun concur:make-promise (&key (mode :deferred) name
                               cancel-token parent-promise proc)
  "Create a new, pending `concur-promise`.

Arguments:
- `:mode` (symbol): Concurrency mode. Can be `:deferred` (default, for main
  thread work) or `:thread` (for use with native threads).
- `:name` (string): A descriptive name for debugging and registry.
- `:cancel-token` (concur-cancel-token): An optional token to link for
  cancellation.
- `:parent-promise` (concur-promise): The promise that created this one, for
  registry tracking.
- `:proc` (process): An optional OS process to associate with this promise.

Returns:
- `(concur-promise)`: A new promise in the `:pending` state."
  (let* ((id (gensym (or name "promise-")))
         (lock-mode (if (eq mode :thread) :thread :deferred))
         (p (%%make-promise :id id
                            :mode mode
                            :lock (concur:make-lock
                                   (format "promise-lock-%S" id)
                                   :mode lock-mode)
                            :cancel-token cancel-token
                            :proc proc)))
    (when (fboundp 'concur-registry-register-promise)
      (concur-registry-register-promise p (or name (symbol-name id))
                                        :parent-promise parent-promise))
    (when (and cancel-token (fboundp 'concur-cancel-token-add-callback))
      (concur-cancel-token-add-callback
       cancel-token (lambda () (concur:cancel p))))
    p))

;;;###autoload
(defmacro concur:with-executor (executor-fn-form &rest opts)
  "Create a promise controlled by a user-supplied EXECUTOR-FN-FORM.
The executor is a lambda `(lambda (resolve reject) ...)` where `resolve` and
`reject` are functions that control the state of the returned promise.

Arguments:
- `executor-fn-form` (form): The lambda `(lambda (resolve reject) ...)` to
  execute.
- `opts` (plist): A plist of options passed to `concur:make-promise`
  (e.g., `:name`).

Returns:
- `(concur-promise)`: A new promise controlled by the executor."
  (declare (indent 1) (debug t))
  (let ((p (gensym "promise-"))
        (resolve (gensym "resolve-"))
        (reject (gensym "reject-")))
    `(let* ((,p (apply #'concur:make-promise ',opts))
            (,resolve (lambda (v) (concur:resolve ,p v)))
            (,reject  (lambda (e) (concur:reject  ,p e))))
       (let ((concur--current-promise-context ,p))
         (condition-case err
             (progn
               (concur--log :debug (concur-promise-id ,p) "Executing executor.")
               (funcall ,executor-fn-form ,resolve ,reject))
           (error
            (let ((err-msg (format "Executor failed: %S" err)))
              (concur--log :error (concur-promise-id ,p) "%s" err-msg)
              (concur:reject
               ,p (concur:make-error :type :executor-error
                                     :message err-msg :cause err
                                     :promise ,p))))))
       ,p)))

;;;###autoload
(cl-defun concur:resolved! (value &rest keys)
  "Create and return a new promise that is already resolved with VALUE.

Arguments:
- `value` (any): The resolution value for the new promise.
- `keys` (plist): Options for `concur:make-promise` like `:mode` and `:name`.

Returns:
- `(concur-promise)`: A new promise in the `:resolved` state."
  (let ((p (apply #'concur:make-promise keys)))
    (concur:resolve p value)))

;;;###autoload
(cl-defun concur:rejected! (error &rest keys)
  "Create and return a new promise that is already rejected with ERROR.

Arguments:
- `error` (any): The rejection error for the new promise.
- `keys` (plist): Options for `concur:make-promise` like `:mode` and `:name`.

Returns:
- `(concur-promise)`: A new promise in the `:rejected` state."
  (let ((p (apply #'concur:make-promise keys)))
    (concur:reject p error)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: State Transition

;;;###autoload
(defun concur:resolve (promise value)
  "Resolve a PROMISE with a given VALUE.
This implements the Promise/A+ Resolution Procedure. If VALUE is a
promise (a 'thenable'), the original PROMISE will adopt its state.
This operation is idempotent.

Arguments:
- `promise` (concur-promise): The promise to resolve.
- `value` (any): The resolution value. Can be a concrete value or another
  promise.

Returns:
- `(concur-promise)`: The original `promise`."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
  ;; Promise/A+ Spec 2.3.1: A promise cannot be resolved with itself.
  (if (eq promise value)
      (concur:reject
       promise
       (concur:make-error :type :type-error
                          :message "Promise cannot resolve with itself."))
    (let ((normalized-value
           (run-hook-with-args-until-success
            'concur-normalize-awaitable-hook value)))
      ;; If value is a promise, chain to it. Otherwise, fulfill.
      (if (eq (type-of (or normalized-value value)) 'concur-promise)
          ;; Promise/A+ Spec 2.3.2: If value is another promise, adopt its state.
          (let ((source-promise (or normalized-value value)))
            (concur--log :debug (concur-promise-id promise)
                         "Chaining to promise %S."
                         (concur-promise-id source-promise))
            (concur-attach-then-callbacks
             source-promise promise
             (lambda (res) (concur:resolve promise res))
             (lambda (err) (concur:reject promise err))))
        ;; Promise/A+ Spec 2.3.4: If value is not a promise, fulfill with value.
        (concur--settle-promise promise value nil nil))))
  promise)

;;;###autoload
(defun concur:reject (promise error)
  "Reject a PROMISE with a given ERROR.
This operation is idempotent.

Arguments:
- `promise` (concur-promise): The promise to reject.
- `error` (any): The reason for the rejection. Will be wrapped in a
  `concur-error` struct if it isn't one already.

Returns:
- `(concur-promise)`: The original `promise`."
  (unless (eq (type-of promise) 'concur-promise)
    (signal 'concur-type-error (list "Expected a promise" promise)))
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
(defun concur:cancel (promise &optional reason)
  "Cancel a pending PROMISE.
This is a convenience function that rejects the promise with a
`concur-cancel-error`. If the promise has an associated process,
it will be killed.

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
    (concur:reject
     promise (concur:make-error :type :cancel
                                :message (or reason "Promise cancelled")
                                :promise promise))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Introspection

;;;###autoload
(defun concur:status (promise)
  "Return the current state of a PROMISE without blocking.

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
- (boolean): `t` if the promise was rejected due to cancellation."
  (concur-promise-cancelled-p promise))

;;;###autoload
(defun concur:value (promise)
  "Return the resolved value of PROMISE, or nil if not resolved. Non-blocking.

Arguments:
- `promise` (concur-promise): The promise to inspect.

Returns:
- (any): The resolved value, or `nil` if not in the `:resolved` state."
  (when (concur:resolved-p promise) (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return the error of PROMISE if rejected, else nil. Non-blocking.

Arguments:
- `promise` (concur-promise): The promise to inspect.

Returns:
- (concur-error or nil): The rejection error object, or `nil`."
  (when (concur:rejected-p promise) (concur-promise-error promise)))

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
  "Return a human-readable string representation of a promise.

Arguments:
- `p` (concur-promise): The promise to format.

Returns:
- (string): A descriptive string including ID, name, mode, and state."
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
      (:resolved (format "#<Promise %s (%s) %s: resolved with %s>"
                         name id mode
                         (s-truncate concur-log-value-max-length
                                     (format "%S" (concur:value p)))))
      (:rejected (format "#<Promise %s (%s) %s: rejected with %s>"
                         name id mode
                         (s-truncate concur-log-value-max-length
                                     (concur:error-message p)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Error & Resource Handling

;;;###autoload
(defun concur:make-error (&rest all-args)
  "Create a new `concur-error` struct, capturing contextual information.
This function intelligently merges properties from a `:cause` error with
explicitly provided arguments. The precedence is:
explicit arguments > properties from `:cause` > defaults.

Arguments:
- `all-args` (plist): Key-value pairs for the `concur-error` struct fields.
  A special key `:cause` can be another `concur-error` to inherit from.

Returns:
- `(concur-error)`: A new, populated error struct."
  (let* ((cause (plist-get all-args :cause))
         (async-stack (concur-current-async-stack-string))
         (final-args all-args))
    ;; Step 1: Inherit properties from the `cause` if it's a concur-error.
    (when (eq (type-of cause) 'concur-error)
      (dolist (slot '(type message cmd args cwd exit-code signal process-status
                           stdout stderr))
        (let ((keyword (intern (concat ":" (symbol-name slot)))))
          ;; Add inherited value only if not already specified in `all-args`.
          (unless (plist-member final-args keyword)
            (when-let ((value (funcall
                               (intern (format "concur-error-%s" slot))
                               cause)))
              (setq final-args (plist-put final-args keyword value)))))))
    ;; Step 2: Ensure required fields have defaults if still missing.
    (unless (plist-member final-args :type)
      (setq final-args (plist-put final-args :type :generic)))
    (unless (plist-member final-args :message)
      (setq final-args (plist-put final-args :message "An error occurred.")))
    (unless (plist-member final-args :async-stack-trace)
      (setq final-args (plist-put final-args :async-stack-trace async-stack)))
    ;; Construct the final error object.
    (apply #'%%make-concur-error final-args)))

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
;; Public API: Awaiting

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
If called within a `coroutine`, it will yield control to the scheduler
instead of blocking. Otherwise, it blocks the current thread
(cooperatively on the main thread, natively on background threads).

Arguments:
- `promise-form` (form): A form that evaluates to a `concur-promise` or
  another awaitable object recognized by `concur-normalize-awaitable-hook`.
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
          (p (or (run-hook-with-args-until-success
                  'concur-normalize-awaitable-hook p-val)
                 p-val)))
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
       (concur--await-blocking
        p (or ,timeout concur-await-default-timeout)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Initialization

;; Initialize critical infrastructure on library load.
(concur--init-thread-signaling)
(concur--init-macrotask-queue)

(provide 'concur-core)
;;; concur-core.el ends here