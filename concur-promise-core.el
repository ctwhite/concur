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

(require 'concur-hooks)
(require 'concur-cancel)
(require 'concur-primitives)

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
  (run-hook-with-args 'concur-resolve-callbacks-begin-hook (list promise callbacks))
  (dolist (callback callbacks)
    (let* ((handler (concur-callback-fn callback))
           (type (concur-callback-type callback))
           (target-promise (concur-callback-promise callback))
           (context (concur-callback-context callback)))
      (condition-case err
          ;; CORRECTION: Replaced `cond` with `pcase` for clarity and style.
          (pcase type
            (:resolved
             (when (not (concur-promise-error promise))
               (funcall handler (concur:value promise) context)))

            (:rejected
             (when-let ((err-val (concur:error-value promise)))
               (funcall handler err-val context)))

            (:finally
             (funcall handler context))

            (:tap
             (funcall handler
                      (concur:value promise)
                      (concur:error-value promise)
                      context)))
        ('error
         (concur--log :error "Callback failed in %S handler for %s: %S"
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
  (concur--log :debug "CALLBACKS: Running for %s" (concur:format-promise promise))
  (let ((callback-links (concur-promise-callbacks promise))
        (async-callbacks '()))
    ;; Step 1: Immediately signal any synchronous await latches.
    (dolist (link callback-links)
      (dolist (cb (concur-callback-link-callbacks link))
        (if (eq (concur-callback-type cb) :await-latch)
            (let ((latch (cdr (assoc 'latch (concur-callback-context cb)))))
              (when (concur-await-latch-p latch)
                (setf (concur-await-latch-signaled-p latch) t)
                (concur--log :debug "CALLBACKS: Signaling await latch for %s"
                             (concur:format-promise promise))))
          ;; Collect all other handlers for async execution.
          (push cb async-callbacks))))
    (setq async-callbacks (nreverse async-callbacks))
    ;; Clear callbacks immediately to conform to Promise/A+ spec.
    (setf (concur-promise-callbacks promise) nil)
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
  (unless (concur-promise-resolved-p promise)
    (concur--log :debug "PROMISE-SETTLE: Settling %s"
                 (concur:format-promise promise))
    ;; Acquire lock to prevent race conditions during state transition.
    (concur:with-mutex! (concur-promise-lock promise)
      (:else
       (concur--log :warn "PROMISE-SETTLE: %s lock contention, retrying."
                    (concur:format-promise promise))
       (run-with-timer 0.001 nil #'concur--settle-promise
                       promise result error is-cancellation))
      ;; Re-check inside lock to be absolutely certain.
      (when (concur-promise-resolved-p promise)
        (cl-return-from concur--settle-promise promise))
      ;; Set the final state.
      (setf (concur-promise-result promise) result)
      (setf (concur-promise-error promise) error)
      (setf (concur-promise-resolved-p promise) t)
      (when is-cancellation
        (setf (concur-promise-cancelled-p promise) t)))
    ;; `unwind-protect` ensures hooks run even if callbacks error.
    (unwind-protect
        (concur--run-callbacks promise)
      (when (and error (not (concur-promise-callbacks promise)) (not is-cancellation))
        (run-hook-with-args 'concur-unhandled-rejection-hook (list promise error))
        (when concur-throw-on-promise-rejection
          (signal (car error) (cdr error))))))
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
  ;; --- NORMALIZATION STEP ---
  ;; If a normalizer function has been set by a higher-level library, use it.
  ;; Otherwise, assume the input is already a promise.
  (let ((promise (if concur--normalize-awaitable-fn
                     (funcall concur--normalize-awaitable-fn source-awaitable)
                   source-awaitable)))

    (unless (concur-promise-p promise)
      (error "Invalid awaitable provided. Must resolve to a promise, got %S"
             source-awaitable))

    (let ((callback-id (gensym "promise-cb-")))
      (if (concur-promise-resolved-p promise)
          (progn
            (concur--log :debug "ON_RESOLVE: Source %s already settled, scheduling."
                         (concur:format-promise promise))
            (concur--process-scheduled-callbacks-batch promise callbacks))
        (concur:with-mutex! (concur-promise-lock promise)
          (:else (concur--log :warn "ON_RESOLVE: %s lock contention, retrying."
                              (concur:format-promise promise))
                 (apply #'concur--on-resolve promise callbacks))
          (push (%%make-callback-link callback-id callbacks)
                (concur-promise-callbacks promise))))
      callback-id)))

(defun concur--resolve-with-maybe-promise (target-promise value-or-promise)
  "Resolve TARGET-PROMISE with VALUE-OR-PROMISE.
This implements the Promise/A+ 'thenable' resolution procedure. If
`value-or-promise` is itself a promise, `target-promise` will adopt its
state, effectively 'flattening' nested promises.

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to resolve.
- VALUE-OR-PROMISE (any): The value or promise to resolve with.

Returns:
`nil`."
  (if (concur-promise-p value-or-promise)
      ;; If the value is another promise, chain to it.
      (concur--on-resolve
       value-or-promise
       (concur--make-resolved-callback
        (lambda (res-val ctx)
          (concur:resolve (cdr (assoc 'target-promise ctx)) res-val))
        target-promise
        :context (list (cons 'target-promise target-promise)))
       (concur--make-rejected-callback
        (lambda (rej-err ctx)
          (concur:reject (cdr (assoc 'target-promise ctx)) rej-err))
        target-promise
        :context (list (cons 'target-promise target-promise))))
    ;; If the value is not a promise, settle directly.
    (concur--settle-promise target-promise value-or-promise nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Callback Creation

(defun concur--merge-contexts (existing-context captured-vars)
  "Merge `existing-context` with `captured-vars` into a single alist.

Arguments:
- EXISTING-CONTEXT (alist or `nil`): An alist of existing context data.
- CAPTURED-VARS (alist or `nil`): An alist of variables captured for lifting.

Returns:
A new alist containing the merged data."
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
    (%%make-callback :type :resolved 
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-rejected-callback (handler target-promise
                                           &key context captured-vars)
  "Create a `concur-callback` for a rejected handler."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (%%make-callback :type :rejected 
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-finally-callback (handler target-promise
                                          &key context captured-vars)
  "Create a `concur-callback` for a finally handler."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (%%make-callback :type :finally 
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-tap-callback (handler target-promise
                                      &key context captured-vars)
  "Create a `concur-callback` for a tap handler."
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (%%make-callback :type :tap 
                     :fn handler
                     :promise target-promise
                     :context final-context)))

(cl-defun concur--make-await-latch-callback (latch target-promise
                                              &key context captured-vars)
  "Create a `concur-callback` for an await latch."
  (let ((final-context (concur--merge-contexts (list (cons 'latch latch))
                                             (if (listp context) context nil))))
    (setq final-context (concur--merge-contexts final-context
                                              (if (listp captured-vars) captured-vars nil)))
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
    (error "concur--await-blocking: Invalid promise object: %S" watched-promise))

  (concur--log :debug "AWAIT-BLOCKING: Entering for %s (timeout: %s)"
               (concur:format-promise watched-promise) timeout)

  ;; Handle already-resolved promises immediately.
  (if (concur-promise-resolved-p watched-promise)
      (if-let ((err (concur:error-value watched-promise)))
          (signal (car err) (cdr err))
        (concur:value watched-promise))

    ;; For pending promises, enter the cooperative wait loop.
    (let ((latch (%%make-await-latch))
          (timer nil))
      (unwind-protect
          (progn
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
                                   (setf (concur-await-latch-signaled-p latch)
                                         'timeout)))))

            ;; The robust wait loop using `sit-for`.
            (while (not (concur-await-latch-signaled-p latch))
              (sit-for concur-await-poll-interval))

            ;; When the loop exits, check how it was signaled.
            (if (eq (concur-await-latch-signaled-p latch) 'timeout)
                (error 'concur:timeout-error
                       (format "Await for %s timed out after %s seconds"
                               (concur:format-promise watched-promise)
                               timeout))
              ;; Otherwise, the promise settled normally.
              (if-let ((err (concur:error-value watched-promise)))
                  (signal (car err) (cdr err))
                (concur:value watched-promise))))
        ;; Cleanup form: always cancel the timer if it exists.
        (when timer (cancel-timer timer))))))

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
  (apply #'%%make-promise
         :id (gensym "promise-")
         slots))

;;;###autoload
(defmacro concur:with-executor (executor-fn-form &optional cancel-token-form)
  "Create a promise and immediately invoke EXECUTOR-FN-FORM.
This is the fundamental promise constructor. The EXECUTOR-FN-FORM is
a lambda `(lambda (resolve reject) ...)` that contains the asynchronous logic.
The promise's state is determined by which of these functions is called.

Arguments:
- EXECUTOR-FN-FORM (form): A lambda `(lambda (resolve reject))` that
  contains the asynchronous logic. Its free variables will be lifted.
- CANCEL-TOKEN-FORM (form, optional): An expression evaluating to a
  `concur-cancel-token` to link to this promise's lifecycle.

Returns:
A new `concur-promise`."
  (declare (indent 1) (debug t))
  (let* ((promise (gensym "promise-"))
         (resolve (gensym "resolve-"))
         (reject (gensym "reject-"))
         (cancel-token (gensym "cancel-token-"))
         ;; The AST lifter needs to know that `resolve` and `reject` are
         ;; parameters to the executor, not free variables to be lifted.
         (param-alist `((,resolve . ,resolve) (,reject . ,reject)))
         ;; Lift the user's executor function.
         (lift-info (concur--process-handler executor-fn-form "executor" param-alist))
         (lifted-executor (car lift-info))
         (captured-vars (cdr lift-info))
         ;; Generate the code that will build the `extra-data` alist at runtime.
         (context-form `(list ,@(mapcar (lambda (v) `(cons ',v ,v)) captured-vars))))
    `(let* ((,promise (concur:make-promise))
            (,cancel-token ,(or cancel-token-form nil)))
       ;; Associate cancel token if provided.
       (when ,cancel-token
         (setf (concur-promise-cancel-token ,promise) ,cancel-token))

       (condition-case err
           ;; Call the lifted executor function. It now expects an `extra-data`
           ;; alist as its final argument, in addition to `resolve` and `reject`.
           (funcall ,lifted-executor
                    (lambda (value) (concur:resolve ,promise value))
                    (lambda (error) (concur:reject ,promise error))
                    ,context-form)
         ;; Handle errors that occur during the synchronous portion of the executor.
         (error
          (concur:reject ,promise `(executor-error :original-error ,err))))
       ,promise)))

(defun concur:resolve (target-promise result)
  "Resolve a promise with a success RESULT.
If RESULT is itself a promise, `target-promise` will adopt its state
(this is the Promise/A+ 'thenable' flattening behavior).

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to resolve.
- RESULT (any): The value to resolve the promise with.

Returns:
The `target-promise`."
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
  (let ((final-error error))
    ;; If there's an active async stack and the error is a plist,
    ;; attach the stack trace to it.
    (when (and concur--current-async-stack (listp error))
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
  (unless (concur-promise-resolved-p cancellable-promise)
    (when-let ((proc (concur-promise-proc cancellable-promise)))
      (when (process-live-p proc) (ignore-errors (kill-process proc))))
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
  `(if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
       ;; Inside a coroutine, yield to the scheduler.
       (let ((awaited-promise ,promise-form))
         (if (concur-promise-resolved-p awaited-promise)
             (if-let ((err (concur:error-value awaited-promise)))
                 (signal (car err) (cdr err))
               (concur:value awaited-promise))
           (yield--internal-throw-form awaited-promise
                                       ',yield--await-external-status-key)))
     ;; Outside a coroutine, use the cooperative blocking helper.
     (concur--await-blocking ,promise-form ,timeout)))

(defun concur:status (promise)
  "Return the current status of a PROMISE without blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to inspect.

Returns:
A symbol: one of `'pending`, `'resolved`, `'rejected`, or `'cancelled`."
  (unless (concur-promise-p promise)
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
    (error "Invalid promise object: %S" promise))
  (eq (concur:status promise) 'pending))

(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has been resolved successfully.

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is resolved, `nil` otherwise."
  (unless (concur-promise-p promise)
    (error "Invalid promise object: %S" promise))
  (eq (concur:status promise) 'resolved))

(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE has been rejected (including cancellation).

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is rejected or cancelled, `nil` otherwise."
  (unless (concur-promise-p promise)
    (error "Invalid promise object: %S" promise))
  (memq (concur:status promise) '(rejected cancelled)))

(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE has been cancelled.

Arguments:
- PROMISE (`concur-promise`): The promise to check.

Returns:
`t` if the promise is cancelled, `nil` otherwise."
  (unless (concur-promise-p promise)
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
- P (any): The object to format (ideally a `concur-promise`).

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