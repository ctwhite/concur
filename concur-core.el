;;; concur-core.el --- Core functionality for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This file defines the fundamental `concur-promise` data structure and
;; the core operations for creating, resolving, and rejecting promises.
;; It includes the low-level asynchronous scheduling mechanisms and
;; thread-safety primitives necessary for robust concurrent execution.
;;
;; Key features include:
;; - `concur-promise` struct: The central data structure for a promise.
;; - Promise states: pending, resolved, rejected.
;; - `concur:make-promise`: For creating new, deferrable promises.
;; - `concur:resolved!`, `concur:rejected!`: For creating pre-settled promises.
;; - `concur:resolve`, `concur:reject`: For settling deferrable promises.
;; - `concur:value`, `concur:error-value`: For retrieving promise outcomes.
;; - Status predicates like `concur:resolved-p` for checking promise states.
;; - `concur:make-lock`, `concur:with-mutex!`: For thread-safe state changes.
;;   These primitives are sourced from `concur-primitives.el`.
;; - `concur:with-executor`: A convenient macro for defining executor logic.
;;
;; This version incorporates a dedicated microtask queue (`concur-microtask`)
;; and a priority queue for macrotasks, significantly improving scheduling
;; behavior and responsiveness for both `await` and `.then` style workflows.
;;
;; A key enhancement is the `concur-normalize-awaitable-hook`, allowing
;; external libraries to register functions for converting custom "awaitable"
;; objects into standard `concur-promise` instances, promoting extensibility.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'ht)
(require 's)

(require 'concur-hooks)
(require 'concur-cancel)
(require 'concur-primitives)
(require 'concur-ast)
(require 'concur-priority-queue)
(require 'concur-microtask)

;; Forward declarations for byte-compiler
(declare-function concur:then "concur-chain" (promise 
      &optional on-resolved-form on-rejected-form
      &environment env))
(declare-function concur:race "concur-combinators" (promise-list))

(defvar yield--await-external-status-key)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants and Customization

(defgroup concur nil
  "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defconst concur-log-value-max-length 100
  "Maximum length of a value/error string in log messages before truncation.")

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, signal an error for unhandled promise rejections.
When a promise is rejected but has no rejection handlers attached,
this setting controls whether to silently ignore it or to signal a
`concur-unhandled-rejection` error, which can be useful for debugging."
  :type 'boolean
  :group 'concur)

(defcustom concur-executor-batch-size 10
  "Maximum number of callbacks to process in one idle cycle.
Limits burstiness of Promise callback execution."
  :type 'integer
  :group 'concur)

(defcustom concur-await-poll-interval 0.01
  "The polling interval (in seconds) for `concur:await`.
This value controls the sleep time in the cooperative waiting loop.
A smaller value (e.g. 0.001) increases responsiveness at the cost of higher
CPU usage. A larger value (e.g. 0.1) reduces CPU usage but increases the
latency for `await` to unblock."
  :type 'float
  :group 'concur)

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
High-level functions like `concur:async!` manage this stack to provide
richer debugging information on promise rejection.")
  
(define-error 'concur-unhandled-rejection "A promise was rejected with no handler.")
(define-error 'concur-await-error "An error occurred while awaiting a promise." 'concur-error)
(define-error 'concur-cancel-error "A promise was cancelled." 'concur-error)

(defconst concur--promise-cancelled-key 'concur-cancel-error
  "The symbol used to identify cancellation errors.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(eval-and-compile
  (cl-defstruct (concur-promise (:constructor %%make-promise))
    "Represents an asynchronous operation that can resolve or reject.
This struct should not be manipulated directly. Use the `concur:` functions.

Fields:
- `id` (symbol): A unique identifier for the promise, for logging.
- `result` (any): The value the promise resolved with.
- `error` (any): The error condition the promise was rejected with.
- `state` (symbol): The current state, one of `:pending`, `:resolved`, or `:rejected`.
- `callbacks` (list): A list of `concur-callback-link` structs.
- `cancel-token` (`concur-cancel-token`): An optional token for cancellation.
- `cancelled-p` (boolean): `t` if rejection was due to cancellation.
- `proc` (process): An optional external process to kill on cancel.
- `lock` (`concur-lock`): A mutex to protect internal state."
    (id nil :type symbol)
    (result nil)
    (error nil)
    (state :pending :type (member :pending :resolved :rejected))
    (callbacks '() :type list)
    (cancel-token nil :type (or concur-cancel-token null))
    (cancelled-p nil :type boolean)
    (proc nil)
    (lock (concur:make-lock) :type concur-lock)))

(eval-and-compile
  (cl-defstruct (concur-await-latch (:constructor %%make-await-latch))
    "Internal latch used by the cooperative blocking `concur:await`.
This struct provides a simple, mutable flag that is shared between the
`await` loop and the promise's settlement callbacks.

Fields:
- `signaled-p` (boolean or `t`): `t` if the latch has been signaled by a
  settled promise, or `'timeout` if it timed out."
    (signaled-p nil :type (or boolean (eql timeout)))))

(eval-and-compile
  (cl-defstruct (concur-callback (:constructor %%make-callback))
    "An internal struct wrapping a callback function and its context.
This struct explicitly carries the full context needed to execute a handler
asynchronously, including any captured lexical variables.

Fields:
- `type` (symbol): The type of handler, e.g., `:resolved`, `:rejected`, `:await-latch`.
- `fn` (function): The actual callback function to execute.
- `promise` (`concur-promise`): The promise this callback will settle.
- `context` (form): A Lisp form (typically an alist) that, when `eval`'d,
  recreates the lexical context for the handler.
- `priority` (integer): A numerical priority for scheduling. Lower values
  indicate higher priority."
    (type nil :type (member :resolved :rejected :finally :tap :await-latch))
    (fn nil :type function)
    (promise nil :type concur-promise)
    (context nil :type (or hash-table null))
    (priority 50 :type integer)))

(eval-and-compile
  (cl-defstruct (concur-callback-link (:constructor %%make-callback-link))
    "Represents one link in a promise chain.
A single call to `.then` can attach both a resolved and a rejected handler.
This struct groups those related handlers together with a unique ID.

Fields:
- `id` (symbol): A unique identifier for this link in the chain.
- `callbacks` (list): The list of `concur-callback` structs associated
  with this link."
    (id nil :type symbol)
    (callbacks '() :type list)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Core Promise Logic

(defvar concur--scheduled-callbacks-pq nil
  "A global `concur-priority-queue` of callbacks scheduled for deferred
execution (macrotasks). This processes higher-priority callbacks first.")

(defvar concur--callback-processing-lock (concur:make-lock "concur--callback-processing-lock")
  "A global lock to protect both `concur--scheduled-callbacks-pq` and
`concur--idle-timer` to ensure atomic scheduling operations.")

(defvar concur--idle-timer nil
  "The timer used to schedule deferred callback processing.")

(cl-defun concur--init-executor-queues ()
  "Initializes the executor's priority queue."
  (unless concur--scheduled-callbacks-pq
    (setq concur--scheduled-callbacks-pq
          (concur-priority-queue-create
           :comparator (lambda (cb1 cb2)
                         (< (concur-callback-priority cb1)
                            (concur-callback-priority cb2)))))))
(concur--init-executor-queues)

(defun concur--format-value-or-error-for-log (value)
  "Format a value or error for concise logging, truncating if necessary.

Arguments:
- VALUE (any): The Lisp object to format.

Returns:
- (string): A concise string representation of VALUE."
  (let ((str (format "%S" value)))
    (if (> (length str) concur-log-value-max-length)
        (concat (substring str 0 concur-log-value-max-length) "...")
      str)))

(defun concur--schedule-callbacks (callbacks-list)
  "Schedules a list of callbacks for deferred processing by the executor."
  (concur--log :debug "[CORE] Scheduling %d macrotask callbacks" (length callbacks-list))
  (concur:with-mutex! concur--callback-processing-lock
    (--each callbacks-list
            (lambda (cb)
              (concur-priority-queue-insert concur--scheduled-callbacks-pq cb)))
    (unless concur--idle-timer
      (setq concur--idle-timer
            (run-with-idle-timer 0.001 t #'concur--run-executor-batch)))))

(defun concur--run-executor-batch ()
  "Executes a batch of scheduled callbacks from the macrotask queue."
  (let (batch)
    (concur:with-mutex! concur--callback-processing-lock
      (setq batch (concur-priority-queue-pop-n
                   concur--scheduled-callbacks-pq concur-executor-batch-size))
      (when (concur-priority-queue-empty-p concur--scheduled-callbacks-pq)
        (when concur--idle-timer (cancel-timer concur--idle-timer))
        (setq concur--idle-timer nil)))
    (when batch
      (concur--log :debug "[CORE] Running executor batch of %d callbacks" (length batch))
      (--each batch
              (lambda (cb)
                (concur-process-scheduled-callbacks-batch
                 (concur-callback-promise cb)
                 (list cb)))))))

(defun concur--on-resolve (promise &rest callbacks)
  "Internal primitive to attach a set of callbacks to a promise.
This is the low-level building block for `.then`, `.finally`, etc.
It handles the critical logic of either scheduling callbacks immediately if
the promise is already settled, or adding them to the promise's callback
list if it is still pending.

Arguments:
- PROMISE (`concur-promise`): The promise to attach callbacks to.
- CALLBACKS (list of `concur-callback`): The callbacks to attach.

Returns:
- nil."
  (let* ((non-nil-callbacks (-filter #'identity callbacks))
         (link (%%make-callback-link :id (gensym "link-")
                                     :callbacks non-nil-callbacks)))
    (concur:with-mutex! (concur-promise-lock promise)
      (if (not (eq (concur-promise-state promise) :pending))
          ;; --- Promise is already settled ---
          (let ((microtasks '())
                (macrotasks '()))
            (dolist (cb (concur-callback-link-callbacks link))
              (if (eq (concur-callback-type cb) :await-latch)
                  (push cb microtasks)
                (push cb macrotasks)))
            (when microtasks (concur-microtask-queue-add promise (nreverse microtasks)))
            (when macrotasks (concur--schedule-callbacks (nreverse macrotasks)))
            ;; Immediately drain microtasks to unblock any `await` calls.
            (concur-microtask-queue-drain))
        ;; --- Promise is pending ---
        (push link (concur-promise-callbacks promise))))))

(defun concur--resolve-with-maybe-promise (promise value)
  "Resolves `PROMISE` with `VALUE`, handling promise-chaining.
Implements the Promise/A+ `thenable` resolution procedure. If `VALUE`
is itself a promise, `PROMISE` will adopt its state.

Arguments:
- PROMISE (`concur-promise`): The promise to resolve.
- VALUE (any): The value to resolve with.

Returns:
- nil."
  (let ((normalized-value
         (if (concur-promise-p value)
             value
           (or (run-hook-with-args-until-success 'concur-normalize-awaitable-hook
                                                 value)
               value))))
    (if (eq promise normalized-value)
        (concur--settle-promise promise nil (error "TypeError: A promise cannot be resolved with itself.") nil)
      (if (concur-promise-p normalized-value)
          (progn
            (concur--log :debug "[CORE] Chaining %s to adopt state from %s"
                         (concur:format-promise promise)
                         (concur:format-promise normalized-value))
            (concur--on-resolve
             normalized-value
             (concur--make-resolved-callback
              (lambda (res-val ctx)
                (concur:resolve (cdr (assoc 'target-promise ctx)) res-val))
              promise :context (list (cons 'target-promise promise)))
             (concur--make-rejected-callback
              (lambda (rej-err ctx)
                (concur:reject (cdr (assoc 'target-promise ctx)) rej-err))
              promise :context (list (cons 'target-promise promise)))))
        (concur--settle-promise promise value nil nil)))))

(defun concur--settle-promise (promise result error is-cancellation)
  "Internal function to settle a promise (resolve or reject).
This is the only function that should ever mutate a promise's core state.
It ensures thread-safety and idempotency (a promise can only be settled once).

Arguments:
- PROMISE (`concur-promise`): The promise to settle.
- RESULT (any): The resolution value (if successful).
- ERROR (any): The rejection error (if failed).
- IS-CANCELLATION (boolean): True if rejection is due to cancellation.

Returns:
- (`concur-promise`): The settled promise."
  (concur:with-mutex! (concur-promise-lock promise)
    ;; The core idempotency check: only proceed if the promise is pending.
    (when (eq (concur-promise-state promise) :pending)
      (let ((new-state (if error :rejected :resolved)))
        (concur--log :debug "[CORE] Settling %s -> %S with %s"
                     (concur:format-promise promise)
                     new-state
                     (concur--format-value-or-error-for-log (or result error)))
        (setf (concur-promise-result promise) result)
        (setf (concur-promise-error promise) error)
        (setf (concur-promise-cancelled-p promise) is-cancellation)
        (setf (concur-promise-state promise) new-state)

        (concur--run-callbacks promise)
        (concur-microtask-queue-drain)

        (when-let ((proc (concur-promise-proc promise)))
          (when (process-live-p proc)
            (delete-process proc))
          (setf (concur-promise-proc promise) nil)))))
  promise)

(defun concur--run-callbacks (promise)
  "Schedules registered callbacks on PROMISE after it has settled.
This function separates callbacks into high-priority microtasks (for `await`)
and normal-priority macrotasks (for `.then` handlers) to ensure correct
execution order and responsiveness.

Arguments:
- PROMISE (`concur-promise`): The promise that has just settled.

Returns:
- nil."
  (let ((callback-links (concur-promise-callbacks promise))
        (microtasks '())
        (macrotasks '()))
    (setf (concur-promise-callbacks promise) nil) ; Clear callbacks after scheduling.

    (dolist (link callback-links)
      (dolist (cb (concur-callback-link-callbacks link))
        (if (eq (concur-callback-type cb) :await-latch)
            (push cb microtasks)
          (push cb macrotasks))))

    (when microtasks (concur-microtask-queue-add promise (nreverse microtasks)))
    (when macrotasks (concur--schedule-callbacks (nreverse macrotasks)))

    ;; Check for unhandled rejections.
    (when (and (eq (concur-promise-state promise) :rejected)
               (null microtasks) (null macrotasks))
      (concur--log :warn "[CORE] Unhandled rejection in %s: %s"
                   (concur:format-promise promise)
                   (concur--format-value-or-error-for-log (concur-promise-error promise)))
      (run-hook-with-args 'concur-unhandled-rejection-hook
                          promise (concur-promise-error promise))
      (when concur-throw-on-promise-rejection
        (signal 'concur-unhandled-rejection
                (list (concur-promise-error promise) promise))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Callback Creation

(defun concur--merge-contexts (existing-context captured-vars)
  "Merge `existing-context` with `captured-vars` into a single alist."
  (cond ((and (listp existing-context) (listp captured-vars))
         (append existing-context captured-vars))
        ((listp existing-context) existing-context)
        ((listp captured-vars) captured-vars)
        (t nil)))

(cl-defun concur--make-resolved-callback (handler target-promise
                                           &key context captured-vars)
  "Create a `concur-callback` for a resolved handler."
  (%%make-callback :type :resolved
                   :fn handler
                   :promise target-promise
                   :context (concur--merge-contexts context captured-vars)))

(cl-defun concur--make-rejected-callback (handler target-promise
                                           &key context captured-vars)
  "Create a `concur-callback` for a rejected handler."
  (%%make-callback :type :rejected
                   :fn handler
                   :promise target-promise
                   :context (concur--merge-contexts context captured-vars)))

(cl-defun concur--make-finally-callback (handler target-promise
                                          &key context captured-vars)
  "Create a `concur-callback` for a finally handler."
  (%%make-callback :type :finally
                   :fn handler
                   :promise target-promise
                   :context (concur--merge-contexts context captured-vars)))

(cl-defun concur--make-tap-callback (handler target-promise
                                      &key context captured-vars)
  "Create a `concur-callback` for a tap handler."
  (%%make-callback :type :tap
                   :fn handler
                   :promise target-promise
                   :context (concur--merge-contexts context captured-vars)))

(cl-defun concur--make-await-latch-callback (latch target-promise
                                              &key context captured-vars)
  "Create a `concur-callback` for an await latch."
  (let ((final-context (concur--merge-contexts (list (cons 'latch latch))
                                               context)))
    (setq final-context (concur--merge-contexts final-context captured-vars))
    (%%make-callback :type :await-latch
                     :fn (lambda () nil) ; Dummy handler.
                     :promise target-promise
                     :context final-context)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers - Await Blocking

(defun concur--await-blocking (watched-promise &optional timeout)
  "Blocking (but cooperative) implementation of `await`.

Arguments:
- WATCHED-PROMISE (`concur-promise`): The promise to wait for.
- TIMEOUT (number): Optional max time in seconds to wait.

Returns:
- (any): The resolved value of `watched-promise`.

Signals:
- `concur-timeout`: If the timeout is exceeded.
- `concur-await-error`: If the `watched-promise` rejects."
  (unless (concur-promise-p watched-promise)
    (error "concur--await-blocking: Invalid promise object: %S" watched-promise))

  (if (not (eq (concur:status watched-promise) :pending))
      (if-let ((err (concur:error-value watched-promise)))
          (signal 'concur-await-error (list err))
        (concur:value watched-promise))

    (let ((latch (%%make-await-latch))
          (timer nil))
      (unwind-protect
          (progn
            (concur--log :debug "[CORE] Await: blocking for %s (timeout: %s)"
                         (concur:format-promise watched-promise)
                         (or timeout "none"))
            (concur--on-resolve
             watched-promise
             (concur--make-await-latch-callback latch watched-promise))
            (when timeout
              (setq timer
                    (run-at-time timeout nil
                                 (lambda ()
                                   (setf (concur-await-latch-signaled-p latch) 'timeout)))))
            (while (not (concur-await-latch-signaled-p latch))
              (sit-for concur-await-poll-interval))

            (concur--log :debug "[CORE] Await: unblocked for %s (status: %s)"
                         (concur:format-promise watched-promise)
                         (concur-await-latch-signaled-p latch))
            (if (eq (concur-await-latch-signaled-p latch) 'timeout)
                (signal 'concur-timeout
                       (list (format "Await for %s timed out" (concur:format-promise watched-promise))))
              (if-let ((err (concur:error-value watched-promise)))
                  (signal 'concur-await-error (list err))
                (concur:value watched-promise))))
        (when timer
          (cancel-timer timer))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Utilities

  (defun concur-safe-ht-get (hash-table key &optional default)
    "Safely get `KEY` from `HASH-TABLE`.
This is a simple utility to avoid errors when the context object inside
a macro expansion might not be a hash-table during certain compiler passes.

Arguments:
- HASH-TABLE (hash-table or any): The hash-table to look up in.
- KEY (any): The key to retrieve.
- DEFAULT (any, optional): The default value to return if key is not found.

Returns:
- (any): The value associated with KEY, or DEFAULT."
    (if (hash-table-p hash-table)
        (gethash key hash-table default)
      default))
      
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Promise Construction and Basic Operations)

;;;###autoload
(defun concur-process-scheduled-callbacks-batch (promise callbacks)
  "Executes a batch of scheduled promise callbacks.
This is a core utility used by macrotask and microtask queues.

Arguments:
- PROMISE (`concur-promise`): The promise that settled, triggering these 
callbacks.
- CALLBACKS (list of `concur-callback`): The list of callbacks to execute.

Returns:
- nil."
  (dolist (callback callbacks)
    (let* ((handler (concur-callback-fn callback))
           (type (concur-callback-type callback))
           (target-promise (concur-callback-promise callback))
           ;; Crucial: Evaluate the `context` to bring lexical vars into scope.
           (context (eval (concur-callback-context callback)))
           (result (concur-promise-result promise))
           (error (concur-promise-error promise)))
      (condition-case err
          (pcase type
            (:resolved
             (when (not error) (funcall handler result context)))
            (:rejected
             (when error (funcall handler error context)))
            (:finally
             (funcall handler result error))
            (:tap
             (funcall handler result error context))
            ;; This case is handled by the microtask queue's specific logic.
            (:await-latch
             (when-let (latch (cdr (assoc 'latch context)))
               (setf (concur-await-latch-signaled-p latch) t))))
        ('error
         (concur--log :error "[CORE] Callback failed in %S for %s: %S"
                      type (concur:format-promise promise) err))))))

;;;###autoload
(defun concur:make-promise (&rest slots)
  "Create a new, deferrable `concur-promise`.
This is a low-level constructor. Prefer using `concur:with-executor`
or higher-level functions like `concur:async!` for creating promises
that perform asynchronous work.

Arguments:
- SLOTS (plist): Optional initial values for the promise struct slots.

Returns:
- (`concur-promise`): A new, pending `concur-promise`."
  (let ((p (apply #'%%make-promise :id (gensym "promise-") slots)))
    (concur--log :debug "[CORE] Created %s" (concur:format-promise p))
    (when (and (concur-promise-cancel-token p)
               (fboundp 'concur:cancel-token-add-callback))
      (concur:cancel-token-add-callback
       (concur-promise-cancel-token p)
       (lambda () (concur:cancel p))))
    p))

;;;###autoload
(defun concur:resolve (target-promise result)
  "Resolve a `TARGET-PROMISE` with a `RESULT`.

If `RESULT` is itself a promise, `TARGET-PROMISE` will adopt its
state (this is the Promise/A+ `thenable` flattening behavior).

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to resolve.
- RESULT (any): The value to resolve the promise with.

Returns:
- (`concur-promise`): The `TARGET-PROMISE`."
  (concur--resolve-with-maybe-promise target-promise result)
  target-promise)

;;;###autoload
(defun concur:reject (target-promise error &optional is-cancellation)
  "Reject a `TARGET-PROMISE` with an `ERROR`.

If the dynamic variable `concur--current-async-stack` is bound,
its value will be captured and added to the error object.

Arguments:
- TARGET-PROMISE (`concur-promise`): The promise to reject.
- ERROR (any): The reason for the rejection, typically a Lisp condition.
- IS-CANCELLATION (boolean, optional): If non-nil, mark as a cancellation.

Returns:
- (`concur-promise`): The `TARGET-PROMISE`."
  (let ((final-error error))
    (when (and concur--current-async-stack (plistp error))
      (setq final-error
            (append error `(:async-stack-trace
                            ,(mapconcat 'identity
                                        (reverse concur--current-async-stack)
                                        "\n↳ ")))))
    (concur--settle-promise target-promise nil final-error is-cancellation)))

;;;###autoload
(defun concur:resolved! (value)
  "Return a new promise that is already resolved with `VALUE`.

Arguments:
- VALUE (any): The value for the new resolved promise.

Returns:
- (`concur-promise`): A new, already-resolved `concur-promise`."
  (let ((p (concur:make-promise)))
    (concur:resolve p value)
    p))

;;;###autoload
(defun concur:rejected! (error)
  "Return a new promise that is already rejected with `ERROR`.

Arguments:
- ERROR (any): The error condition for the new rejected promise.

Returns:
- (`concur-promise`): A new, already-rejected `concur-promise`."
  (let ((p (concur:make-promise)))
    (concur:reject p error)
    p))

;;;###autoload
(defun concur:cancel (cancellable-promise &optional reason)
  "Cancel a PROMISE by rejecting it with a cancellation reason.
If the promise has an associated process, this also kills that process.

Arguments:
- CANCELLABLE-PROMISE (`concur-promise`): The promise to cancel.
- REASON (string, optional): A message explaining the cancellation.

Returns:
- (`concur-promise`): The (now rejected) `CANCELLABLE-PROMISE`."
  (unless (not (eq (concur:status cancellable-promise) :pending))
    (concur--log :debug "[CORE] Cancelling %s (reason: %s)"
                 (concur:format-promise cancellable-promise) (or reason "N/A"))
    (when-let ((proc (concur-promise-proc cancellable-promise)))
      (when (process-live-p proc)
        (ignore-errors (kill-process proc))))
    (concur:reject cancellable-promise
                   `(,concur--promise-cancelled-key
                     :message ,(or reason "Promise cancelled"))
                   t))
  cancellable-promise)

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
When used within a `defasync!` coroutine, this macro will yield
control until the promise settles. When used outside a
coroutine, it will cooperatively block the Emacs event loop
until the promise settles.

Arguments:
- PROMISE-FORM (form): A form that evaluates to a `concur-promise`.
- TIMEOUT (number, optional): Max time in seconds to wait.

Returns:
- (any): The resolved value of the `PROMISE-FORM`.

Signals:
- `concur-timeout`: If the `TIMEOUT` is exceeded.
- `concur-await-error`: If the `PROMISE-FORM` rejects."
  (declare (indent 1) (debug t))
  `(if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
       ;; Inside a coroutine, yield to the scheduler.
       (let ((awaited-promise ,promise-form))
         (if (not (eq (concur:status awaited-promise) :pending))
             (if-let ((err (concur:error-value awaited-promise)))
                 (signal 'concur-await-error (list err))
               (concur:value awaited-promise))
           (yield--internal-throw-form awaited-promise
                                       ',yield--await-external-status-key)))
     ;; Outside a coroutine, use the cooperative blocking helper.
     (concur--await-blocking ,promise-form ,timeout)))

;;;###autoload
(defun concur:status (promise)
  "Return the current status of a PROMISE without blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to inspect.

Returns:
- (symbol): One of `:pending`, `:resolved`, or `:rejected`."
  (unless (concur-promise-p promise)
    (error "Invalid promise object: %S" promise))
  (concur-promise-state promise))

;;;###autoload
(defun concur:pending-p (promise)
  "Return non-nil if PROMISE is currently pending."
  (eq (concur:status promise) :pending))

;;;###autoload
(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has been resolved successfully."
  (eq (concur:status promise) :resolved))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE has been rejected."
  (eq (concur-promise-state promise) :rejected))

;;;###autoload
(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE has been cancelled."
  (concur-promise-cancelled-p promise))

;;;###autoload
(defun concur:value (promise)
  "Return the resolved value of a PROMISE, or nil if not resolved.
This function is non-blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to inspect.

Returns:
- (any): The resolved value, or nil."
  (when (eq (concur:status promise) 'resolved)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return the error value of a PROMISE if rejected, else nil.
This function is non-blocking.

Arguments:
- PROMISE (`concur-promise`): The promise to inspect.

Returns:
- (any): The rejection error, or nil."
  (when (eq (concur-promise-state promise) :rejected)
    (concur-promise-error promise)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return a human-readable message from a promise's error or an error object.

Arguments:
- PROMISE-OR-ERROR (`concur-promise` or any): The promise or error value.

Returns:
- (string): A formatted string representing the error."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (cond ((stringp err) err)
          ((plistp err) (or (plist-get err :message) (format "%S" err)))
          ((symbolp err) (symbol-name err))
          (err (format "%S" err))
          (t "Unknown error"))))

;;;###autoload
(defun concur:format-promise (p)
  "Return a human-readable string representation of a promise.
Intended for logging/debugging to provide a concise summary.

Arguments:
- P (any): The object to format (preferably a `concur-promise`).

Returns:
- (string): A formatted string."
  (if (concur-promise-p p)
      (let ((status (concur:status p))
            (val (concur:value p))
            (err (concur:error-value p))
            (id (concur-promise-id p)))
        (pcase status
          (:pending (format "#<concur-promise %s: pending>" id))
          (:resolved (format "#<concur-promise %s: resolved with %s>"
                             id (concur--format-value-or-error-for-log val)))
          (:rejected (format "#<concur-promise %s: rejected with %s>"
                             id (concur--format-value-or-error-for-log err)))))
    (format "%S" p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Executor & Thread Safety)

;;;###autoload
(cl-defmacro concur:with-executor (executor-fn-form &key cancel-token &environment env)
  "Define and execute an asynchronous block that manages its own promise.
This macro provides a controlled environment for starting asynchronous
operations. `EXECUTOR-FN-FORM` is a lambda `(lambda (resolve reject) ...)`
which receives `resolve` and `reject` functions to control the promise.

Arguments:
- EXECUTOR-FN-FORM (function): A lambda `(lambda (resolve reject) ...)`
  that contains the asynchronous logic.
- :cancel-token (`concur-cancel-token`, optional): For cancellability.
- env (implicit): The lexical environment for macro expansion.

Returns:
- (`concur-promise`): A promise that will be settled by the executor."
  (declare (indent 1) (debug t))
  (let* ((promise (gensym "promise-"))
         (cancel-token-val (gensym "cancel-token-val-"))
         (executor-analysis (concur-ast-analysis executor-fn-form env nil))
         (original-lambda
          (concur-ast-analysis-result-expanded-callable-form executor-analysis))
         (free-vars (concur-ast-analysis-result-free-vars-list executor-analysis))
         (context-form (concur-ast-make-captured-vars-form free-vars)))

    (let ((err-sym (gensym "err-")))
      `(let* ((,promise (concur:make-promise))
              (,cancel-token-val ,cancel-token))
         (when ,cancel-token-val
           (setf (concur-promise-cancel-token ,promise) ,cancel-token-val))
         (concur--log :debug "[CORE] Starting executor for %s" (concur:format-promise ,promise))
         (condition-case ,err-sym
             (let ((resolve (lambda (value) (concur:resolve ,promise value)))
                   (reject (lambda (error) (concur:reject ,promise error)))
                   (context ,context-form))
               (let ,(cl-loop for var in free-vars
                              collect `(,var (concur-safe-ht-get context ',var)))
                 (funcall ,original-lambda resolve reject)))
           (error
            (concur--log :error "[CORE] Executor for %s failed on init: %S" (concur:format-promise ,promise) ,err-sym)
            (concur:reject ,promise `(executor-error :original-error ,,err-sym))))
         ,promise))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Utilities and Integrations

;;;###autoload
(defmacro concur:from-callback (fetch-fn-form)
  "Wrap a callback-based async function into a `concur-promise`.
The function `FETCH-FN-FORM` should expect a single callback argument,
which will be invoked as `(callback result error)`.

Arguments:
- FETCH-FN-FORM (form): An expression evaluating to a function that
  takes one argument: a callback of the form `(lambda (result error) ...)`.

Returns:
- (`concur-promise`): A promise that resolves with `result` or rejects with 
`error`."
  (declare (indent 1) (debug t))
  `(concur:with-executor
       (lambda (resolve reject)
         (funcall ,fetch-fn-form
                  (lambda (result error)
                    (if error
                        (funcall reject error)
                      (funcall resolve result)))))))

;;;###autoload
(defmacro concur:catch (promise-form &rest body)
  "Attach a rejection handler to a promise.
This is syntactic sugar for `(concur:then PROMISE-FORM nil (lambda (err) ...))`

Arguments:
- PROMISE-FORM (form): A form that evaluates to a `concur-promise`.
- BODY (forms): The forms to execute if the promise is rejected. The error
  is available in the `err` variable.

Returns:
- (`concur-promise`): A new promise."
  (declare (indent 1) (debug t))
  `(concur:then ,promise-form nil (lambda (err) ,@body)))

(cl-defun concur:promise-semaphore-acquire (sem &key timeout)
  "Acquire a slot from SEM, returning a promise.

Arguments:
- SEM (`concur-semaphore`): The semaphore to acquire a slot from.
- :timeout (number, optional): Max time in seconds to wait for a slot.

Returns:
- (`concur-promise`): A promise that resolves with `t` on successful
  acquisition, or rejects with a `concur-timeout` error on timeout."
  (concur:with-executor
      (lambda (resolve reject)
        (concur:semaphore-acquire
         sem
         (lambda () (funcall resolve t))
         :timeout timeout
         :timeout-callback
         (lambda ()
           (funcall reject `(concur-timeout "Semaphore acquire timed out")))))))

(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with `VALUE` after `SECONDS`.

Arguments:
- SECONDS (number): The number of seconds to wait before resolving.
- VALUE (any, optional): The value the promise will resolve with.

Returns:
- (`concur-promise`): A promise that resolves after the specified delay."
  (concur:with-executor
      (lambda (resolve _reject)
        (run-at-time seconds nil
                     (lambda () (funcall resolve (or value t)))))))

(defun concur:timeout (timed-promise timeout-seconds)
  "Wrap a promise, rejecting it if it does not settle within a timeout.
This effectively races the original promise against a delay promise that
rejects.

Arguments:
- TIMED-PROMISE (`concur-promise`): The promise to apply a timeout to.
- TIMEOUT-SECONDS (number): The maximum number of seconds to wait.

Returns:
- (`concur-promise`): A new promise that adopts the state of the original
  promise, or rejects with a `concur-timeout` error."
  (concur:race
   (list timed-promise
         (concur:then (concur:delay timeout-seconds)
                      (lambda (_)
                        (concur:rejected!
                         `(concur-timeout "Promise timed out")))))))

(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an asynchronous function `FN` up to `RETRIES` times on failure.

Arguments:
- FN (function): A zero-argument function that returns a `concur-promise`.
- :retries (integer): Max number of retry attempts. Default is 3.
- :delay (number or function): Delay in seconds before each retry. If a
  function, it receives the attempt number and error, `(lambda (attempt err))`,
  and should return the delay time.
- :pred (function): A predicate `(lambda (error))` that returns non-nil if
  the given error should trigger a retry.

Returns:
- (`concur-promise`): A promise that resolves with `FN`'s successful
  result, or rejects if all retry attempts fail."
  (let ((retry-promise (concur:make-promise)) (attempt 0))
    (cl-labels
        ((delay-and-retry (err)
           (let ((d (if (functionp delay) (funcall delay attempt err) delay)))
             (concur:then (concur:delay d) #'do-try)))
         (do-try ()
           (concur:catch
            (funcall fn)
            (lambda (err)
              (if (and (< (cl-incf attempt) retries) (funcall pred err))
                  (delay-and-retry err)
                (concur:rejected! err))))))
      (concur:then (do-try)
                   (lambda (res) (concur:resolve retry-promise res))
                   (lambda (err) (concur:reject retry-promise err))))
    retry-promise))

(provide 'concur-core)
;;; concur-core.el ends here
