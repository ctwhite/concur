;;; concur-promise-core.el --- Core data structures and functions for Concur Promises
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the core data structures and fundamental functions for the
;; Concur promise library. It defines what a promise is and the basic
;; operations for creating, resolving, and rejecting them. It is the foundational
;; module upon which all other promise functionality is built.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'ht)
(require 'ts)
(require 's)
(require 'subr-x)

(require 'concur-hooks)        ; Provides concur--log
(require 'concur-cancel)
(require 'concur-primitives)
(require 'concur-ast)

;; Forward declarations for byte-compiler
(declare-function concur-ast-lift-lambda-form "concur-ast"
                  (user-lambda &optional initial-param-bindings
                               additional-capture-vars))
(declare-function concur--process-handler "concur-promise-chain"
                  (handler-form handler-type-str initial-param-bindings))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants and Customization

(defconst concur--promise-cancelled-key :cancelled
  "Keyword in rejection objects indicating cancellation.")

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, unhandled rejected promises throw an error."
  :type 'boolean
  :group 'concur)

(defcustom concur-log-value-max-length 100
  "Max length for values/errors when formatting promises for logging.
Values or errors longer than this will be truncated with '...'."
  :type 'integer
  :group 'concur)

(defcustom concur-await-poll-interval 0.01
  "The polling interval (in seconds) for `concur:await`.
This value controls the sleep time in the cooperative waiting loop.
A smaller value (e.g., 0.001) increases responsiveness at the cost
of higher CPU usage. A larger value (e.g., 0.1) reduces CPU
usage but increases the latency for `await` to unblock."
  :type 'float
  :group 'concur)

(defvar concur--normalize-awaitable-fn nil
  "A function hook for normalizing awaitable objects into promises.
Higher-level libraries like `concur-future` can set this variable to a
function that takes one argument and returns a `concur-promise`. This allows
the core to handle different awaitable types without circular dependencies.")

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
High-level functions like `concur:async!` manage this stack to provide
richer debugging information on promise rejection.")

;; **FIX:** Declare the free variable to silence the byte-compiler warning.
;; This variable is used by the `yield` library for coroutine integration.
(defvar yield--await-external-status-key nil
  "Internal key used by the `yield` library for awaiting external events.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(eval-and-compile
  (cl-defstruct (concur-promise (:constructor %%make-promise))
    "Represents an asynchronous operation that can resolve or reject.
This struct should not be manipulated directly. Use the `concur:` functions.

Fields:
- `id` (symbol): A unique identifier for the promise, for logging.
- `result` (any): The value the promise resolved with.
- `error` (any): The error condition the promise was rejected with.
- `resolved-p` (boolean): `t` if the promise has settled.
- `callbacks` (list of `concur-callback-link`): A list of callback sets
  registered on this promise.
- `cancel-token` (`concur-cancel-token`): An optional associated token for
  cooperative cancellation.
- `cancelled-p` (boolean): `t` if cancellation was requested.
- `proc` (process): An optional external process, for auto-killing on cancel.
- `lock` (`concur-lock`): A mutex to protect internal state."
    (id nil :type symbol)
    (result nil)
    (error nil)
    (resolved-p nil :type boolean)
    (callbacks '() :type (list-of concur-callback-link))
    (cancel-token nil :type (or null concur-cancel-token))
    (cancelled-p nil :type boolean)
    (proc nil :type (or null process))
    (lock (concur:make-lock) :type concur-lock)))

(eval-and-compile
  (cl-defstruct (concur-await-latch (:constructor %%make-await-latch))
    "Internal latch used by the cooperative blocking `concur:await`.
This struct provides a simple, mutable flag that can be shared between the
`await` loop and the promise's settlement callbacks.

Fields:
- `signaled-p` (boolean or `t`): `t` if the latch has been signaled by a
  settled promise, or `'timeout` if it timed out."
    (signaled-p nil :type (or boolean (const 'timeout)))))

(eval-and-compile
  (cl-defstruct (concur-callback (:constructor %%make-callback))
    "An internal struct wrapping a callback function and its context.
This struct explicitly carries the full context needed to execute a handler
asynchronously, including any captured lexical variables.

Fields:
- `type` (symbol): The type of handler, e.g., `:resolved`, `:rejected`.
- `fn` (function): The actual callback function to execute.
- `promise` (`concur-promise`): The promise this callback will settle.
- `context` (alist): An alist of data passed to the handler, including
  runtime info and captured lexical variables from the AST lifter."
    (type nil :type (member :resolved :rejected :finally :tap :await-latch))
    (fn nil :type function)
    (promise nil :type (or null concur-promise))
    (context nil :type (or null alist))))

(eval-and-compile
  (cl-defstruct (concur-callback-link (:constructor %%make-callback-link))
    "Represents one link in a promise chain.
A single call to `.then` can attach both a resolved and a rejected handler.
This struct groups those related handlers together with a unique ID.

Fields:
- `id` (symbol): A unique identifier for this link in the chain.
- `callbacks` (list of `concur-callback`): The list of callbacks
  (typically one for success, one for failure) associated with this link."
    (id nil :type symbol)
    (callbacks '() :type (list-of concur-callback))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Core Promise Logic

(defun concur--format-value-or-error-for-log (value)
  "Format a value or error for concise logging, truncating if necessary.

Arguments:
- VALUE (any): The Lisp object to format.

Returns:
A concise string representation of VALUE."
  (let ((str (format "%S" value)))
    (if (> (length str) concur-log-value-max-length)
        (concat (substring str 0 concur-log-value-max-length) "...")
      str)))

(defun concur--process-scheduled-callbacks-batch (promise callbacks)
  "Process a batch of scheduled promise callbacks via a timer.
This function is the target of `run-with-timer` and executes all non-latch
callbacks associated with a newly-settled promise.

Arguments:
- PROMISE (`concur-promise`): The promise that settled.
- CALLBACKS (list of `concur-callback`): The list of callbacks to execute.

Returns:
`nil`."
  (concur--log :debug "[CORE:process-callbacks-batch] Processing batch for %s. Callbacks: %S"
               (concur:format-promise promise) (mapcar #'concur-callback-type callbacks))
  (run-hook-with-args 'concur-resolve-callbacks-begin-hook (list promise callbacks))
  (dolist (callback callbacks)
    (let* ((handler (concur-callback-fn callback))
           (type (concur-callback-type callback))
           (target-promise (concur-callback-promise callback))
           (context (concur-callback-context callback)))
      (concur--log :debug "[CORE:process-callbacks-batch] Executing callback type %S for %S. Context: %S"
                   type (concur:format-promise promise) context)
      (condition-case err
          ;; CORRECTION: Replaced `cond` with `pcase` for clarity and style.
          (pcase type
            (:resolved
             (when (not (concur-promise-error promise))
               (concur--log :debug "[CORE:process-callbacks-batch] Resolved handler: calling with value %S" (concur:value promise))
               (funcall handler (concur:value promise) context)))

            (:rejected
             (when-let ((err-val (concur:error-value promise)))
               (concur--log :debug "[CORE:process-callbacks-batch] Rejected handler: calling with error %S" err-val)
               (funcall handler err-val context)))

            (:finally
             (concur--log :debug "[CORE:process-callbacks-batch] Finally handler: calling with context %S" context)
             (funcall handler context))

            (:tap
             (concur--log :debug "[CORE:process-callbacks-batch] Tap handler: calling with value %S and error %S"
                          (concur:value promise) (concur:error-value promise))
             (funcall handler
                      (concur:value promise)
                      (concur:error-value promise)
                      context)))
        ('error
         (concur--log :error "[CORE:process-callbacks-batch] Callback failed in %S handler for %s: %S"
                      type
                      (concur:format-promise promise)
                      err)))))
  (run-hook-with-args 'concur-resolve-callbacks-end-hook (list promise callbacks)))

(defun concur--run-callbacks (promise)
  "Invoke registered callbacks on PROMISE after it has settled.
This function separates synchronous latch signaling from asynchronous handler
execution to ensure `await` unblocks correctly while handlers run later.

Arguments:
- PROMISE (`concur-promise`): The promise whose callbacks to run.

Returns:
`nil`."
  (concur--log :debug "[CORE:run-callbacks] Running callbacks for %s" (concur:format-promise promise))
  (let ((callback-links (concur-promise-callbacks promise))
        (async-callbacks '()))
    ;; Step 1: Immediately signal any synchronous await latches.
    (dolist (link callback-links)
      (dolist (cb (concur-callback-link-callbacks link))
        (if (eq (concur-callback-type cb) :await-latch)
            (let ((latch (cdr (assoc 'latch (concur-callback-context cb)))))
              (when (concur-await-latch-p latch)
                (setf (concur-await-latch-signaled-p latch) t)
                (concur--log :debug "[CORE:run-callbacks] Signaling await latch for %s"
                             (concur:format-promise promise))))
          ;; Collect all other handlers for async execution.
          (push cb async-callbacks))))
    (setq async-callbacks (nreverse async-callbacks))
    ;; Clear callbacks immediately to conform to Promise/A+ spec.
    (setf (concur-promise-callbacks promise) nil)
    (concur--log :debug "[CORE:run-callbacks] %d async callbacks scheduled for %s"
                 (length async-callbacks) (concur:format-promise promise))
    ;; Step 2: Schedule all other handlers to run in the next event loop cycle.
    (when async-callbacks
      (run-with-timer 0 nil
                      #'concur--process-scheduled-callbacks-batch
                      promise
                      async-callbacks))))

(defun concur--settle-promise (promise result error &optional is-cancellation)
  "Settle a PROMISE by resolving or rejecting it.
This is the core internal mechanism for setting a promise's final state.
It is idempotent; a promise can only be settled once.

Arguments:
- PROMISE (`concur-promise`): The promise to settle.
- RESULT (any): The value to resolve with (if successful).
- ERROR (any): The error condition to reject with.
- IS-CANCELLATION (boolean): If non-nil, marks the rejection as a cancellation.

Returns:
The settled `concur-promise`."
  (concur--log :debug "[CORE:settle-promise] Attempting to settle %s. Resolved-p: %S, Result: %S, Error: %S, Is-cancellation: %S"
               (concur:format-promise promise)
               (concur-promise-resolved-p promise)
               (concur--format-value-or-error-for-log result)
               (concur--format-value-or-error-for-log error)
               is-cancellation)
  (unless (concur-promise-resolved-p promise)
    (cl-block concur--settle-promise
      (concur--log :debug "[CORE:settle-promise] Acquiring lock for %s"
                  (concur:format-promise promise))
      ;; Acquire lock to prevent race conditions during state transition.
      (concur:with-mutex! (concur-promise-lock promise)
        (:else
        (concur--log :warn "[CORE:settle-promise] %s lock contention, retrying settlement."
                      (concur:format-promise promise))
        (run-with-timer 0.001 nil #'concur--settle-promise
                        promise result error is-cancellation))
        ;; Re-check inside lock to be absolutely certain.
        (when (concur-promise-resolved-p promise)
          (concur--log :debug "[CORE:settle-promise] %s already settled inside lock, aborting."
                       (concur:format-promise promise))
          (cl-return-from concur--settle-promise promise))
        ;; Set the final state.
        (setf (concur-promise-result promise) result)
        (setf (concur-promise-error promise) error)
        (setf (concur-promise-resolved-p promise) t)
        (when is-cancellation
          (setf (concur-promise-cancelled-p promise) t))
        (concur--log :debug "[CORE:settle-promise] %s successfully SETTLED. Result: %S, Error: %S, Cancelled: %S"
                     (concur:format-promise promise)
                     (concur--format-value-or-error-for-log result)
                     (concur--format-value-or-error-for-log error)
                     is-cancellation))
      ;; `unwind-protect` ensures hooks run even if callbacks error.
      (unwind-protect
          (concur--run-callbacks promise)
        (when (and error (not (concur-promise-callbacks promise)) (not is-cancellation))
          (concur--log :warn "[CORE:settle-promise] Unhandled rejection for %s: %S"
                       (concur:format-promise promise) (concur--format-value-or-error-for-log error))
          (run-hook-with-args 'concur-unhandled-rejection-hook (list promise error))
          (when concur-throw-on-promise-rejection
            (concur--log :error "[CORE:settle-promise] Throwing unhandled rejection error: %S" error)
            ;; This is where the error passed to `concur:reject` eventually causes a signal.
            ;; We need to make sure `error` here is a valid condition list for `signal`.
            (signal (car error) (cdr error)))))))
  promise)

(defun concur--on-resolve (source-awaitable &rest callbacks)
  "Register callbacks for a promise or other awaitable object.
This function is the low-level entry point for all promise-consuming
operations. It uses the `concur--normalize-awaitable-fn` hook to convert
any awaitable object (like a future) into a promise before attaching handlers.

Arguments:
- SOURCE-AWAITABLE (any): The object to attach callbacks to.
- CALLBACKS (list of `concur-callback`): The callbacks to register.

Returns:
A unique symbol identifying this callback link."
  (concur--log :debug "[CORE:on-resolve] Registering callbacks for source: %S, Callbacks count: %d"
               source-awaitable (length callbacks))
  ;; --- NORMALIZATION STEP ---
  ;; If a normalizer function has been set by a higher-level library, use it.
  ;; Otherwise, assume the input is already a promise.
  (let ((promise (if concur--normalize-awaitable-fn
                     (progn
                       (concur--log :debug "[CORE:on-resolve] Normalizing awaitable %S" source-awaitable)
                       (funcall concur--normalize-awaitable-fn source-awaitable))
                   source-awaitable)))

    (unless (concur-promise-p promise)
      (concur--log :error "[CORE:on-resolve] Invalid awaitable provided: %S" source-awaitable)
      (error "Invalid awaitable provided. Must resolve to a promise, got %S"
             source-awaitable))

    (let ((callback-id (gensym "promise-cb-")))
      (if (concur-promise-resolved-p promise)
          (progn
            (concur--log :debug "[CORE:on-resolve] Source %s already settled, scheduling callbacks immediately."
                         (concur:format-promise promise))
            (concur--process-scheduled-callbacks-batch promise callbacks))
        (concur--log :debug "[CORE:on-resolve] Source %s pending, adding callbacks to queue."
                     (concur:format-promise promise))
        (concur:with-mutex! (concur-promise-lock promise)
          (:else (concur--log :warn "[CORE:on-resolve] %s lock contention, retrying callback registration."
                              (concur:format-promise promise))
                 (apply #'concur--on-resolve promise callbacks))
          (push (%%make-callback-link :id callback-id
                                      :callbacks callbacks)
                (concur-promise-callbacks promise))))
      callback-id)))

(defun concur--resolve-with-maybe-promise (target-promise value-or-promise)
  "Resolve TARGET-PROMISE with VALUE-OR-PROMISE.
This implements the Promise/A+ `thenable` resolution procedure. If
`value-or-promise` is itself a promise, `target-promise` will adopt its
state, effectively `'flattening'` nested promises.

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to resolve.
- VALUE-OR-PROMISE (any): The value or promise to resolve with.

Returns:
`nil`."
  (concur--log :debug "[CORE:resolve-with-maybe-promise] Resolving %s with %S"
               (concur:format-promise target-promise)
               (concur--format-value-or-error-for-log value-or-promise))
  (if (concur-promise-p value-or-promise)
      ;; If the value is another promise, chain to it.
      (progn
        (concur--log :debug "[CORE:resolve-with-maybe-promise] Value is a promise %s, chaining."
                     (concur:format-promise value-or-promise))
        (concur--on-resolve
         value-or-promise
         (concur--make-resolved-callback
          (lambda (res-val ctx)
            (concur--log :debug "[CORE:resolve-with-maybe-promise] Chained promise resolved, resolving target %s with %S"
                         (concur:format-promise (cdr (assoc 'target-promise ctx))) res-val)
            (concur:resolve (cdr (assoc 'target-promise ctx)) res-val))
          target-promise
          :context (list (cons 'target-promise target-promise)))
         (concur--make-rejected-callback
          (lambda (rej-err ctx)
            (concur--log :debug "[CORE:resolve-with-maybe-promise] Chained promise rejected, rejecting target %s with %S"
                         (concur:format-promise (cdr (assoc 'target-promise ctx))) rej-err)
            (concur:reject (cdr (assoc 'target-promise ctx)) rej-err))
          target-promise
          :context (list (cons 'target-promise target-promise)))))
    ;; If the value is not a promise, settle directly.
    (progn
      (concur--log :debug "[CORE:resolve-with-maybe-promise] Value is not a promise, settling %s directly with %S"
                   (concur:format-promise target-promise) value-or-promise)
      (concur--settle-promise target-promise value-or-promise nil))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Callback Creation

(defun concur--merge-contexts (existing-context captured-vars)
  "Merge `existing-context` with `captured-vars` into a single alist.

Arguments:
- EXISTING-CONTEXT (alist or `nil`): An alist of existing context data.
- CAPTURED-VARS (alist or `nil`): An alist of variables captured for lifting.

Returns:
A new alist containing the merged data."
  (concur--log :debug "[CORE:merge-contexts] Merging existing: %S, captured: %S" existing-context captured-vars)
  (cond
   ((and (listp existing-context) (listp captured-vars))
    (append existing-context captured-vars))
   ((listp existing-context) existing-context)
   ((listp captured-vars) captured-vars)
   (t nil)))

(cl-defun concur--make-resolved-callback (handler target-promise
                                           &key context captured-vars)
  "Create a `concur-callback` for a resolved handler.

Arguments:
- HANDLER (function): The resolved callback function.
- TARGET-PROMISE (`concur-promise`): The promise this callback will resolve.
- :CONTEXT (alist): Additional fixed data to pass to the handler.
- :CAPTURED-VARS (alist): Lexically captured variables from the AST lifter.

Returns:
A new `concur-callback` struct."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (concur--log :debug "[CORE:make-resolved-callback] Created resolved callback for %s. Final context: %S"
                 (concur:format-promise target-promise) final-context)
    (%%make-callback :type :resolved
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-rejected-callback (handler target-promise
                                           &key context captured-vars)
  "Create a `concur-callback` for a rejected handler."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (concur--log :debug "[CORE:make-rejected-callback] Created rejected callback for %s. Final context: %S"
                 (concur:format-promise target-promise) final-context)
    (%%make-callback :type :rejected
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-finally-callback (handler target-promise
                                          &key context captured-vars)
  "Create a `concur-callback` for a finally handler."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (concur--log :debug "[CORE:make-finally-callback] Created finally callback for %s. Final context: %S"
                 (concur:format-promise target-promise) final-context)
    (%%make-callback :type :finally
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-tap-callback (handler target-promise
                                      &key context captured-vars)
  "Create a `concur-callback` for a tap handler."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (concur--log :debug "[CORE:make-tap-callback] Created tap callback for %s. Final context: %S"
                 (concur:format-promise target-promise) final-context)
    (%%make-callback :type :tap
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-await-latch-callback (latch target-promise
                                              &key context captured-vars)
  "Create a `concur-callback` for an await latch."
  ;; Note: The original `context` and `captured-vars` handling here seemed a bit off.
  ;; `context` for await latch typically only includes the latch itself.
  ;; `captured-vars` from AST lifting are probably not relevant for a dummy lambda.
  ;; Re-aligning with typical `merge-contexts` usage if it applies.
  (let ((final-context (concur--merge-contexts (list (cons 'latch latch)) context)))
    (setq final-context (concur--merge-contexts final-context captured-vars)) ; ensures captured-vars are merged if present
    (concur--log :debug "[CORE:make-await-latch-callback] Created await latch callback for %s. Latch: %S, Final context: %S"
                 (concur:format-promise target-promise) latch final-context)
    (%%make-callback :type :await-latch
                     :fn (lambda () nil) ; Dummy handler.
                     :promise target-promise
                     :context final-context)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Await Blocking

(defun concur--await-blocking (watched-promise &optional timeout)
  "Blocking (but cooperative) implementation of `await`.
This function pauses execution until `watched-promise` settles or `timeout`
is reached. It uses `sit-for` to yield to the Emacs event loop, allowing
timers and other events to run.

Arguments:
- WATCHED-PROMISE (`concur-promise`): The promise to wait for.
- TIMEOUT (number): Optional max time in seconds to wait.

Returns:
The resolved value of `watched-promise`.

Signals:
- `concur:timeout-error` if the timeout is exceeded.
- The error from `watched-promise` if it rejects."
  (unless (concur-promise-p watched-promise)
    (concur--log :error "[CORE:await-blocking] Invalid promise object: %S" watched-promise)
    (error "concur--await-blocking: Invalid promise object: %S" watched-promise))

  (concur--log :debug "[CORE:await-blocking] Entering for %s (timeout: %s)"
               (concur:format-promise watched-promise) timeout)

  ;; Handle already-resolved promises immediately.
  (if (concur-promise-resolved-p watched-promise)
      (progn
        (concur--log :debug "[CORE:await-blocking] Promise %s already settled, returning immediately."
                     (concur:format-promise watched-promise))
        (if-let ((err (concur:error-value watched-promise)))
            (progn
              (concur--log :debug "[CORE:await-blocking] Promise %s rejected, signaling error %S."
                           (concur:format-promise watched-promise) err)
              (signal (car err) (cdr err)))
          (concur:value watched-promise)))

    ;; For pending promises, enter the cooperative wait loop.
    (let ((latch (%%make-await-latch))
          (timer nil))
      (unwind-protect
          (progn
            (concur--log :debug "[CORE:await-blocking] Promise %s pending, setting up await latch."
                         (concur:format-promise watched-promise))
            ;; Attach the latch so it gets signaled when the promise settles.
            (concur--on-resolve
             watched-promise
             (concur--make-await-latch-callback latch watched-promise))

            ;; If a timeout is specified, set up a timer that will signal
            ;; the latch with a special 'timeout status.
            (when timeout
              (setq timer
                    (run-at-time timeout nil
                                 (lambda ()
                                   (concur--log :debug "[CORE:await-blocking] Timeout occurred for %s."
                                                (concur:format-promise watched-promise))
                                   (setf (concur-await-latch-signaled-p latch)
                                         'timeout)))))

            ;; The robust wait loop using `sit-for`.
            (while (not (concur-await-latch-signaled-p latch))
              (sit-for concur-await-poll-interval)
              (concur--log :debug "[CORE:await-blocking] Polling for %s, latch signaled-p: %S"
                           (concur:format-promise watched-promise) (concur-await-latch-signaled-p latch)))

            ;; When the loop exits, check how it was signaled.
            (if (eq (concur-await-latch-signaled-p latch) 'timeout)
                (progn
                  (concur--log :error "[CORE:await-blocking] Await for %s timed out after %s seconds."
                               (concur:format-promise watched-promise) timeout)
                  (error 'concur:timeout-error
                         (format "Await for %s timed out after %s seconds"
                                 (concur:format-promise watched-promise)
                                 timeout)))
              ;; Otherwise, the promise settled normally.
              (concur--log :debug "[CORE:await-blocking] Promise %s settled, checking result/error."
                           (concur:format-promise watched-promise))
              (if-let ((err (concur:error-value watched-promise)))
                  (progn
                    (concur--log :debug "[CORE:await-blocking] Promise %s rejected, signaling error %S."
                                 (concur:format-promise watched-promise) err)
                    (signal (car err) (cdr err)))
                (concur:value watched-promise))))
        ;; Cleanup form: always cancel the timer if it exists.
        (when timer
          (concur--log :debug "[CORE:await-blocking] Cancelling timer for %s."
                       (concur:format-promise watched-promise))
          (cancel-timer timer))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Promise Construction and Basic Operations

(defun concur:make-promise (&rest slots)
  "Create and return a new unresolved (pending) promise.
This is a low-level constructor. Prefer using `concur:with-executor`
for creating promises that perform asynchronous work.

Arguments:
- SLOTS (plist): Optional initial values for the promise struct slots.

Returns:
A new, pending `concur-promise`."
  (let ((p (apply #'%%make-promise
                  :id (gensym "promise-")
                  slots)))
    (concur--log :debug "[CORE:make-promise] Created new promise: %s" (concur:format-promise p))
    p))

;;;###autoload
(cl-defmacro concur:with-executor (executor-fn-form &key cancel-token &environment env)
  "Define and execute an asynchronous block that manages its own promise.

  This macro provides a controlled environment for starting asynchronous
  operations. The `executor-fn-form` is typically a lambda
  `(lambda (resolve reject) ...)` which receives `resolve` and `reject`
  functions to control the promise's lifecycle.

  Arguments:
  - `executor-fn-form`: A zero-argument lambda form `(lambda () ...)` or a
    function symbol that, when called, sets up and resolves/rejects the
    returned promise. It automatically receives `resolve` and `reject`
    parameters to manage the promise.
  - `:cancel-token`: (optional) A `concur-cancel-token` for cancellability.
  - `env`: (Implicit) The lexical environment for macro expansion.

  Returns:
  A `concur-promise` that will be resolved or rejected by the `executor-fn-form`."
  (declare (indent 1) (debug t))
  (let* ((promise (gensym "promise-"))
         (cancel-token-val (gensym "cancel-token-val-"))
         ;; Analyze the executor form. 'resolve' and 'reject' are its parameters,
         ;; so they should NOT be identified as free variables to be captured.
         (executor-analysis (concur-ast-analysis
                             executor-fn-form
                             env
                             nil)) ; No additional captures for 'resolve'/'reject'
         (original-lambda (concur-ast-analysis-result-expanded-callable-form executor-analysis))
         (free-vars (concur-ast-analysis-result-free-vars-list executor-analysis))
         ;; Generate the context form for any *other* free variables from user's code.
         (context-form (concur-ast-make-captured-vars-form free-vars)))

    (let ((err-sym (gensym "err-"))) ; Gensym for `err` in condition-case
      `(let* ((,promise (concur:make-promise))
              (,cancel-token-val ,cancel-token))
         (when ,cancel-token-val
           (setf (concur-promise-cancel-token ,promise) ,cancel-token-val))
         (condition-case ,err-sym ; Catch errors within the executor's body
              ;; Directly bind `resolve` and `reject` in a `let` block.
              ;; These are the functions that control the promise.
              (let ((resolve #'(lambda (value) (concur:resolve ,promise value)))
                    (reject #'(lambda (error) (concur:reject ,promise error)))
                    (context ,context-form)) ; Bind the captured vars context here

                ;; Unpack other captured free variables from the context
                (let ,(cl-loop for var in free-vars
                              collect `(,var (concur--safe-ht-get context ',var)))
                  ;; Now, call the user's original lambda, passing the bound
                  ;; `resolve` and `reject` functions as its arguments.
                  (funcall ,original-lambda resolve reject)))
           (error
            (concur:reject ,promise `(executor-error :original-error ,,err-sym))))
         ,promise))))

(defun concur:resolve (target-promise result)
  "Resolve a promise with a success RESULT.
If RESULT is itself a promise, `target-promise` will adopt its state
(this is the Promise/A+ `thenable` flattening behavior).

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to resolve.
- RESULT (any): The value to resolve the promise with.

Returns:
The `target-promise`."
  (concur--log :debug "[CORE:resolve] Public API: Resolving %s with result %S"
               (concur:format-promise target-promise) (concur--format-value-or-error-for-log result))
  (concur--resolve-with-maybe-promise target-promise result)
  target-promise)

(defun concur:reject (target-promise error &optional is-cancellation)
  "Reject a promise with an ERROR reason.
If the dynamic variable `concur--current-async-stack` is bound, its
value will be captured and added to the error object.

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to reject.
- ERROR (any): The reason for the rejection, typically a Lisp condition.
- IS-CANCELLATION (boolean): If non-nil, mark as a cancellation.

Returns:
The `target-promise`."
  (concur--log :debug "[CORE:reject] Public API: Rejecting %s with error %S (Is-cancellation: %S)"
               (concur:format-promise target-promise) (concur--format-value-or-error-for-log error) is-cancellation)
  (let ((final-error error))
    ;; If there's an active async stack and the error is a plist,
    ;; attach the stack trace to it.
    (when (and concur--current-async-stack (listp error))
      (concur--log :debug "[CORE:reject] Attaching async stack to error %S" error)
      (setq final-error
            (append error `(:async-stack-trace
                            ,(mapconcat 'identity
                                        (reverse concur--current-async-stack)
                                        "\n↳ ")))))
    (concur--settle-promise target-promise nil final-error is-cancellation)))

(defun concur:resolved! (value)
  "Return a new promise that is already resolved with VALUE.

Arguments:
- VALUE (any): The value for the new resolved promise.

Returns:
A new, already-resolved `concur-promise`."
  (concur--log :debug "[CORE:resolved!] Creating new resolved promise with value %S" (concur--format-value-or-error-for-log value))
  (let ((p (concur:make-promise)))
    (setf (concur-promise-result p) value
          (concur-promise-resolved-p p) t)
    p))

(defun concur:rejected! (error)
  "Return a new promise that is already rejected with ERROR.

Arguments:
- ERROR (any): The error condition for the new rejected promise.

Returns:
A new, already-rejected `concur-promise`."
  (concur--log :debug "[CORE:rejected!] Creating new rejected promise with error %S" (concur--format-value-or-error-for-log error))
  (let ((p (concur:make-promise)))
    (setf (concur-promise-error p) error
          (concur-promise-resolved-p p) t)
    p))

(defun concur:cancel (cancellable-promise &optional reason)
  "Cancel a PROMISE by rejecting it with a cancellation reason.
If the promise is associated with an external process via its `proc` field,
this function also attempts to kill that process.

Arguments:
- CANCELLABLE-PROMISE (`concur-promise`): The promise to cancel.
- REASON (string, optional): A message explaining the cancellation.

Returns:
The (now rejected) `cancellable-promise`."
  (concur--log :debug "[CORE:cancel] Attempting to cancel %s with reason: %S"
               (concur:format-promise cancellable-promise) reason)
  (unless (concur-promise-resolved-p cancellable-promise)
    (when-let ((proc (concur-promise-proc cancellable-promise)))
      (when (process-live-p proc)
        (concur--log :debug "[CORE:cancel] Killing associated process for %s: %S"
                     (concur:format-promise cancellable-promise) proc)
        (ignore-errors (kill-process proc))))
    (concur:reject cancellable-promise
                   `(,(car concur--promise-cancelled-key)
                     :message ,(or reason "Promise cancelled"))
                   t))
  cancellable-promise)

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
When used within a `defasync!` coroutine, this macro will yield control
until the promise settles. When used outside a coroutine, it will
cooperatively block the Emacs event loop until the promise settles.

Arguments:
- PROMISE-FORM (form): A form that evaluates to a `concur-promise`.
- TIMEOUT (number, optional): Max time in seconds to wait. If exceeded,
  a `concur:timeout-error` is signaled.

Returns:
The resolved value of the `promise-form`.

Signals:
- `concur:timeout-error` if the `timeout` is exceeded.
- The error condition from `promise-form` if it rejects."
  (declare (indent 1))
  (concur--log :debug "[CORE:await] Expanding concur:await for promise-form: %S (timeout: %S)"
               promise-form timeout)
  `(if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
       ;; Inside a coroutine, yield to the scheduler.
       (let ((awaited-promise ,promise-form))
         (concur--log :debug "[CORE:await] Inside coroutine, awaiting promise %s" (concur:format-promise awaited-promise))
         (if (concur-promise-resolved-p awaited-promise)
             (if-let ((err (concur:error-value awaited-promise)))
                 (progn
                   (concur--log :debug "[CORE:await] Coroutine: Promise %s already rejected, signaling error %S"
                                (concur:format-promise awaited-promise) err)
                   (signal (car err) (cdr err)))
               (progn
                 (concur--log :debug "[CORE:await] Coroutine: Promise %s already resolved, returning value %S"
                              (concur:format-promise awaited-promise) (concur:value awaited-promise))
                 (concur:value awaited-promise)))
           (progn
             (concur--log :debug "[CORE:await] Coroutine: Yielding for promise %s" (concur:format-promise awaited-promise))
             (yield--internal-throw-form awaited-promise
                                         ',yield--await-external-status-key))))
     ;; Outside a coroutine, use the cooperative blocking helper.
     (progn
       (concur--log :debug "[CORE:await] Outside coroutine, using blocking await for promise-form: %S" promise-form)
       (concur--await-blocking ,promise-form ,timeout))))

(defun concur:status (promise)
  "Return the current status of a PROMISE without blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to inspect.

Returns:
A symbol: one of `'pending`, `'resolved`, `'rejected`, or `'cancelled`."
  (unless (concur-promise-p promise)
    (concur--log :error "[CORE:status] Invalid promise object: %S" promise)
    (error "Invalid promise object: %S" promise))
  (cond ((not (concur-promise-resolved-p promise)) 'pending)
        ((concur-promise-cancelled-p promise) 'cancelled)
        ((concur-promise-error promise) 'rejected)
        (t 'resolved)))

(defun concur:pending-p (promise)
  "Return non-nil if PROMISE is currently pending.

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is pending, `nil` otherwise."
  (unless (concur-promise-p promise)
    (concur--log :error "[CORE:pending-p] Invalid promise object: %S" promise)
    (error "Invalid promise object: %S" promise))
  (eq (concur:status promise) 'pending))

(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has been resolved successfully.

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is resolved, `nil` otherwise."
  (unless (concur-promise-p promise)
    (concur--log :error "[CORE:resolved-p] Invalid promise object: %S" promise)
    (error "Invalid promise object: %S" promise))
  (eq (concur:status promise) 'resolved))

(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE has been rejected (including cancellation).

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is rejected or cancelled, `nil` otherwise."
  (unless (concur-promise-p promise)
    (concur--log :error "[CORE:rejected-p] Invalid promise object: %S" promise)
    (error "Invalid promise object: %S" promise))
  (memq (concur:status promise) '(rejected cancelled)))

(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE has been cancelled.

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is cancelled, `nil` otherwise."
  (unless (concur-promise-p promise)
    (concur--log :error "[CORE:cancelled-p] Invalid promise object: %S" promise)
    (error "Invalid promise object: %S" promise))
  (eq (concur:status promise) 'cancelled))

(defun concur:value (promise)
  "Return the resolved value of a PROMISE, or nil if not resolved.
This function is non-blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to query.

Returns:
The resolved value, or `nil` if the promise is pending or rejected."
  (unless (concur-promise-p promise)
    (concur--log :error "[CORE:value] Invalid promise object: %S" promise)
    (error "Invalid promise object: %S" promise))
  (when (eq (concur:status promise) 'resolved)
    (concur-promise-result promise)))

(defun concur:error-value (promise)
  "Return the error value of a PROMISE if rejected, else nil.
This function is non-blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to query.

Returns:
The error condition, or `nil` if the promise is pending or resolved."
  (when (memq (concur:status promise) '(rejected cancelled))
    (concur-promise-error promise)))

(defun concur:error-message (promise-or-error)
  "Return a human-readable message from a promise's error or an error object.
This function safely extracts a meaningful message from various error formats.

Arguments:
- PROMISE-OR-ERROR (`concur-promise` or any): The promise or error value.

Returns:
A formatted string representing the error."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (cond ((stringp err) err)
          ((plistp err) (or (plist-get err :message) (format "%S" err)))
          ((symbolp err) (symbol-name err))
          (err (format "%S" err))
          (t "Unknown error"))))

(defun concur:format-promise (p)
  "Return a human-readable string representation of a promise.
Intended for logging/debugging to provide a concise summary.

Arguments:
- P (any): The object to format (preferably a `concur-promise`).

Returns:
A formatted string."
  (if (concur-promise-p p)
      (let ((status (concur:status p))
            (val (concur-promise-result p))
            (err (concur-promise-error p))
            (id (concur-promise-id p)))
        (pcase status
          ('pending (format "#<concur-promise %s: pending>" id))
          ('resolved (format "#<concur-promise %s: resolved with %s>"
                             id (concur--format-value-or-error-for-log val)))
          ('rejected (format "#<concur-promise %s: rejected with %s>"
                             id (concur--format-value-or-error-for-log err)))
          ('cancelled (format "#<concur-promise %s: cancelled %s>"
                               id (concur--format-value-or-error-for-log err)))
          (_ (format "#<concur-promise %s: unknown status>" id))))
    (format "%S" p)))

(provide 'concur-promise-core)
;;; concur-promise-core.el ends here