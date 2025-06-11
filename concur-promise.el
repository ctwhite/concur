;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a lightweight yet comprehensive Promise implementation
;; for Emacs Lisp, designed to facilitate asynchronous programming patterns.
;; It allows for chaining operations, handling errors gracefully, and managing
;; concurrent tasks. This library is a foundational component for building
;; more complex asynchronous systems in Emacs.
;;
;; Core Promise Lifecycle:
;; - Promises start in a "pending" state.
;; - They can be "resolved" with a success value or "rejected" with an error.
;; - Once settled (resolved or rejected), a promise's state does not change.
;; - Callbacks can be attached to a promise to react to its settlement.
;;
;; Key Features:
;; - Basic Promise Operations: `concur:make-promise`, `concur:with-executor`,
;;   `concur:resolve`, `concur:reject`, `concur:resolved!`, `concur:rejected!`.
;; - Chaining and Transformation: `concur:then`, `concur:catch`, `concur:finally`.
;; - Composition: `concur:all`, `concur:race`, `concur:any`, `concur:all-settled`.
;; - Advanced Control Flow & Utilities:
;;   - `concur:chain`: A powerful threading macro for building complex chains.
;;   - `concur:await`: Cooperatively wait until a promise settles. This operation
;;     is non-blocking when used inside a coroutine.
;;   - `concur:map-series`, `concur:map-parallel`, `concur:retry`.
;;   - `concur:delay`, `concur:timeout`.
;; - Async/Await: `concur:from-coroutine` bridges the gap between
;;   promise-chains and coroutine-based sequential code.
;; - Cancellation: Integration with `concur-cancel-token`.
;; - Introspection: Status checking functions like `concur:status`, `concur:value`.

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

;; Forward declarations to satisfy the byte-compiler.
(declare-function macro-function "macro" (&rest args))
(declare-function yield! "coroutines" (value &optional tag))
(declare-function yield--internal-throw-form (value tag))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constants and Customization

(defcustom concur-throw-on-promise-rejection nil
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
    "Represents an asynchronous operation that can resolve or reject."
    (result nil "The success value of the promise once resolved.")
    (error nil "The error reason of the promise once rejected.")
    (resolved-p nil "A flag indicating if the promise has settled." :type boolean)
    (callbacks '()
     "A list of `concur-promise-callback-entry' structs." :type list)
    (cancel-token nil "An optional `concur-cancel-token` for cancellation.")
    (cancelled-p nil "A flag indicating if the promise was cancelled." :type boolean)
    (proc nil "An associated process, for cancellation.")
    (lock (concur:make-lock) "A mutex to protect the callbacks list.")))

(eval-and-compile
  (cl-defstruct (concur-promise-callback-entry
                 (:constructor %%make-callback-entry
                               (id on-resolved on-rejected)))
    "Internal wrapper for a promise callback with a unique ID."
    (id nil "The unique symbol identifying this callback entry.")
    (on-resolved nil "The function to call on successful resolution.")
    (on-rejected nil "The function to call on rejection.")))

