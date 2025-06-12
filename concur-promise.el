;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a lightweight yet comprehensive Promise implementation
;; for Emacs Lisp, designed to facilitate asynchronous programming patterns.
;; It allows for chaining operations, handling errors gracefully, and managing
;; concurrent tasks.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'ht)
(require 'ts)
(require 's)
(require 'subr-x)
(require 'concur-core)
(require 'concur-cancel)
(require 'concur-primitives)
(require 'coroutines)

;; Forward declarations for the byte-compiler
(declare-function macro-function "macro" (&rest args))
(declare-function yield! "coroutines" (value &optional tag))
(declare-function yield--internal-throw-form (value tag))
(declare-function resume! "coroutines" (runner &optional value))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants and Customization

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, unhandled rejected promises throw an error."
  :type 'boolean
  :group 'concur)

(defconst concur--promise-cancelled-key :cancelled
  "Keyword in rejection objects indicating cancellation.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(eval-and-compile
  (cl-defstruct (concur-promise
                 (:constructor %%make-promise))
    "Represents an asynchronous operation that can resolve or reject.

Fields:
- `result` (any): The resolved value of the promise.
- `error` (any): The error reason if the promise is rejected.
- `resolved-p` (boolean): `t` if the promise has settled (resolved or rejected).
- `callbacks` (list): A list of `concur-promise-callback-entry` objects
  waiting for the promise to settle.
- `cancel-token` (concur-cancel-token, optional): An associated cancellation token.
- `cancelled-p` (boolean): `t` if the promise was cancelled.
- `proc` (process, optional): An associated Emacs process, if any.
- `lock` (concur-lock): A mutex to protect internal state during modifications."
    (result nil)
    (error nil)
    (resolved-p nil :type boolean)
    (callbacks '() :type list)
    (cancel-token nil)
    (cancelled-p nil :type boolean)
    (proc nil)
    (lock (concur:make-lock))))

(eval-and-compile
  (cl-defstruct (concur-promise-callback-entry
                 (:constructor %%make-callback-entry
                               (id on-resolved on-rejected)))
    "Internal wrapper for a promise callback with a unique ID.

Fields:
- `id` (symbol): A unique identifier for the callback entry.
- `on-resolved` (function, optional): The callback to run on promise resolution.
- `on-rejected` (function, optional): The callback to run on promise rejection."
    (id nil)
    (on-resolved nil)
    (on-rejected nil)))

(eval-and-compile
  (cl-defstruct (concur-await-latch
                 (:constructor %%make-await-latch))
    "Internal latch used by the blocking implementation of `concur:await`.

Fields:
- `process` (process): A dummy process used for `accept-process-output`
  to cooperatively block.
- `signaled-p` (boolean): `t` if the latch has been signaled (promise settled)
  or `'timeout` if a timeout occurred."
    (process (start-process (format "await-latch-%s" (random)) nil nil))
    (signaled-p nil :type boolean)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--run-callbacks (promise)
  "Invoke registered callbacks on PROMISE after settlement.

Arguments:
- `PROMISE` (concur-promise): The promise whose callbacks should be run.

Returns:
`nil`."
  (let (callbacks promise-error promise-result)
    (concur:with-mutex! (concur-promise-lock promise)
        (:else (error "Impossible state: Contention in run-callbacks"))
      (setq callbacks (concur-promise-callbacks promise))
      (setq promise-error (concur-promise-error promise))
      (setq promise-result (concur-promise-result promise))
      (setf (concur-promise-callbacks promise) nil))
    (dolist (entry callbacks)
      (condition-case err
          (let ((on-resolved
                 (concur-promise-callback-entry-on-resolved entry))
                (on-rejected
                 (concur-promise-callback-entry-on-rejected entry)))
            (if promise-error
                (when on-rejected (funcall on-rejected promise-error))
              (when on-resolved (funcall on-resolved promise-result))))
        ('error (message "[concur] Callback failed: %S" err))))))

(defun concur--settle-promise (promise &optional value error is-cancellation)
  "Settle a PROMISE (resolve or reject).

This is an internal function that sets the promise's state to settled,
stores the result or error, and then runs all registered callbacks.

Arguments:
- `PROMISE` (concur-promise): The promise to settle.
- `VALUE` (any, optional): The value to resolve the promise with.
- `ERROR` (any, optional): The error reason to reject the promise with.
- `IS-CANCELLATION` (boolean, optional): `t` if the rejection is due to cancellation.

Returns:
The settled `PROMISE` object."
  (unless (concur-promise-resolved-p promise)
    (concur--log :debug "Settling promise: %S, Value: %S, Error: %S"
                 promise value error)
    (setf (concur-promise-result promise) value)
    (setf (concur-promise-error promise) error)
    (setf (concur-promise-resolved-p promise) t)
    (when is-cancellation
      (setf (concur-promise-cancelled-p promise) t))
    (concur--run-callbacks promise)
    (when (and error (not is-cancellation) concur-throw-on-promise-rejection)
      (error "[concur] Unhandled promise rejection: %S" error)))
  promise)

(defun concur--destroy-await-latch (latch)
  "Destroy the AWAIT-LATCH's associated process to free resources.

Arguments:
- `LATCH` (concur-await-latch): The latch to destroy.

Returns:
`nil`."
  (when (and (concur-await-latch-p latch)
             (process-live-p (concur-await-latch-process latch)))
    (delete-process (concur-await-latch-process latch))))

(defun concur--await-blocking (promise &optional timeout)
  "Blocking (but cooperative) implementation of `await`.

This function cooperatively blocks Emacs by yielding control
periodically until the given `PROMISE` settles or a `TIMEOUT` occurs.
It should be used with caution as it will pause UI interaction.

Arguments:
- `PROMISE` (concur-promise): The promise to wait for.
- `TIMEOUT` (number, optional): Maximum seconds to wait.

Returns:
The resolved value of the promise on success.

Errors:
- Signals the promise's error if it rejects.
- Signals `concur:timeout-error` if the timeout is reached."
  (if (concur-promise-resolved-p promise)
      (if-let ((err (concur:error-value promise)))
          (signal (car err) (cdr err))
        (concur:value promise))
    (let ((latch (%%make-await-latch)) (timer nil) (result nil) (had-error nil))
      (concur--log :debug "concur:await: Blocking until promise settles: %S"
                   promise)
      (unwind-protect
          (progn
            (concur:on-resolve
             promise
             (lambda (value)
               (setq result value)
               (setf (concur-await-latch-signaled-p latch) t))
             (lambda (err)
               (setq had-error err)
               (setf (concur-await-latch-signaled-p latch) t)))
            (when timeout
              (setq timer (run-at-time timeout nil
                           (lambda ()
                             (setf (concur-await-latch-signaled-p latch)
                                   'timeout)))))
            (while (not (concur-await-latch-signaled-p latch))
              (accept-process-output (concur-await-latch-process latch) 0.1))
            (when (eq (concur-await-latch-signaled-p latch) 'timeout)
              (concur:cancel promise "Await timed out")
              (error 'concur:timeout-error "Await timed out"))
            (concur--log :debug "concur:await: Finished blocking for %S"
                         promise)
            (if had-error
                (signal (car had-error) (cdr had-error))
              result))
        (when timer (cancel-timer timer))
        (concur--destroy-await-latch latch)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Promise API

;;;###autoload
(defun concur:make-promise (&rest slots)
  "Create and return a new unresolved (pending) promise.

Arguments:
- `SLOTS` (plist, optional): Initial slot values for the promise struct.

Returns:
A new `concur-promise` object in a pending state."
  (apply #'%%make-promise slots))

;;;###autoload
(defun concur:with-executor (executor-fn &optional cancel-token)
  "Create a promise and immediately invoke EXECUTOR-FN.

The `EXECUTOR-FN` is a function `(lambda (resolve reject))` that takes
two functions as arguments: `resolve` to resolve the promise with a value,
and `reject` to reject it with an error. The executor function is run
synchronously when `concur:with-executor` is called.

Arguments:
- `EXECUTOR-FN` (function): A function `(lambda (resolve reject))` that
  encapsulates the asynchronous operation.
- `CANCEL-TOKEN` (concur-cancel-token, optional): A cancellation token
  to associate with this promise.

Returns:
A `concur-promise` object."
  (unless (functionp executor-fn)
    (error "Executor must be a function, got %S" executor-fn))
  (let ((promise (concur:make-promise :cancel-token cancel-token)))
    (concur--log :debug "Executing promise with: %S" executor-fn)
    ;; Since `lexical-binding` is t, a standard `let` correctly creates a
    ;; closure over the `promise` variable.
    (condition-case err
        (let ((p promise))
          (funcall executor-fn
                   (lambda (value) (concur:resolve p value))
                   (lambda (error) (concur:reject p error))))
      (error
       (concur--log :error "Error in promise executor for %S: %S"
                    promise err)
       (concur:reject promise
                      `(:error-type executor-error
                        :message "Error in promise executor"
                        :original-error ,err))))
    promise))

;;;###autoload
(defun concur:resolve (promise result)
  "Resolve PROMISE with a success RESULT.

If the promise is already settled, this function does nothing.

Arguments:
- `PROMISE` (concur-promise): The promise to resolve.
- `RESULT` (any): The value to resolve the promise with.

Returns:
The `PROMISE` object."
  (concur--settle-promise promise result nil nil))

;;;###autoload
(defun concur:reject (promise error &optional is-cancellation)
  "Reject PROMISE with an ERROR reason.

If the promise is already settled, this function does nothing.

Arguments:
- `PROMISE` (concur-promise): The promise to reject.
- `ERROR` (any): The reason for the rejection. Can be a string, symbol, or plist.
- `IS-CANCELLATION` (boolean, optional): `t` if the rejection is due to cancellation.

Returns:
The `PROMISE` object."
  (concur--settle-promise promise nil error is-cancellation))

;;;###autoload
(defun concur:resolved! (value)
  "Return a new promise that is already resolved with VALUE.

This is a convenience function for creating promises that have
already successfully completed.

Arguments:
- `VALUE` (any): The value to resolve the promise with.

Returns:
A new `concur-promise` object in a resolved state."
  (let ((p (concur:make-promise)))
    (setf (concur-promise-result p) value
          (concur-promise-resolved-p p) t)
    p))

;;;###autoload
(defun concur:rejected! (error)
  "Return a new promise that is already rejected with ERROR.

This is a convenience function for creating promises that have
already failed.

Arguments:
- `ERROR` (any): The reason for the rejection.

Returns:
A new `concur-promise` object in a rejected state."
  (let ((p (concur:make-promise)))
    (setf (concur-promise-error p) error
          (concur-promise-resolved-p p) t)
    p))

;;;###autoload
(defun concur:cancel (promise &optional reason)
  "Cancel PROMISE by rejecting it with a cancellation reason.
Also kills any associated process if one exists and is live.

Arguments:
- `PROMISE` (concur-promise): The promise to cancel.
- `REASON` (string or plist, optional): A description for the cancellation.

Returns:
The `PROMISE` object."
  (unless (concur-promise-resolved-p promise)
    (concur--log :debug "Cancelling promise %S. Reason: %S" promise reason)
    (when-let ((proc (concur-promise-proc promise)))
      (when (process-live-p proc) (ignore-errors (kill-process proc))))
    (concur:reject promise
                   (if (and (consp reason)
                            (plist-member reason concur--promise-cancelled-key))
                       reason
                     `(,concur--promise-cancelled-key
                       ,(or reason "Promise cancelled")))
                   t))
  promise)

;;;###autoload
(defun concur:status (promise)
  "Return the current status of PROMISE without blocking.

Arguments:
- `PROMISE` (concur-promise): The promise to check.

Returns:
A symbol representing the promise's status:
- `'pending`: The promise has not yet settled.
- `'resolved`: The promise has successfully completed.
- `'rejected`: The promise has failed with an error.
- `'cancelled`: The promise was explicitly cancelled."
  (unless (concur-promise-p promise)
    (error "Invalid promise object: %S" promise))
  (cond ((not (concur-promise-resolved-p promise)) 'pending)
        ((concur-promise-cancelled-p promise) 'cancelled)
        ((concur-promise-error promise) 'rejected)
        (t 'resolved)))

;;;###autoload
(defun concur:value (promise)
  "Return the resolved value of PROMISE, or nil if not resolved.

Arguments:
- `PROMISE` (concur-promise): The promise to query.

Returns:
The resolved value of the promise, or `nil` if the promise is
pending, rejected, or cancelled."
  (when (eq (concur:status promise) 'resolved)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return the error value of PROMISE if rejected, else nil.

Arguments:
- `PROMISE` (concur-promise): The promise to query.

Returns:
The error reason if the promise is rejected or cancelled,
otherwise `nil`."
  (when (memq (concur:status promise) '(rejected cancelled))
    (concur-promise-error promise)))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE has been rejected (including cancellation).

Arguments:
- `PROMISE` (concur-promise): The promise to check.

Returns:
`t` if the promise is in a `'rejected` or `'cancelled` state,
otherwise `nil`."
  (memq (concur:status promise) '(rejected cancelled)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return a human-readable message from a promise's error or an error object.

Arguments:
- `PROMISE-OR-ERROR` (concur-promise or any): A promise object or an error value.

Returns:
A string representation of the error message."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (cond ((stringp err) err)
          ((plistp err) (or (plist-get err :message) (format "%S" err)))
          ((symbolp err) (symbol-name err))
          (err (format "%S" err)))))

;;;###autoload
(cl-defun concur:on-resolve (promise &optional on-resolved on-rejected)
  "Register ON-RESOLVED and/or ON-REJECTED callbacks for PROMISE.

If the promise is already settled, the appropriate callback is
invoked immediately. Otherwise, the callbacks are queued.

Arguments:
- `PROMISE` (concur-promise): The promise to attach callbacks to.
- `ON-RESOLVED` (function, optional): A function `(lambda (value))` to
  be called if the promise resolves.
- `ON-REJECTED` (function, optional): A function `(lambda (error))` to
  be called if the promise rejects.

Returns:
A unique `callback-id` (symbol) that can be used with
`concur:unregister-callback` to remove the callback."
  (let ((callback-id (gensym "promise-cb-")))
    (concur:with-mutex! (concur-promise-lock promise)
        (:else (error "Impossible state: Contention in on-resolve"))
      (concur--log :debug "Attaching callback to: %S" promise)
      (if (concur-promise-resolved-p promise)
          (progn
            (concur--log :debug "Promise already settled, firing immediately.")
            (let ((err (concur:error-value promise)))
              (if err
                  (when on-rejected (funcall on-rejected err))
                (when on-resolved (funcall on-resolved (concur:value promise))))))
        (progn
          (concur--log :debug "Promise pending, adding to callback list.")
          (push (%%make-callback-entry callback-id on-resolved on-rejected)
                (concur-promise-callbacks promise)))))
    callback-id))

;;;###autoload
(defun concur:unregister-callback (promise callback-id)
  "Unregister a callback from PROMISE using its CALLBACK-ID.

Arguments:
- `PROMISE` (concur-promise): The promise from which to remove the callback.
- `CALLBACK-ID` (symbol): The ID returned by `concur:on-resolve`.

Returns:
`t` if the callback was found and removed, `nil` otherwise."
  (concur:with-mutex! (concur-promise-lock promise)
      (:else (error "Impossible state: Contention in unregister-callback"))
    (unless (concur-promise-resolved-p promise)
      (let* ((current (concur-promise-callbacks promise))
             (new (-remove (lambda (cb)
                             (eq (concur-promise-callback-entry-id cb)
                                 callback-id))
                           current)))
        (when (< (length new) (length current))
          (setf (concur-promise-callbacks promise) new)
          t)))))

;;;###autoload
(defun concur:then (source-promise
                    &optional on-resolved-handler on-rejected-handler)
  "Chain a new promise from SOURCE-PROMISE, transforming its result.

This is the core method for promise chaining. It returns a new promise
that will resolve with the return value of `ON-RESOLVED-HANDLER`
(if `SOURCE-PROMISE` resolves) or `ON-REJECTED-HANDLER` (if `SOURCE-PROMISE` rejects).
If a handler returns a promise, the new promise will adopt the state
of that returned promise.

Arguments:
- `SOURCE-PROMISE` (concur-promise): The promise to chain from.
- `ON-RESOLVED-HANDLER` (function, optional): A function `(lambda (value))`
  to be called when `SOURCE-PROMISE` resolves. Its return value
  becomes the resolved value of the new promise. Defaults to `#'identity`.
- `ON-REJECTED-HANDLER` (function, optional): A function `(lambda (error))`
  to be called when `SOURCE-PROMISE` rejects. Its return value
  becomes the resolved value of the new promise (allowing for error recovery).
  Defaults to a function that re-rejects with the same error.

Returns:
A new `concur-promise` that represents the result of the chained operation.

Examples:

Resolve chain:
\(concur:then (concur:resolved! 5)
  (lambda (x) (+ x 5)))
;; => A promise that resolves with 10

Error handling:
\(concur:then (concur:rejected! '(:error \"Oops\"))
  (lambda (val) (message \"Resolved with: %S\" val)) ;; Not called
  (lambda (err) (message \"Caught error: %S\" err) \"Recovered!\"))
;; => A promise that resolves with \"Recovered!\" (and displays \"Caught error: (:error \\\"Oops\\\")\")

Returning a new promise from a handler:
\(concur:then (concur:resolved! 1)
  (lambda (x) (concur:delay 0.5 (* x 2))))
;; => A promise that resolves with 2 after 0.5 seconds"
  (concur--log :debug "Chaining from promise: %S" source-promise)
  (concur:with-executor
   (lambda (resolve reject)
     ;; Using cl-letf to locally bind functions, ensuring the byte-compiler
     ;; understands that the symbols are valid function references.
     (cl-letf (((symbol-function 'resolve) resolve)
               ((symbol-function 'reject) reject)
               ((symbol-function 'on-resolved-handler)
                (or on-resolved-handler #'identity))
               ((symbol-function 'on-rejected-handler)
                (or on-rejected-handler
                    (lambda (err) (concur:rejected! err)))))
       (concur:on-resolve
        source-promise
        (lambda (value)
          (condition-case err
              (let ((next-val (funcall on-resolved-handler value)))
                (if (concur-promise-p next-val)
                    (concur:then next-val #'resolve #'reject)
                  (funcall resolve next-val)))
            (error (funcall reject err))))
        (lambda (error)
          (condition-case err
              (let ((next-val (funcall on-rejected-handler error)))
                (if (concur-promise-p next-val)
                    (concur:then next-val #'resolve #'reject)
                  (funcall resolve next-val)))
            (error (funcall reject err)))))))))

;;;###autoload
(defun concur:catch (promise handler)
  "Attach an error HANDLER to PROMISE.

This is a syntactic sugar for `concur:then` with only an
`on-rejected` handler.

Arguments:
- `PROMISE` (concur-promise): The promise to attach the handler to.
- `HANDLER` (function): A function `(lambda (error))` to be called if
  the promise rejects. Its return value can recover the promise chain.

Returns:
A new `concur-promise`."
  (concur:then promise nil handler))

;;;###autoload
(defun concur:finally (promise callback)
  "Attach CALLBACK to run after PROMISE settles, regardless of outcome.

The `CALLBACK` function is called after the promise has either resolved
or rejected. It does not receive any arguments. If `CALLBACK` returns
a promise, `concur:finally` will wait for that promise to settle.
Crucially, `concur:finally` does not alter the original promise's
resolution or rejection value.

Arguments:
- `PROMISE` (concur-promise): The promise to attach the finally callback to.
- `CALLBACK` (function): A zero-argument function to execute after `PROMISE` settles.

Returns:
A new `concur-promise` that resolves/rejects with the same value/error
as the original `PROMISE` after `CALLBACK` has completed."
  (concur:then
   promise
   (lambda (val)
     (let ((p (funcall callback)))
       (if (concur-promise-p p) (concur:then p (lambda (_) val)) val)))
   (lambda (err)
     (let ((p (funcall callback)))
       (if (concur-promise-p p)
           (concur:then p (lambda (_) (concur:rejected! err)))
         (concur:rejected! err))))))

;;;###autoload
(defun concur:tap (promise callback)
  "Attach CALLBACK for side effects without altering the promise chain.

The `CALLBACK` function receives two arguments: `value` and `error`.
If the promise resolved, `value` is the resolved value and `error` is `nil`.
If the promise rejected, `value` is `nil` and `error` is the rejection reason.
The return value of `CALLBACK` is ignored, and the original promise's
resolution/rejection propagates.

Arguments:
- `PROMISE` (concur-promise): The promise to tap into.
- `CALLBACK` (function): A function `(lambda (value error))` for side effects.

Returns:
A new `concur-promise` that mirrors the settlement of the original `PROMISE`."
  (concur:then
   promise
   (lambda (value) (ignore-errors (funcall callback value nil)) value)
   (lambda (error) (ignore-errors (funcall callback nil error))
     (concur:rejected! error))))

;;;###autoload
(defun concur:all (promises)
  "Return a promise that resolves when all PROMISES resolve.

The returned promise resolves with a list of resolved values in the same
order as the input `PROMISES`. If any of the input promises reject,
the returned promise immediately rejects with the error of the first
rejected promise.

Arguments:
- `PROMISES` (list): A list of `concur-promise` objects or values.
  (Non-promise values will be treated as already resolved promises).

Returns:
A `concur-promise` object."
  (concur--log :debug "concur:all called with %d promises." (length promises))
  (if (null promises) (concur:resolved! '())
    (let* ((total (length promises))
           (results (make-vector total nil))
           (done-p (concur:make-promise))
           (resolved-count 0))
      (--each-indexed promises
        (lambda (i p)
          (let ((p (if (concur-promise-p p) p (concur:resolved! p))))
            (concur:then p
              (lambda (res)
                (unless (concur-promise-resolved-p done-p)
                  (aset results i res)
                  (cl-incf resolved-count)
                  (when (= resolved-count total)
                    (concur--log :debug "concur:all finished successfully.")
                    (concur:resolve done-p (cl-coerce results 'list)))))
              (lambda (err)
                (unless (concur-promise-resolved-p done-p)
                  (concur--log :debug "concur:all rejected.")
                  (concur:reject done-p err)))))))
      done-p)))

;;;###autoload
(defun concur:race (promises)
  "Return a promise that resolves or rejects with the first PROMISE to settle.

As soon as any promise in the input `PROMISES` list settles (either
resolves or rejects), the returned promise will settle with the same
value or error.

Arguments:
- `PROMISES` (list): A list of `concur-promise` objects or values.

Returns:
A `concur-promise` object."
  (concur--log :debug "concur:race called with %d promises." (length promises))
  (let ((race-p (concur:make-promise)))
    (dolist (p promises)
      (let ((p (if (concur-promise-p p) p (concur:resolved! p))))
        (concur:then p
                     (lambda (res)
                       (unless (concur-promise-resolved-p race-p)
                         (concur:resolve race-p res)))
                     (lambda (err)
                       (unless (concur-promise-resolved-p race-p)
                         (concur:reject race-p err))))))
    race-p))

;;;###autoload
(defun concur:any (promises)
  "Return a promise that resolves with the first promise to fulfill.

The returned promise resolves with the value of the first promise in
`PROMISES` that resolves. If all input promises reject, the returned
promise rejects with an aggregate error containing all rejection reasons.

Arguments:
- `PROMISES` (list): A list of `concur-promise` objects or values.

Returns:
A `concur-promise` object."
  (concur--log :debug "concur:any called with %d promises." (length promises))
  (if (null promises)
      (concur:rejected! '(:aggregate-error "No promises provided" nil))
    (let* ((total (length promises))
           (errors (make-vector total nil))
           (any-p (concur:make-promise))
           (rejected-count 0))
      (--each-indexed promises
        (lambda (i p)
          (let ((p (if (concur-promise-p p) p (concur:resolved! p))))
            (concur:then p
              (lambda (res)
                (unless (concur-promise-resolved-p any-p)
                  (concur:resolve any-p res)))
              (lambda (err)
                (unless (concur-promise-resolved-p any-p)
                  (aset errors i err)
                  (cl-incf rejected-count)
                  (when (= rejected-count total)
                    (concur:reject any-p
                                   `(:aggregate-error
                                     "All promises were rejected"
                                     ,(cl-coerce errors 'list))))))))))
      any-p)))

;;;###autoload
(defun concur:all-settled (promises)
  "Return a promise that resolves after all PROMISES have settled.

The returned promise always resolves. Its resolved value is a list of
outcome description plists, each indicating whether an input promise
was `fulfilled` or `rejected`, along with its `value` or `reason`.
The order of outcomes matches the order of input `PROMISES`.

Arguments:
- `PROMISES` (list): A list of `concur-promise` objects or values.

Returns:
A `concur-promise` object."
  (concur--log :debug "concur:all-settled called with %d promises."
               (length promises))
  (if (null promises) (concur:resolved! '())
    (let* ((total (length promises))
           (outcomes (make-vector total nil))
           (all-p (concur:make-promise))
           (settled-count 0))
      (--each-indexed promises
        (lambda (i p)
          (let ((p (if (concur-promise-p p) p (concur:resolved! p))))
            (concur:finally p
              (lambda ()
                (unless (concur-promise-resolved-p all-p)
                  (aset outcomes i
                        (if (concur:rejected-p p)
                            `(:status 'rejected :reason ,(concur:error-value p))
                          `(:status 'fulfilled :value ,(concur:value p))))
                  (cl-incf settled-count)
                  (when (= settled-count total)
                    (concur:resolve all-p (cl-coerce outcomes 'list)))))))))
      all-p)))

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.

If used within a coroutine, this macro will yield control and resume when
the `PROMISE-FORM` settles. If used outside a coroutine, it will use a
blocking (but cooperative) mechanism that pauses Emacs until the promise
settles or `TIMEOUT` is reached.
**Use with extreme caution outside of coroutines, as it blocks the UI.**

Arguments:
- `PROMISE-FORM` (form): A form that evaluates to a `concur-promise`.
- `TIMEOUT` (number, optional): Maximum seconds to wait when blocking
  outside a coroutine.

Returns:
The resolved value of the promise on success.

Errors:
- Signals the promise's error if it rejects.
- Signals `concur:timeout-error` if a timeout occurs when blocking."
  `(if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
       (let ((promise ,promise-form))
         (if (concur-promise-resolved-p promise)
             (if-let ((err (concur:error-value promise)))
                 (signal (car err) (cdr err))
               (concur:value promise))
           (yield--internal-throw-form promise
                                       ',yield--await-external-status-key)))
     (concur--await-blocking ,promise-form ,timeout)))

;;;###autoload
(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with VALUE after SECONDS.

Arguments:
- `SECONDS` (number): The number of seconds to wait before resolving.
- `VALUE` (any, optional): The value the promise will resolve with.
  Defaults to `t` if not provided.

Returns:
A `concur-promise` object."
  (concur:with-executor
   (lambda (resolve _reject)
     (run-at-time seconds nil
                  (lambda () (funcall resolve (or value t)))))))

;;;###autoload
(defun concur:timeout (promise timeout-seconds)
  "Wrap PROMISE, rejecting if it doesn't settle within TIMEOUT-SECONDS.

This creates a new promise that mirrors the original `PROMISE`, but
if the `PROMISE` doesn't settle within `TIMEOUT-SECONDS`, the new
promise will reject with a timeout error.

Arguments:
- `PROMISE` (concur-promise): The promise to apply a timeout to.
- `TIMEOUT-SECONDS` (number): The maximum number of seconds to wait.

Returns:
A new `concur-promise` object that includes the timeout logic."
  (concur:race
   (list promise
         (concur:with-executor
          (lambda (_resolve reject)
            (run-at-time timeout-seconds nil
                         (lambda ()
                           (funcall reject '(:timeout "Promise timed out")))))))))

;;;###autoload
(defmacro concur:from-callback (fetch-fn-form)
  "Wrap a callback-based async FETCH-FN-FORM into a promise.

`FETCH-FN-FORM` should evaluate to a function that takes a single
callback argument, e.g., `(lambda (callback-fn))`. The `callback-fn`
itself should accept two arguments: `(result error)`.

Arguments:
- `FETCH-FN-FORM` (form): A form evaluating to a function that accepts
  a completion callback `(lambda (result error))`.

Returns:
A `concur-promise` object that resolves or rejects based on the
`FETCH-FN-FORM`'s callback invocation."
  `(concur:with-executor
    (lambda (resolve reject)
      (funcall ,fetch-fn-form (lambda (result error)
                                (if error (funcall reject error)
                                  (funcall resolve result)))))))

;;;###autoload
(defun concur:from-coroutine (runner &optional cancel-token)
  "Create a `concur-promise` that settles with a coroutine's final outcome.

This function bridges a coroutine (created via `coroutines.el`) with
the promise system. The promise will resolve when the coroutine
completes successfully, or reject if the coroutine signals an error
or is cancelled.

Arguments:
- `RUNNER` (coroutine-runner): The runner object of a coroutine.
- `CANCEL-TOKEN` (concur-cancel-token, optional): A cancellation token
  to associate with the promise and the coroutine.

Returns:
A `concur-promise` object."
  (let ((ctx (plist-get (symbol-plist runner) :coroutine-ctx)))
    (when cancel-token (put ctx :cancel-token cancel-token)))
  (concur:with-executor
   (lambda (resolve reject)
     (cl-labels ((drive-coro (&optional resume-val)
                   (condition-case-unless-debug err
                       (pcase (resume! runner resume-val) ;; Pass resume-val to resume!
                         (`(:await-external ,p)
                          (concur:then p #'drive-coro #'reject))
                         (yielded-val (drive-coro yielded-val)))
                     (coroutine-done (funcall resolve (car err)))
                     (coroutine-cancelled (funcall reject err))
                     (error (funcall reject err)))))
       (drive-coro)))
   cancel-token))

;;;###autoload
(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an async FN up to RETRIES times on failure.

This function executes `FN` (which should return a promise) and
retries it if it rejects, up to a maximum number of `RETRIES`.
An optional `DELAY` can be specified between retries, and a `PRED`
function can filter which errors trigger a retry.

Arguments:
- `FN` (function): A zero-argument function that returns a `concur-promise`.
- `:retries` (integer, optional): The maximum number of retry attempts. Defaults to 3.
- `:delay` (number or function, optional): The delay in seconds between retries.
  Can be a number for a fixed delay or a function `(lambda (attempt-number))`
  for exponential backoff. Defaults to 0.1 seconds.
- `:pred` (function, optional): A predicate `(lambda (error))` that
  returns `t` if the error should trigger a retry. Defaults to `#'always`
  (retry on any error).

Returns:
A `concur-promise` that resolves with the first successful result
or rejects with the final error after all retries are exhausted."
  (let ((p (concur:make-promise)) (attempt 0))
    (cl-labels ((do-try ()
                  (concur:catch (funcall fn)
                                (lambda (err)
                                  (if (and (< (cl-incf attempt) retries)
                                           (funcall pred err))
                                      (let ((d (if (functionp delay)
                                                   (funcall delay attempt)
                                                 delay)))
                                        (concur:then (concur:delay d) #'do-try))
                                    (concur:rejected! err))))))
      (concur:then (do-try)
                   (lambda (res) (concur:resolve p res))
                   (lambda (err) (concur:reject p err))))
    p))

;;;###autoload
(cl-defun concur:map-series (items fn)
  "Process ITEMS sequentially with async FN `(lambda (item))`.

`FN` is an asynchronous mapping function that takes an item and returns
a promise. This function processes each item one after another, waiting
for the previous item's promise to settle before starting the next.

Arguments:
- `ITEMS` (list): A list of items to process.
- `FN` (function): An async function `(lambda (item))` that returns a `concur-promise`.

Returns:
A `concur-promise` that resolves with a list of all transformed results
in order, or rejects with the first error encountered."
  (--reduce-from
   (lambda (p-acc item)
     (concur:then p-acc
                  (lambda (acc-res)
                    (concur:then (funcall fn item)
                                 (lambda (item-res)
                                   (append acc-res (list item-res)))))))
   (concur:resolved! '())
   items))

;;;###autoload
(cl-defun concur:map-parallel (items fn)
  "Process ITEMS in parallel with async FN `(lambda (item))`.

`FN` is an asynchronous mapping function that takes an item and returns
a promise. This function initiates all processing concurrently.

Arguments:
- `ITEMS` (list): A list of items to process.
- `FN` (function): An async function `(lambda (item))` that returns a `concur-promise`.

Returns:
A `concur-promise` that resolves with a list of all transformed results
in order, or rejects with the first error encountered (similar to `concur:all`)."
  (concur:all (--map (funcall fn it) items)))

(defun concur--expand-sugar (steps)
  "Transform sugar keywords in STEPS into canonical `concur:chain` clauses."
  (let ((processed nil) (remaining steps))
    (while remaining
      (let ((key (pop remaining)) arg1 arg2)
        (pcase key
          (:map
           (setq arg1 (pop remaining))
           (push `(:then (lambda (<>) (--map (let ((it <>)) ,arg1) <>)))
                 processed))
          (:filter
           (setq arg1 (pop remaining))
           (push `(:then (lambda (<>) (--filter (let ((it <>)) ,arg1) <>)))
                 processed))
          (:each
           (setq arg1 (pop remaining))
           (push `(:then (lambda (<>)
                           (prog1 <> (--each (let ((it <>)) ,arg1) <>))))
                 processed))
          (:sleep
           (setq arg1 (pop remaining))
           (push `(:then (lambda (val)
                           (concur:then (concur:delay (/ ,arg1 1000.0))
                                        (lambda (_) val))))
                 processed))
          (:log
           (let ((fmt (if (and remaining (stringp (car remaining)))
                          (pop remaining) "%S")))
             (push `(:tap (message ,fmt <>)) processed)))
          (:retry
           (setq arg1 (pop remaining)) (setq arg2 (pop remaining))
           (push `(:then (lambda (<>)
                           (concur:retry (lambda () ,arg2) :retries ,arg1)))
                 processed))
          (_ (push key processed)
             (when remaining (push (pop remaining) processed))))))
    (nreverse processed)))

;;;###autoload
(defmacro concur:chain (initial-promise-expr &rest steps)
  "Thread INITIAL-PROMISE-EXPR through a series of asynchronous steps.

This macro provides a powerful and readable way to sequence asynchronous
operations. Each `step` is applied to the resolved value of the previous
promise. If any promise in the chain rejects, the chain short-circuits
to the next `:catch` handler or the final rejection.

The special variable `<>` (read as \'it\' or \'value\') holds the resolved
value of the preceding promise in the chain. For `:catch` handlers,
the special variable `<!>` (read as \'error\' or \'exception\') holds the
rejection reason.

Arguments:
- `INITIAL-PROMISE-EXPR` (form): A form that evaluates to the first
  `concur-promise` in the chain, or a regular value which will be
  wrapped in a resolved promise.
- `STEPS` (forms): A sequence of asynchronous operations.
  Supported steps:
    - `(:then (lambda (<>) ...))`: Explicit `lambda` for transformation.
    - `(some-form)`: Implicit `(:then (lambda (<>) some-form))`.
    - `(lambda (<>) ...)`: Shorthand for `(:then (lambda (<>) ...))`.
    - `(:catch (lambda (<!>) ...))`: Error handling.
    - `(:finally (form ...))`: Runs after success or failure, without altering result.
    - `(:tap (form ...))`: Runs for side effects, receives `(<>)` and `error`
      (one will be `nil`), doesn't alter result.
    - `(:let (bindings) ...)`: Introduces lexical bindings for subsequent steps.
    - `(:all (list-of-promises))`: Waits for all promises in the list.
    - `(:race (list-of-promises))`: Waits for the first promise to settle.
    - `(:map fn)`: Transforms a list of items using `fn` in parallel.
      `fn` receives `it` as current item.
    - `(:filter fn)`: Filters a list of items using `fn`. `fn` receives `it`.
    - `(:each fn)`: Iterates over a list for side effects. `fn` receives `it`.
    - `(:sleep milliseconds)`: Pauses the chain for `milliseconds`.
    - `(:log [fmt-string])`: Logs the current value of `<>`.
    - `(:retry times body)`: Retries `body` if it fails, up to `times`.

Returns:
A `concur-promise` representing the final outcome of the chain.

Examples:

Simple chaining with implicit lambda (form use):
\(concur:chain (concur:resolved! 10)
  (1+ <>)
  (* <> 2))
;; => A promise that resolves with 22

Chaining with explicit lambda (lambda use):
\(concur:chain (concur:resolved! \"hello\")
  (lambda (s) (s-capitalize s))
  (lambda (s) (concat s \", world!\")))
;; => A promise that resolves with \"Hello, world!\"

Chaining with error handling:
\(concur:chain (concur:rejected! '(:error \"Initial error\"))
  (lambda (<>) (message \"This won\'t run\"))
  (:catch
   (lambda (<!>)
     (message \"Caught error: %S\" <!)
     \"Error handled!\")))
;; => A promise that resolves with \"Error handled!\" (and displays \"Caught error: (:error \\\"Initial error\\\")\")

More complex example with multiple steps:
\(concur:chain (concur:resolved! '(1 2 3))
  (:log \"Initial list: %S\")
  (:map (1+ it))                 ;; Add 1 to each number, e.g., (1 2 3) -> (2 3 4)
  (:log \"After map: %S\")
  (:then (concur:delay 0.1 <>) ) ;; Simulate async delay
  (lambda (nums)                 ;; Sum the numbers
    (apply '+ nums))
  (:log \"Sum is: %S\")
  (:catch                        ;; Catch any errors in the chain
   (lambda (e)
     (message \"Unexpected error: %S\" e)
     \"Failed to compute sum\")))
;; This will log the steps and eventually resolve with 9.
"
  (declare (indent 1))
  (let ((sugared-steps (concur--expand-sugar steps)))
    (cl-labels
        ((expander (current-promise steps)
           (if (null steps)
               current-promise
             (pcase steps
               (`(:then ,arg . ,rest)
                (expander `(concur:then ,current-promise (lambda (<>) ,arg))
                          rest))
               (`(:catch ,arg . ,rest)
                (expander `(concur:then ,current-promise nil
                                        (lambda (<!>) ,arg))
                          rest))
               (`(:finally ,arg . ,rest)
                (expander `(concur:finally ,current-promise (lambda () ,arg))
                          rest))
               (`(:tap ,arg . ,rest)
                (expander
                 `(concur:tap ,current-promise
                              (lambda (<> error) (declare (ignore error)) ,arg))
                 rest))
               (`(:let ,bindings . ,rest)
                `(let* ,bindings ,(expander current-promise rest)))
               (`(:all ,arg . ,rest) (expander `(concur:all ,arg) rest))
               (`(:race ,arg . ,rest) (expander `(concur:race ,arg) rest))
               (`(<> . ,rest) (expander current-promise rest))
               (`(,(and (pred (lambda (f) (and (listp f) (eq (car f) 'lambda))))
                       lambda-expr) . ,rest)
                (expander `(concur:then ,current-promise ,lambda-expr) rest))
               (`(,(and (pred listp) form) . ,rest)
                (expander `(concur:then ,current-promise (lambda (<>) ,form))
                          rest))
               (_ (error "Invalid concur:chain step: %S" (car steps)))))))
      (expander initial-promise-expr sugared-steps))))

;;;###autoload
(defmacro concur:chain-when (initial-promise-expr &rest steps)
  "Like `concur:chain` but short-circuits on `nil` resolved values.

This macro behaves similarly to `concur:chain`, but if a promise
resolves with `nil`, subsequent `:then` steps will be skipped.
Error handling (`:catch`, `:finally`, `:tap`) will still execute.

Arguments:
- `INITIAL-PROMISE-EXPR` (form): The initial promise or value.
- `STEPS` (forms): A sequence of asynchronous operations, similar to `concur:chain`.

Returns:
A `concur-promise` representing the final outcome of the chain."
  (declare (indent 1))
  (let ((sugared-steps (concur--expand-sugar steps)))
    (cl-labels
        ((expander (current-promise steps)
           (if (null steps)
               current-promise
             (pcase steps
               (`(:then ,arg . ,rest)
                (expander `(concur:then
                            ,current-promise (lambda (<>) (when <> ,arg)))
                          rest))
               (`(:catch ,arg . ,rest)
                (expander `(concur:then
                            ,current-promise nil (lambda (<!>) ,arg))
                          rest))
               (`(:finally ,arg . ,rest)
                (expander `(concur:finally
                            ,current-promise (lambda () ,arg)) rest))
               (`(:tap ,arg . ,rest)
                (expander
                 `(concur:tap
                   ,current-promise
                   (lambda (<> error) (declare (ignore error)) (when <> ,arg)))
                 rest))
               (`(:let ,bindings . ,rest)
                `(let* ,bindings ,(expander current-promise rest)))
               (`(:all ,arg . ,rest) (expander `(concur:all ,arg) rest))
               (`(:race ,arg . ,rest) (expander `(concur:race ,arg) rest))
               (`(<> . ,rest) (expander current-promise rest))
               (`(,(and (pred (lambda (f) (and (listp f) (eq (car f) 'lambda))))
                       lambda-expr) . ,rest)
                (expander
                 `(concur:then
                   ,current-promise (lambda (<>) (when <>
                                                   (funcall ,lambda-expr <>))))
                 rest))
               (`(,(and (pred listp) form) . ,rest)
                (expander
                 `(concur:then ,current-promise (lambda (<>) (when <> ,form)))
                 rest))
               (_ (error "Invalid concur:chain step: %S" (car steps)))))))
      (expander initial-promise-expr sugared-steps))))

(provide 'concur-promise)
;;; concur-promise.el ends here