(eval-and-compile
  (cl-defstruct (concur-await-latch
                 (:constructor %%make-await-latch))
    "Internal latch used by the blocking implementation of `concur:await`."
    (process (start-process (format "await-latch-%s" (random)) nil nil)
             "A dummy background process used for cooperative waiting.")
    (signaled-p nil "A flag to indicate the latch has been released."
               :type boolean)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--run-callbacks (promise)
  "Invoke registered callbacks on PROMISE after settlement."
  (let (callbacks promise-error promise-result)
    ;; Atomically grab and clear the callbacks list inside a mutex.
    (concur:with-mutex! (concur-promise-lock promise)
        (:else (error "Impossible state: Contention in run-callbacks"))
      (setq callbacks (concur-promise-callbacks promise))
      (setq promise-error (concur-promise-error promise))
      (setq promise-result (concur-promise-result promise))
      (setf (concur-promise-callbacks promise) nil))

    ;; With the callbacks safely extracted, run them outside the mutex.
    (concur--log :debug "Running %d callbacks for promise: %S"
                 (length callbacks) promise)
    (dolist (entry callbacks)
      (concur--log :debug "  Executing callback entry: %S" entry)
      (condition-case err
          (let ((on-resolved (concur-promise-callback-entry-on-resolved entry))
                (on-rejected (concur-promise-callback-entry-on-rejected entry)))
            (if promise-error
                (when on-rejected (funcall on-rejected promise-error))
              (when on-resolved (funcall on-resolved promise-result))))
        ('error (message "[concur] Callback failed: %S" err))))))

(defun concur--settle-promise (promise &optional value error is-cancellation)
  "Internal helper to settle a promise (resolve or reject).
Handles state setting, callback execution, and unhandled rejection errors."
  (unless (concur-promise-resolved-p promise)
    (concur--log :debug "Settling promise: %S, Value: %S, Error: %S"
                 promise value error)
    ;; 1. Set the final state of the promise.
    (setf (concur-promise-result promise) value)
    (setf (concur-promise-error promise) error)
    (setf (concur-promise-resolved-p promise) t)
    (when is-cancellation
      (setf (concur-promise-cancelled-p promise) t))

    ;; 2. Execute all pending callbacks synchronously.
    (concur--run-callbacks promise)

    ;; 3. Throw an error for unhandled rejections *after* callbacks have run.
    (when (and error (not is-cancellation) concur-throw-on-promise-rejection)
      (error "[concur] Unhandled promise rejection: %S" error)))
  promise)

(defun concur--destroy-await-latch (latch)
  "Destroy the AWAIT-LATCH's associated process to free resources."
  (when (and (concur-await-latch-p latch)
             (process-live-p (concur-await-latch-process latch)))
    (delete-process (concur-await-latch-process latch))))

(defun concur--await-blocking (promise &optional timeout)
  "Blocking (but cooperative) implementation of `await`."
  (unless (concur-promise-p promise)
    (error "Invalid object passed to concur--await-blocking: %S" promise))
  (if (concur-promise-resolved-p promise)
      (if-let ((err (concur:error-value promise)))
          (signal (car err) (cdr err))
        (concur:value promise))
    (let ((latch (%%make-await-latch))
          (timer nil)
          (result nil)
          (had-error nil))
      (unwind-protect
          (progn
            (concur:on-resolve
             promise
             ;; on-resolved: capture the result and signal the latch.
             (lambda (value)
               (setq result value)
               (setf (concur-await-latch-signaled-p latch) t))
             ;; on-rejected: capture the error and signal the latch.
             (lambda (err)
               (setq had-error err)
               (setf (concur-await-latch-signaled-p latch) t)))

            (when timeout
              (setq timer (run-at-time timeout nil
                                       (lambda ()
                                         (setf (concur-await-latch-signaled-p
                                                latch)
                                               'timeout)))))
            (while (not (concur-await-latch-signaled-p latch))
              (accept-process-output (concur-await-latch-process latch) 0.1))

            (when (eq (concur-await-latch-signaled-p latch) 'timeout)
              (concur:cancel promise "Await timed out")
              (error 'concur:timeout-error "Await timed out"))

            (if had-error
                (signal (car had-error) (cdr had-error))
              result))
        (when timer (cancel-timer timer))
        (concur--destroy-await-latch latch)))))
        
(defun concur--non-keyword-symbol-p (s)
  "Return non-nil if S is a symbol but not a keyword."
  (and (symbolp s) (not (keywordp s))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Promise API

;;;###autoload
(defun concur:make-promise (&rest slots)
  "Create and return a new unresolved (pending) promise."
  (apply #'%%make-promise slots))

;;;###autoload
(defun concur:with-executor (executor-fn &optional cancel-token)
  "Create a promise and immediately invoke EXECUTOR-FN."
  (unless (functionp executor-fn)
    (error "Executor must be a function, got %S" executor-fn))
  (let ((promise (concur:make-promise :cancel-token cancel-token)))
    (concur--log :debug "Executing promise with: %S" executor-fn)
    (condition-case err
        (funcall executor-fn
                 (lambda (value) (concur:resolve promise value))
                 (lambda (error) (concur:reject promise error)))
      (error
       (concur:reject promise
                      `(:error-type executor-error
                        :message "Error in promise executor"
                        :original-error ,err))))
    promise))

;;;###autoload
(defun concur:resolve (promise result)
  "Resolve PROMISE with RESULT."
  (concur--settle-promise promise result nil nil))

;;;###autoload
(defun concur:reject (promise error &optional is-cancellation)
  "Reject PROMISE with ERROR."
  (concur--settle-promise promise nil error is-cancellation))

;;;###autoload
(defun concur:resolved! (value)
  "Return a new promise that is already resolved with VALUE."
  (let ((p (concur:make-promise)))
    (setf (concur-promise-result p) value)
    (setf (concur-promise-resolved-p p) t)
    p))

;;;###autoload
(defun concur:rejected! (error)
  "Return a new promise that is already rejected with ERROR."
  (let ((p (concur:make-promise)))
    (setf (concur-promise-error p) error)
    (setf (concur-promise-resolved-p p) t)
    p))

;;;###autoload
(defun concur:cancel (promise &optional reason)
  "Cancel PROMISE by rejecting it and killing any associated process."
  (unless (concur-promise-resolved-p promise)
    (when-let ((proc (concur-promise-proc promise)))
      (when (process-live-p proc)
        (ignore-errors (kill-process proc))))
    (concur:reject promise
                   (if (and (consp reason)
                            (plist-member reason concur--promise-cancelled-key))
                       reason
                     `(,concur--promise-cancelled-key
                       ,(or reason "Promise cancelled")))
                   t))
  promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Promise Introspection & Status

;;;###autoload
(defun concur:status (promise)
  "Return the current status of PROMISE as a symbol."
  (unless (concur-promise-p promise)
    (error "Invalid promise object: %S" promise))
  (cond ((not (concur-promise-resolved-p promise)) 'pending)
        ((concur-promise-cancelled-p promise) 'cancelled)
        ((concur-promise-error promise) 'rejected)
        (t 'resolved)))

;;;###autoload
(defun concur:value (promise)
  "Return the resolved value of PROMISE, or nil if not resolved."
  (when (eq (concur:status promise) 'resolved)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return the error value of PROMISE if rejected, else nil."
  (when (memq (concur:status promise) '(rejected cancelled))
    (concur-promise-error promise)))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE has been rejected (including cancellation)."
  (memq (concur:status promise) '(rejected cancelled)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return a human-readable message for a promise's error."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (cond ((stringp err) err)
          ((plistp err) (or (plist-get err :message) (format "%S" err)))
          ((symbolp err) (symbol-name err))
          (err (format "%S" err)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Callback Management

;;;###autoload
(cl-defun concur:on-resolve (promise &optional on-resolved on-rejected)
  "Register ON-RESOLVED and/or ON-REJECTED callbacks for PROMISE."
  (let ((callback-id (gensym "promise-cb-")))
    (concur:with-mutex! (concur-promise-lock promise)
        (:else (error "Impossible state: Contention in on-resolve"))
      (concur--log :debug "Attaching callback to: %S" promise)
      (concur--log :debug "  on-resolved: %S" on-resolved)
      (concur--log :debug "  on-rejected: %S" on-rejected)
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
  "Unregister a callback from PROMISE using its CALLBACK-ID."
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Chaining & Transformation

;;;###autoload
(defun concur:then (source-promise &optional on-resolved-handler on-rejected-handler)
  "Chain a new promise from SOURCE-PROMISE, transforming its result.
Returns a new promise that settles based on the return value of
the handler. If a handler returns another promise, the new
promise will assimilate its state.

(Examples)
  (-> (concur:resolved! 10)
      (concur:then (lambda (v) (* v 2)))
      (concur:then (lambda (v) (message \"Result: %d\" v)))) ; => \"Result: 20\"

Arguments:
- `SOURCE-PROMISE` (concur-promise): The promise to chain from.
- `ON-RESOLVED-HANDLER` (function): `(lambda (value))` for success.
- `ON-REJECTED-HANDLER` (function): `(lambda (error))` for failure.

Returns:
  A new `concur-promise`."
  (concur:with-executor
   (lambda (resolve reject)
     (concur:on-resolve
      source-promise
      ;; on-resolved handler
      (lambda (value)
        (if on-resolved-handler
            (condition-case err
                (let ((next-val (funcall on-resolved-handler value)))
                  (if (concur-promise-p next-val)
                      ;; Assimilate the promise returned by the handler.
                      (concur:then next-val resolve reject)
                    ;; Resolve with the transformed value.
                    (funcall resolve next-val)))
              (error (funcall reject err)))
          ;; If no handler, pass the original value through.
          (funcall resolve value)))
      ;; on-rejected handler
      (lambda (error)
        (if on-rejected-handler
            (condition-case err
                (let ((next-val (funcall on-rejected-handler error)))
                  (if (concur-promise-p next-val)
                      ;; Assimilate the promise returned by the handler.
                      (concur:then next-val resolve reject)
                    ;; A catch handler's return value RESOLVES the chain.
                    (funcall resolve next-val)))
              (error (funcall reject err)))
          ;; If no handler, pass the original error through.
          (funcall reject error)))))))

;;;###autoload
(defun concur:catch (promise handler)
  "Attach an error HANDLER to PROMISE. Syntactic sugar for `concur:then`."
  (concur:then promise nil handler))

;;;###autoload
(defun concur:finally (promise callback)
  "Attach CALLBACK to run after PROMISE settles, regardless of outcome."
  (concur:then
   promise
   (lambda (val)
     (let ((p (funcall callback)))
       (if (concur-promise-p p)
           (concur:then p (lambda (_) val))
         val)))
   (lambda (err)
     (let ((p (funcall callback)))
       (if (concur-promise-p p)
           (concur:then p (lambda (_) (concur:rejected! err)))
         (concur:rejected! err))))))

;;;###autoload
(defun concur:tap (promise callback)
  "Attach CALLBACK for side effects without altering the promise chain.
The `CALLBACK` `(lambda (value error))` is called when the promise
settles. Its return value is ignored, and the original promise's
settlement value is passed through to the next link in the chain.

Arguments:
- `PROMISE` (concur-promise): The promise to tap into.
- `CALLBACK` (function): A `(lambda (value error))` function.

Returns:
  A new `concur-promise` that resolves or rejects with the
original promise's value after the callback has been run."
  (concur:then
   promise
   ;; on-resolved: run the side-effect, then pass the original value through.
   (lambda (value)
     (ignore-errors (funcall callback value nil))
     value)
   ;; on-rejected: also run the side-effect, then re-reject with the original error.
   (lambda (error)
     (ignore-errors (funcall callback nil error))
     (concur:rejected! error))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Promise Composition

;;;###autoload
(defun concur:all (promises)
  "Return a promise that resolves when all PROMISES resolve.

(Examples)
  (concur:await (concur:all (list (concur:delay 0.1 1)
                                  (concur:delay 0.2 2))))
  ;; => '(1 2)

Arguments:
- `PROMISES` (list): A list of promises or values.

Returns:
  A new `concur-promise` that resolves with a list of all results."
  (if (null promises)
      (concur:resolved! '())
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
                               (concur:resolve
                                done-p (cl-coerce results 'list)))))
                         (lambda (err)
                           (unless (concur-promise-resolved-p done-p)
                             (concur:reject done-p err)))))))
      done-p)))

;;;###autoload
(defun concur:race (promises)
  "Return a promise that resolves or rejects with the first PROMISE to settle.

Arguments:
- `PROMISES` (list): A list of promises or values.

Returns:
  A new `concur-promise` that mirrors the first promise to settle."
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
If all promises reject, the returned promise rejects with an
`AggregateError` containing all rejection reasons.

Arguments:
- `PROMISES` (list): A list of promises or values.

Returns:
  A new `concur-promise`."
  (if (null promises)
      (concur:rejected! `(:aggregate-error "No promises provided" nil))
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
                               (concur:reject
                                any-p `(:aggregate-error
                                        "All promises were rejected"
                                        ,(cl-coerce errors 'list))))))))))
      any-p)))

;;;###autoload
(defun concur:all-settled (promises)
  "Return a promise that resolves after all PROMISES have settled.
The returned promise *always* resolves with a list of outcome
plists, so it never rejects.

(Examples)
  (concur:await
    (concur:all-settled (list (concur:resolved! 1)
                              (concur:rejected! \"err\"))))
  ;; => '((:status 'fulfilled :value 1)
  ;;      (:status 'rejected :reason \"err\"))

Arguments:
- `PROMISES` (list): A list of promises or values.

Returns:
  A promise that resolves to a list of outcome plists."
  (if (null promises)
      (concur:resolved! '())
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
                                          `(:status 'rejected
                                            :reason ,(concur:error-value p))
                                        `(:status 'fulfilled
                                          :value ,(concur:value p))))
                                (cl-incf settled-count)
                                (when (= settled-count total)
                                  (concur:resolve
                                   all-p (cl-coerce outcomes 'list)))))))))
      all-p)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility, Control Flow, and Async/Await Integration

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously wait for a promise to settle, cooperatively.

This macro's behavior depends on its calling context:
1.  **Inside a coroutine** (created with `defcoroutine!`):
    It suspends the coroutine without blocking Emacs, yielding control
    to the scheduler. Execution resumes when the promise settles.
2.  **Outside a coroutine**:
    It blocks the current thread but keeps Emacs responsive. This is
    achieved by a 'cooperative wait' that yields to the main event
    loop, allowing I/O and timers to run. This is crucial for
    preventing Emacs from freezing while waiting for an async result.

(Examples)
  ;; Blocking, but does not freeze Emacs UI.
  (concur:await (concur:delay 1 \"hello\"))
  ;; => \"hello\"

Arguments:
- `PROMISE-FORM`: An expression that evaluates to a `concur-promise`.
- `TIMEOUT` (number, optional): Timeout in seconds for the blocking version.

Returns:
  The resolved value of the promise. If the promise rejects, this
macro signals the rejection error."
  `(if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
       ;; Cooperative, non-blocking await for coroutines.
       (let ((promise ,promise-form))
         (if (concur-promise-resolved-p promise)
             (if-let ((err (concur:error-value promise)))
                 (signal (car err) (cdr err))
               (concur:value promise))
           (yield--internal-throw-form promise ',yield--await-external-status-key)))
     ;; Blocking await for normal functions.
     (concur--await-blocking ,promise-form ,timeout)))

;;;###autoload
(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with VALUE after SECONDS.

Arguments:
- `SECONDS` (float): The non-blocking delay in seconds.
- `VALUE` (any, optional): The value to resolve with. Defaults to `t`.

Returns:
  A `concur-promise` that resolves after the delay."
  (concur:with-executor
   (lambda (resolve _reject)
     (run-at-time seconds nil (lambda () (funcall resolve (or value t)))))))

;;;###autoload
(defun concur:timeout (promise timeout-seconds)
  "Wrap PROMISE, rejecting if it doesn't settle within TIMEOUT-SECONDS.

Arguments:
- `PROMISE` (concur-promise): The promise to apply a timeout to.
- `TIMEOUT-SECONDS` (float): The maximum seconds to wait.

Returns:
  A new `concur-promise` with the timeout behavior."
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
`FETCH-FN-FORM` should evaluate to a function of the form `(lambda
(callback))`, where `callback` is a function `(lambda (result
error))` that must be called exactly once.

Arguments:
- `FETCH-FN-FORM` (form): The form evaluating to the async function.

Returns:
  A `concur-promise` that settles based on the callback."
  `(concur:with-executor
    (lambda (resolve reject)
      (funcall ,fetch-fn-form
               (lambda (result error)
                 (if error
                     (funcall reject error)
                   (funcall resolve result)))))))

;;;###autoload
(defun concur:from-coroutine (runner &optional cancel-token)
  "Create a `concur-promise` that settles with a coroutine's final outcome.
This serves as the primary bridge from the coroutine world to the
promise world.

Arguments:
- `RUNNER` (function): The coroutine runner (returned by `defcoroutine!`).
- `CANCEL-TOKEN` (`concur-cancel-token`): An optional token to propagate
  cancellation into the coroutine.

Returns:
  A `concur-promise` that settles when the coroutine finishes."
  (let ((ctx (plist-get (symbol-plist runner) :coroutine-ctx)))
    (when cancel-token
      (put ctx :cancel-token cancel-token)))
  (concur:with-executor
   (lambda (resolve reject)
     (cl-labels ((drive-coro (&optional resume-val)
                   (condition-case-unless-debug err
                       ;; Drive the coroutine one step.
                       (pcase (resume! runner resume-val)
                         ;; If it yields `:await-external`, wait for the
                         ;; promise, then continue driving the coroutine.
                         (`(:await-external ,p)
                          (concur:then p #'drive-coro #'reject))
                         ;; Any other yielded value is sent back into the
                         ;; coroutine to continue its execution.
                         (yielded-val
                          (drive-coro yielded-val)))
                     ;; Handle the final signals from the coroutine.
                     (coroutine-done (funcall resolve (car err)))
                     (coroutine-cancelled (funcall reject err))
                     (error (funcall reject err)))))
       ;; Start the coroutine execution loop.
       (drive-coro)))
   cancel-token))

;;;###autoload
(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an async FN up to RETRIES times on failure.
`FN` is a function `(lambda ())` that returns a promise.

Arguments:
- `FN` (function): The function to retry.
- `:retries` (integer, optional): Max retry attempts. Defaults to 3.
- `:delay` (float or function, optional): Seconds between retries.
- `:pred` (function, optional): Predicate `(lambda (error))` to allow a retry.

Returns:
  A promise that resolves on success, or rejects if all retries fail."
  (let ((p (concur:make-promise))
        (attempt 0))
    (cl-labels ((do-try ()
                  (cl-incf attempt)
                  (concur:catch (funcall fn)
                                (lambda (err)
                                  (if (and (< attempt retries)
                                           (funcall pred err))
                                      (let ((d (if (functionp delay)
                                                   (funcall delay attempt)
                                                 delay)))
                                        (concur:then (concur:delay d)
                                                     #'do-try))
                                    (concur:rejected! err))))))
      (concur:then (do-try)
                   (lambda (res) (concur:resolve p res))
                   (lambda (err) (concur:reject p err))))
    p))

;;;###autoload
(cl-defun concur:map-series (items fn)
  "Process ITEMS sequentially with async FN `(lambda (item))`.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async function that returns a promise.

Returns:
  A promise that resolves with a list of results, or rejects on first failure."
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

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async function that returns a promise.

Returns:
  A promise that resolves with a list of results, or rejects on first failure."
  (concur:all (--map (funcall fn it) items)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Chain Macro & Expansion Helpers

(defun concur--special-or-macro-p (sym)
  "Return non-nil if SYM is a special form or macro."
  (or (special-form-p sym)
      (condition-case nil (macro-function sym) (error nil))
      (memq sym '(lambda defun defmacro let let* progn cond if))))

(defun concur--expand-sugar (steps)
  "Transform sugar keywords in STEPS into canonical `concur:chain` clauses."
  (let ((processed nil) (remaining steps))
    (while remaining
      (let ((key (pop remaining)) arg1 arg2)
        (pcase key
          (:map
           (setq arg1 (pop remaining))
           (push `(:then (lambda (<>) (--map (let ((it <>)) ,arg1) <>))) processed))
          (:filter
           (setq arg1 (pop remaining))
           (push `(:then (lambda (<>) (--filter (let ((it <>)) ,arg1) <>))) processed))
          (:each
           (setq arg1 (pop remaining))
           (push `(:then (lambda (<>) (prog1 <> (--each (let ((it <>)) ,arg1) <>))))
                 processed))
          (:sleep
           (setq arg1 (pop remaining))
           (push `(:then (lambda (val)
                           (concur:then (concur:delay (/ ,arg1 1000.0))
                                        (lambda (_) val))))
                 processed))
          (:log
           (let ((fmt (if (and remaining (stringp (car remaining)))
                          (pop remaining)
                        "%S")))
             (push `(:tap (message ,fmt <>)) processed)))
          (:retry
           (setq arg1 (pop remaining) arg2 (pop remaining))
           (push `(:then (lambda (<>)
                           (concur:retry (lambda () ,arg2)
                                         :retries ,arg1)))
                 processed))
          (_
           (push key processed)
           (when remaining (push (pop remaining) processed))))))
    (nreverse processed)))

(defun concur--expand-chain-steps (current-promise steps short-circuit-p)
  "Internal recursive helper to expand `concur:chain` and `concur:chain-when`."
  (if (null steps)
      current-promise
    (pcase steps
      ;; Success handler. The resolved value is available as `<>` in ARG.
      (`(:then ,arg . ,rest)
       (let ((next-promise `(concur:then
                             ,current-promise
                             (lambda (<>) ,(if short-circuit-p
                                               `(when <> ,arg)
                                             arg)))))
         (concur--expand-chain-steps next-promise rest short-circuit-p)))

      ;; Error handler. The rejection reason is available as `<!>` in ARG.
      (`(:catch ,arg . ,rest)
       (let ((next-promise `(concur:then ,current-promise nil
                                         (lambda (<!>) ,arg))))
         (concur--expand-chain-steps next-promise rest short-circuit-p)))

      ;; Side-effect handler. Runs ARG after settlement, passing through the
      ;; original result or error.
      (`(:finally ,arg . ,rest)
       (let ((next-promise `(concur:then
                             ,current-promise
                             (lambda (<>) (prog1 <> ,arg))
                             (lambda (<!>)
                               (prog1 (concur:rejected! <!>) ,arg)))))
         (concur--expand-chain-steps next-promise rest short-circuit-p)))

      ;; Side-effect "tap".
      (`(:tap ,arg . ,rest)
       (let ((next-promise `(concur:tap
                             ,current-promise
                             (lambda (<> error)
                               (declare (ignore error))
                               ,arg))))
         (concur--expand-chain-steps next-promise rest short-circuit-p)))

      ;; Lexical bindings. Introduces `let*` bindings for subsequent steps.
      (`(:let ,bindings . ,rest)
       `(let* ,bindings
          ,(concur--expand-chain-steps current-promise rest short-circuit-p)))

      ;; Composition. Replaces the current promise with one that waits for all
      ;; promises in ARG.
      (`(:all ,arg . ,rest)
       (concur--expand-chain-steps `(concur:all ,arg) rest short-circuit-p))

      ;; Composition. Replaces the current promise with one that settles with
      ;; the first promise in ARG.
      (`(:race ,arg . ,rest)
       (concur--expand-chain-steps `(concur:race ,arg) rest short-circuit-p))

      ;; Handle `<>` as a pass-through (identity) step.
      (`(<> . ,rest)
       (concur--expand-chain-steps current-promise rest short-circuit-p))

      ;; General shorthand for any form. Any step that is a list but
      ;; doesn't start with a known keyword is treated as a `:then` clause.
      (`(,(and (pred listp) form) . ,rest)
       (let ((next-promise `(concur:then
                             ,current-promise
                             (lambda (<>) ,(if short-circuit-p
                                               `(when <> ,form)
                                             form)))))
         (concur--expand-chain-steps next-promise rest short-circuit-p)))

      ;; Catch-all for invalid steps.
      (_ (error "Invalid concur:chain step: %S" (car steps))))))

;;;###autoload
(cl-defmacro concur:chain (initial-promise-expr &rest steps)
  "Thread INITIAL-PROMISE-EXPR through a series of asynchronous steps.

This macro provides a clean, sequential way to define a series of
asynchronous operations. The resolved value from the previous step
is available as `<>` in `:then` clauses and other steps. The
rejection reason is available as `<!>` in `:catch` clauses.

(Examples)
  (concur:chain (concur:resolved! 5)
    :then (lambda (v) (* v 10))   ; v is 5, returns 50
    :then (lambda (v) (message \"Final: %d\" v))) ; v is 50

Arguments:
- `INITIAL-PROMISE-EXPR` (form): A form that evaluates to a promise.
- `STEPS` (forms): A sequence of keywords and associated forms."
  (declare (indent 1))
  (concur--expand-chain-steps
   initial-promise-expr (concur--expand-sugar steps) nil))

;;;###autoload
(cl-defmacro concur:chain-when (initial-promise-expr &rest steps)
  "Like `concur:chain` but short-circuits on `nil` resolved values.
If any step resolves to `nil`, subsequent `:then` clauses and sugar
forms are skipped. `:catch` and `:finally` clauses are still executed."
  (declare (indent 1))
  (concur--expand-chain-steps
   initial-promise-expr (concur--expand-sugar steps) t))

(provide 'concur-promise)
;;; concur-promise.el ends here