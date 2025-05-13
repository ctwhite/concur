;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a lightweight Promise implementation for Emacs,
;; designed to support asynchronous workflows similar to JavaScript promises,
;; with explicit support for chaining, error handling, and finalization.
;;
;; It serves as the async primitive for the concur.el ecosystem and integrates
;; with `concur-future.el` and `concur-proc.el` to manage long-running external
;; commands, background computations, and concurrency orchestration.
;;
;; Features:
;;
;; - Basic promise lifecycle: resolve, reject
;; - Chaining via `concur-promise-then`
;; - Error handling via `concur-promise-catch`
;; - Cleanup/final steps via `concur-promise-finally`
;; - External process integration via `concur-promise-cmd`
;;
;; Example:
;;
;;   (concur-promise-then
;;     (concur-promise-cmd :command "ls" :args '("-la"))
;;     (lambda (output)
;;       (message "Listing: %s" output)))
;;
;; Or with macro threading (see `concur-promise->`):
;;
;;   (concur-promise->
;;     (concur-promise-cmd :command "ls")
;;     (message "Got: %s" <>)
;;     :then    (s-upcase <>)
;;     :catch   (message "Oops: %s" <>)
;;     :finally (message "Done"))
;;
;; This module is foundational and intended to be extensible,
;; but it avoids heavyweight constructs (like `cl-promise`)
;; for performance and debuggability in Emacs.
;;
;;; Code:

(require 'cl-lib)
(require 'concur-cancel)
(require 'concur-proc)
(require 'dash)
(require 'ht)
(require 'scribe)
(require 'ts)

(cl-defstruct
    (concur-promise
     (:constructor nil)
     (:constructor concur-promise-create (&key result error resolved? callbacks proc)))
  "A simple Promise implementation for async chaining.

The `concur-promise` struct represents an asynchronous operation that can either be resolved or rejected.
Callbacks can be added to a promise to handle its eventual result or error.
A promise can be in one of the following states:
  - Resolved: the operation was completed successfully.
  - Rejected: the operation failed.
  - Pending: the operation is still ongoing.

Fields:
  - `result`: The result of the promise if resolved, or `nil` if rejected or pending.
  - `error`: The error that caused the promise to be rejected, or `nil` if resolved or pending.
  - `resolved?`: A boolean indicating whether the promise has been resolved (either with a 
                result or an error).
  - `callbacks`: A list of functions to be called when the promise settles. Each function 
                receives two arguments: `result` and `error`.
  - `proc`: The process associated with the promise, used for monitoring its status (e.g., in 
            case of async operations like waiting for process output).
  - `cancel-token`: A token used to cancel the promise.

Example:
  (let ((p (concur-promise-new)))
    (concur-promise-then p
                  (lambda (res err)
                    (if err
                        (message \"Promise failed with: %s\" err)
                      (message \"Promise succeeded with: %s\" res)))))
  
  This code will add a callback to the promise `p` that will print either the error or the 
  result when the promise settles."
  result
  error
  resolved?
  callbacks
  cancel-token
  proc)

(defconst concur--promise-cancelled-key :cancelled
  "Keyword key used in promise rejection objects to indicate cancellation.")

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, rejected promises will throw an error for debugging purposes."
  :type 'boolean
  :group 'concur)

;;;###autoload
(defun concur-promise-new (&rest slots)
  "Create and return a new unresolved promise.

SLOTS is an optional plist of initial values for internal fields,
such as :resolved?, :value, :error, :callbacks, etc."
  (apply #'concur-promise-create
         :resolved? nil
         :callbacks nil
         slots))

;;;###autoload
(defun concur-promise-run (fn)
  "Create a promise and invoke FN with (resolve reject) functions."
  (let ((p (concur-promise-new)))
    (funcall fn
             (lambda (val) (concur-promise-resolve p val))
             (lambda (err) (concur-promise-reject p err)))
    p))

;;;###autoload
(defmacro concur-promise-do! (&rest body)
  "Create a promise with `resolve` and `reject` available for async use.

- Binds `resolve` and `reject` inside BODY.
- Automatically wraps BODY in `condition-case` to catch sync errors.
- Supports future cancellation by attaching a `cancel` slot (noop by default).

Example:
  (concur-promise-do
    (run-at-time 1 nil (lambda () (funcall resolve \"OK\"))))"
  (declare (indent 1) (debug (form &rest (sexp body))))
  `(let ((p (concur-promise-new)))
     (condition-case err
         (let ((resolve (lambda (val) (concur-promise-resolve p val)))
               (reject  (lambda (err) (concur-promise-reject p err))))
           ,@body)
       (error (concur-promise-reject p err)))
     p))

(defun concur-promise--run-callbacks (promise result error)
  "Invoke all callbacks on PROMISE with RESULT and ERROR."
  (let ((callbacks (concur-promise-callbacks promise)))
    (setf (concur-promise-callbacks promise) nil)
    (--each callbacks
      (ignore-errors
        (funcall it result error)))))

;;;###autoload
(defun concur-promise-resolve (promise result)
  "Resolve PROMISE with RESULT. Does nothing if already settled."
  (unless (concur-promise-resolved? promise)
    (setf (concur-promise-result promise) result
          (concur-promise-error promise) nil
          (concur-promise-resolved? promise) t)
    (concur-promise--run-callbacks promise result nil)))

;;;###autoload
(defun concur-promise-reject (promise error)
  "Reject PROMISE with ERROR. Does nothing if already settled."
  (unless (concur-promise-resolved? promise)
    ;; Mark the promise as rejected
    (setf (concur-promise-error promise) error
          (concur-promise-resolved? promise) t)

    (log! "Promise rejected: %S with error: %S" promise error :level 'error)
    (concur-promise--run-callbacks promise nil error)

    ;; Throw only *after* callbacks are run
    (when concur-throw-on-promise-rejection
      (error "[concur] Promise rejected with error: %S" error))))

;;;###autoload
(defun concur-promise-from-callback (fetch-fn)
  "Wrap a callback-based async FETCH-FN into a promise.

FETCH-FN should accept a callback of the form:
  (lambda (result error))

It must call this callback exactly once:
- success: (result non-nil, error nil)
- failure: (result nil, error non-nil)

Returns a promise that resolves or rejects accordingly."
  (let ((promise (concur-promise-new)))
    (funcall fetch-fn
             (lambda (result error)
               (if error
                   (concur-promise-reject promise error)
                 (concur-promise-resolve promise result))))
    promise))

;;;###autoload
(defun concur-promise-on-resolve (promise callback)
  "Register CALLBACK to be invoked when PROMISE is resolved or rejected.

CALLBACK must accept (lambda (result error)).

If already settled, the callback runs immediately. Otherwise,
it is queued and executed on resolution or rejection."
  (if (concur-promise-resolved? promise)
      (funcall callback
               (concur-promise-result promise)
               (concur-promise-error promise))
    (setf (concur-promise-callbacks promise)
          (append (concur-promise-callbacks promise)
                  (list callback)))))

;;;###autoload
(defun concur-promise-resolved! (value)
  "Return a promise already resolved with VALUE."
  (let ((p (concur-promise-new)))
    (setf (concur-promise-result p) value
          (concur-promise-resolved? p) t)
    p))

;;;###autoload
(defun concur-promise-rejected! (err)
  "Return a promise already rejected with ERR."
  (let ((p (concur-promise-new)))
    (setf (concur-promise-error p) err
          (concur-promise-resolved? p) t)
    (log! "Created rejected promise: %S with error: %S" p err :level 'error)
    p))

;;;###autoload
(defun concur-promise-cancel (promise &optional reason)
  "Cancel PROMISE by rejecting it with REASON and killing its process."
  (let ((proc (concur-promise-proc promise)))
    (when (and proc (process-live-p proc))
      (log! "Cancelling process %S for promise %S" proc promise)
      (kill-process proc)))
  (unless (concur-promise-resolved? promise)
    (let ((cancel-reason (if (and (consp reason) (plist-member reason :cancelled))
                             reason
                           (list :cancelled (or reason "Cancelled")))))
      (concur-promise-reject promise cancel-reason))))

;;;###autoload
(defun concur-promise-cancelled? (promise)
  "Return non-nil if PROMISE was cancelled.

A promise is considered cancelled if its rejection reason contains the `:cancelled` key."
  (let ((err (concur-promise-error promise)))
    (and (consp err)
         (plist-member err concur--promise-cancelled-key))))

;;;###autoload
(defun concur-promise-with-cancel (cancel-token fn)
  "Wrap FN in a promise that is cancelled if CANCEL-TOKEN is triggered.

FN is a function that takes two arguments:
  (lambda (value))  ; resolve
  (lambda (error))  ; reject

Returns a promise that will resolve/reject via FN or cancel early via CANCEL-TOKEN."
  (let ((promise (concur-promise-new))
        (cancel-id nil))

    (cond
     ;; Already cancelled
     ((and cancel-token (concur-cancel-token-cancelled? cancel-token))
      (concur-promise-cancel promise '(:cancelled "Cancelled before start")))

     ;; Not cancelled yet; register hook and run
     (t
      (when cancel-token
        (setq cancel-id
              (concur-cancel-token-register
               cancel-token
               (lambda ()
                 (unless (concur-promise-resolved? promise)
                   (concur-promise-cancel promise '(:cancelled "Cancelled")))))))

      (funcall fn
               (lambda (value)
                 (unless (concur-promise-resolved? promise)
                   (when (and cancel-token cancel-id)
                     (concur-cancel-token-unregister cancel-token cancel-id))
                   (concur-promise-resolve promise value)))
               (lambda (err)
                 (unless (concur-promise-resolved? promise)
                   (when (and cancel-token cancel-id)
                     (concur-cancel-token-unregister cancel-token cancel-id))
                   (concur-promise-reject promise err))))))
    promise))

;;;###autoload
(defun concur-promise-rejected? (promise)
  "Return non-nil if PROMISE has been rejected."
  (and (concur-promise-resolved? promise)
       (concur-promise-error? promise)))

;;;###autoload
(defun concur-promise-error? (promise)
  "Return non-nil if PROMISE has an error (was rejected)."
  (not (null (concur-promise-error promise))))

;;;###autoload
(defun concur-promise-status (promise)
  "Return the current status of PROMISE as a symbol.

Possible values:
- 'pending
- 'resolved
- 'rejected
- 'cancelled"
  (cond
   ((not (concur-promise-resolved? promise)) 'pending)
   ((concur-promise-cancelled? promise) 'cancelled)
   ((concur-promise-rejected? promise) 'rejected)
   (t 'resolved)))

;;;###autoload
(defun concur-promise-await (promise &optional timeout throw-on-error proc-time)
  "Block until PROMISE resolves or TIMEOUT seconds elapse.

Arguments:
  PROMISE         -- The `concur-promise` to wait on.
  TIMEOUT         -- Optional timeout in seconds. If nil, wait indefinitely.
  THROW-ON-ERROR  -- If non-nil, raise an error on rejection or timeout.
  PROC-TIME       -- Optional interval in seconds to wait per poll (default: 0.1s).

Return:
  The result value of the resolved promise. If rejected and THROW-ON-ERROR is nil,
  returns nil and logs the error."
  (let* ((start (ts-now))
         (interval (or proc-time 0.1))
         (proc (concur-promise-proc promise)))
    (while (not (concur-promise-resolved? promise))
      ;; If there is a process, use accept-process-output
      (if proc
          (accept-process-output proc interval)
        ;; Otherwise, use sit-for for non-process events like run-at-time
        (sit-for interval))

      ;; Timeout check
      (when (and timeout
                 (> (ts-diff (ts-now) start 'second) timeout))
        (unless (concur-promise-resolved? promise)
          (concur-promise-cancel promise '(:timeout "Promise timed out"))
          (when throw-on-error
            (error "Promise timed out after %.2fs" timeout))
          (return-from concur-promise-await nil))) ;; Exit if timeout occurs

      ;; Exit if the promise was rejected or canceled
      (when (or (concur-promise-rejected? promise)
                (concur-promise-cancelled? promise))
        (let ((err (or (concur-promise-error promise)
                       '(:cancel "Promise was canceled"))))
          (log! "Promise rejected or canceled: %S" err :level 'error)
          (when throw-on-error
            (error "Promise rejected or canceled: %S" err))
          (return-from concur-promise-await nil)))) ;; Exit if rejected or canceled

    ;; After resolving, check for rejection and handle the result
    (if-let ((err (concur-promise-error promise)))
        (progn
          (log! "Promise rejected with error: %S" err :level 'error)
          (when throw-on-error
            (error "Promise rejected: %s" err))
          nil)
      ;; Return the result if resolved
      (concur-promise-result promise))))

;;;###autoload
(defun concur-promise-then (promise callback)
  "Return a new promise that chains CALLBACK to PROMISE.

Arguments:
  PROMISE  -- The initial `concur-promise` to attach a callback to.
  CALLBACK -- A function (lambda (result error)) called after PROMISE resolves.
              If it returns another promise, the returned value is chained.

Return:
  A new `concur-promise` that resolves or rejects based on the callback's outcome.

Example:
  (let ((p (concur-promise-resolved! 10)))
    (concur-promise-then p
                         (lambda (res _err)
                           (* res 2)))) ; => Promise that eventually resolves to 20"
  (let ((chained (concur-promise-new)))
    (concur-promise-on-resolve
     promise
     (lambda (res err)
       (condition-case-unless-debug ex
           (let ((next (funcall callback res err)))
             (if (concur-promise-p next)
                 (concur-promise-on-resolve
                  next
                  (lambda (r e)
                    (if e
                        (concur-promise-reject chained e)
                      (concur-promise-resolve chained r))))
               (if err
                   (concur-promise-reject chained err)
                 (concur-promise-resolve chained next))))
         (error
          (log! "Promise callback failed: %S" ex :level 'error)
          (concur-promise-reject chained ex)))))
    chained))

;;;###autoload
(defun concur-promise-catch (promise handler)
  "Attach HANDLER to PROMISE, which runs only if PROMISE is rejected.

Arguments:
- PROMISE: A `concur-promise` instance.
- HANDLER: A function called with (res err) if PROMISE is rejected.

Return:
A new `concur-promise` that resolves with HANDLER’s return value on error,
or passes through the original resolved value unchanged.

Example:
  (concur-promise-catch some-promise
                        (lambda (_ err)
                          (message \"Recovered from: %s\" err)
                          \"default-value\"))"
  (let ((next (concur-promise-new)))
    (concur-promise-on-resolve
     promise
     (lambda (res err)
       (if err
           (condition-case ex
               (concur-promise-resolve next (funcall handler res err))
             (error (concur-promise-reject next ex)))
         (concur-promise-resolve next res))))
    next))

;;;###autoload
(defun concur-promise-finally (promise callback)
  "Attach CALLBACK to PROMISE to run after it settles, regardless of outcome.

Arguments:
- PROMISE: A `concur-promise` instance.
- CALLBACK: A function called with (res err) after PROMISE is resolved or rejected.

Return:
A new `concur-promise` that forwards the original result or error.

Example:
  (concur-promise-finally some-promise
                          (lambda (_res _err)
                            (message \"Cleaning up\")))"
  (let ((next (concur-promise-new)))
    (concur-promise-on-resolve
     promise
     (lambda (res err)
       (condition-case ex
           (progn
             (funcall callback res err)
             (if err
                 (concur-promise-reject next err)
               (concur-promise-resolve next res)))
         (error (concur-promise-reject next ex)))))
    next))

(defun concur-promise-error-message (promise)
  "Return a human-readable message for PROMISE error, if any.

Arguments:
- PROMISE: A `concur-promise` instance.

Return:
A string describing the error, or nil if no error is present.

Example:
  (message \"Error: %s\" (concur-promise-error-message my-promise))"
 (let ((err (concur-promise-error promise)))
    (cond
     ((stringp err) err)
     ((plistp err) (or (plist-get err :error)
                       (plist-get err :message)))
     ((symbolp err) (symbol-name err))
     (t (format "%S" err)))))

;;;###autoload
(defun concur-promise-wrap (fn &rest args)
  "Execute FN with ARGS, wrapping the result in a promise.

Arguments:
- FN: A function to call.
- ARGS: Arguments to apply to FN.

Return:
A `concur-promise` resolved with the result, or rejected with the error if FN fails.

Example:
  (concur-promise-wrap (lambda () (/ 1 0)))  ;; rejected
  (concur-promise-wrap #'length '(1 2 3))    ;; resolved with 3"
  (let ((p (concur-promise-new)))
    (condition-case ex
        (concur-promise-resolve p (apply fn args))
      (error (concur-promise-reject p ex)))
    p))

(defun concur-promise-apply-transform (transform res err target)
  "Apply TRANSFORM to RES and ERR, resolving or rejecting TARGET accordingly.

Arguments:
- TRANSFORM: A function taking (res err), which may return a promise or value.
- RES: Result from a previous promise.
- ERR: Error from a previous promise.
- TARGET: A `concur-promise` to resolve/reject with TRANSFORM's result.

Return:
None. TARGET is updated in-place.

Example:
  (concur-promise-apply-transform
   (lambda (res _err) (concat res \"!\")) \"Hello\" nil target-promise)"
  (condition-case ex
      (let ((result (funcall transform res err)))
        (if (concur-promise-p result)
            (concur-promise-then result
                                 (lambda (r e)
                                   (if e
                                       (concur-promise-reject target e)
                                     (concur-promise-resolve target r))))
          (concur-promise-resolve target result)))
    (error (concur-promise-reject target ex))))

;;;###autoload
(defun concur-promise-chain (promise transform)
  "Return a new promise that applies TRANSFORM to PROMISE result.

Arguments:
- PROMISE: A `concur-promise` to observe.
- TRANSFORM: A function called with (res err) when PROMISE settles.

Return:
A new `concur-promise`. If TRANSFORM returns a promise, it will be chained.
If it returns a raw value, the resulting promise is resolved with it.

Example:
  (concur-promise-chain my-promise
                        (lambda (res err)
                          (if err
                              (format \"Failed: %s\" err)
                            (concat res \"!\"))))"
  (let ((next (concur-promise-new)))
    (concur-promise-then
     promise
     (lambda (res err)
       (if err
           (concur-promise-reject next err)
         (concur-promise-apply-transform transform res err next))))
    next))

;;;###autoload
(defun concur-promise-tap (promise callback)
  "Attach CALLBACK to PROMISE for side effects without chaining.

CALLBACK is called with (value error) when PROMISE resolves or rejects.
Returns the original PROMISE for chaining."
  (concur-promise-then
   promise
   (lambda (value error)
     (funcall callback value error)
     nil)) ;; discard result, don't affect any chained promise
  promise)

;;;###autoload 
(defmacro concur-promise-> (promise &rest steps)
  "Thread PROMISE through STEPS using `concur-promise-chain` and anaphoric lambdas.

Each STEP can refer to the previous result using the symbol `<>`. Special keywords
are supported for error handling and finalization.

Arguments:
  PROMISE -- The initial promise expression to thread through.
  STEPS   -- A sequence of forms to apply. May include:
             - Regular forms that use `<>` to access the previous result.
             - Keyword pairs:
               :then    FORM      (additional step)
               :catch   HANDLER   (called on rejection, with `<>` bound to error)
               :finally HANDLER   (called regardless of outcome)

Return:
  A promise resulting from chaining all steps, with error and final handlers applied.

Example:
  (concur-promise->
   (concur-promise-cmd :command \"ls\")
   (message \"Got: %s\" <>)
   :then    (s-upcase <>)
   :catch   (message \"Oops: %s\" <>)
   :finally (message \"Finished\"))"
  (let ((catch-fn nil)
        (finally-fn nil)
        (core-steps '()))
    ;; Partition steps by keyword
    (while steps
      (let ((step (pop steps)))
        (pcase step
          (:catch   (setq catch-fn (pop steps)))
          (:finally (setq finally-fn (pop steps)))
          (:then    (push (pop steps) core-steps))
          (_        (push step core-steps)))))
    (setq core-steps (nreverse core-steps))

    ;; Chain `:then` steps using concur-promise-chain
    (let ((p promise))
      (dolist (body core-steps)
        (setq p
              `(concur-promise-chain
                ,p
                (lambda (<> <!>) (declare (ignore <!>)) ,body))))

      ;; Attach catch handler if provided
      (when catch-fn
        (setq p
              `(concur-promise-catch
                ,p
                (lambda (<> <!>) (let ((<!> <!>)) ,catch-fn)))))

      ;; Attach finally handler if provided
      (when finally-fn
        (setq p
              `(concur-promise-finally
                ,p
                (lambda (<> <!>) (let ((<> <>) (<!> <!>)) ,finally-fn)))))

      p)))

;;;###autoload
(defun concur-promise-all (promises &rest opts)
  "Return a promise that resolves when all PROMISES are fulfilled, or rejects on the first error.

PROMISES is a list of promise objects. This function executes them in parallel
and returns a new promise that:
  - Resolves to a list of results in the same order as PROMISES if all succeed.
  - Rejects immediately if any individual promise fails.
  - Resolves to an empty list immediately if PROMISES is nil.

Optional OPTS:
  :cancel-token — if provided, the returned promise will be cancelled when the token triggers."
  (unless (listp promises)
    (signal 'wrong-type-argument (list 'listp promises)))

  (let ((cancel-token (plist-get opts :cancel-token)))
    (if (null promises)
        (progn
          (log! "No promises provided, resolving with empty list.")
          (concur-promise-resolve '()))  ; Return immediately with an empty result
      (let* ((total (length promises))
             (results (make-vector total nil))  ; Create a vector to hold results
             (done (concur-promise-new))  ; The final promise we are going to return
             (resolved-count 0))
        
        (when cancel-token
          (log! "Cancel token provided, attaching to final promise.")
          (concur-promise-with-cancel done cancel-token))  ; Attach cancel token
        
        (log! "Processing %d promises..." total)
        (--each-indexed promises
          (let ((index it-index)
                (promise it))
            (log! "Processing promise at index %d" index)
            (concur-promise-then
             promise
             (lambda (res err)
               (if err
                   (progn
                     (log! "Promise at index %d failed with error: %S" index err)
                     (unless (concur-promise-resolved? done)
                       (concur-promise-reject! done err)))  ; Reject immediately on error
                 (progn
                   (log! "Promise at index %d resolved with result: %S" index res)
                   (aset results index res)  ; Store the result at the correct index
                   (setq resolved-count (1+ resolved-count))
                   (when (= resolved-count total)  ; All promises resolved
                     (log! "All promises resolved. Returning results.")
                     (concur-promise-resolve done (cl-coerce results 'list)))))))))
        done))))  ; Return the promise holding the aggregated results

;;;###autoload
(defun concur-promise-race (promises)
  "Return a promise that resolves or rejects with the first PROMISE to settle.

Arguments:
  PROMISES -- A list of promises.

Return:
  A new promise that settles (resolves or rejects) with the result of the first
  promise in the list that does.

Example:
  (let ((p1 (exec-promise! :command \"sleep 2\"))
        (p2 (exec-promise! :command \"echo Hello\")))
    (concur-promise-race (list p1 p2)
      (lambda (result)
        (message \"First resolved: %s\" result))))"
  (if (null promises)
      (concur-promise-reject (concur-promise-new) 'no-promises)
    (let ((winner (concur-promise-new)))
      (--each promises
        (concur-promise-then it
          (lambda (res err)
            (unless (concur-promise-resolved? winner)
              (if err
                  (concur-promise-reject winner err)
                (concur-promise-resolve winner res))))))
      winner)))

;;;###autoload
(defun concur-promise-delay (seconds &optional value)
  "Return a promise that resolves with VALUE after SECONDS.

Arguments:
  SECONDS -- Time to delay before resolving (can be fractional).
  VALUE   -- Optional value to resolve with (defaults to `t`).

Return:
  A promise that resolves after SECONDS with VALUE.

Example:
  (concur-promise-delay 2 \"Done\"
    (lambda (result)
      (message \"Resolved after delay: %s\" result)))"
  (if (<= seconds 0)
      (let ((p (concur-promise-new)))
        (concur-promise-resolve p (or value t))
        p)
    (let ((p (concur-promise-new)))
      (run-at-time seconds nil
                   (lambda ()
                     (concur-promise-resolve p (or value t))))
      p)))

;;;###autoload
(defun concur-promise-timeout (inner-promise timeout-seconds)
  "Wrap INNER-PROMISE and reject if it doesn't resolve in TIMEOUT-SECONDS.

Arguments:
  INNER-PROMISE     -- The promise to wait on.
  TIMEOUT-SECONDS   -- Time in seconds before the timeout triggers.

Return:
  A new promise that:
    - Resolves/rejects with INNER-PROMISE if it settles before the timeout.
    - Rejects with `'timeout` if the timeout elapses first."
  (let ((timeout (concur-promise-new)))
    (run-at-time timeout-seconds nil
                 (lambda ()
                   (unless (concur-promise-resolved? timeout)
                     (concur-promise-reject timeout 'timeout))))
    (concur-promise-race (list inner timeout))))

;;;###autoload
(cl-defun concur-promise-retry (fn &key (interval 1) (limit 5) (test #'identity))
  "Call FN every INTERVAL seconds, up to LIMIT times.
Resolves when TEST returns non-nil on result. Rejects otherwise.

FN is a function that returns a promise. The function will be retried up to LIMIT
times, with an INTERVAL (in seconds) between each retry. The result of each retry
will be passed to TEST, and the promise resolves when TEST returns a truthy value.

Example:
  (let ((retry-promise (concur-promise-retry
                        (lambda () (concur-promise-cmd :command \"curl http://example.com\")))))
    (concur-promise-then retry-promise
                         (lambda (res _err) (message \"Successfully retrieved: %s\" res)))
    (concur-promise-catch retry-promise
                         (lambda (_ err) (message \"Failed with error: %s\" err)))))
    
In this example, `concur-promise-retry` retries a command (such as a `curl` request) until it
either succeeds or reaches the retry limit. The promise resolves with the result of the
successful command or rejects after the retries are exhausted."
  (let ((p (concur-promise-new))
        (attempt 1))
    (cl-labels ((try ()
                  (concur-promise-then (funcall fn)
                    (lambda (res err)
                      (if err
                          (if (< attempt limit)
                              (progn
                                (cl-incf attempt)
                                (run-at-time interval nil #'try))
                            (concur-promise-reject p err))
                        (if (funcall test res)
                            (concur-promise-resolve p res)
                          (if (< attempt limit)
                              (progn
                                (cl-incf attempt)
                                (run-at-time interval nil #'try))
                            (concur-promise-reject p 'retry-limit))))))))
      (try))
    p))

;;;###autoload
(defmacro concur-promise-lambda! (&rest body)
  "Create a lambda that returns a promise, wrapping BODY in `concur-promise-new`.
  
BODY should include code for handling `resolve` and `reject` to fulfill the promise. 
  
Example usage:
  (concur-promise-cmd (concur-promise-lambda!
      (run-at-time 1 nil (lambda () (funcall resolve \"hello\")))))"
  (if body
      `(lambda ()
         (let ((promise (concur-promise-new)))
           (let ((resolve (lambda (result) (concur-promise-resolve promise result)))
                 (reject (lambda (err) (concur-promise-reject promise err))))
             ,@body
             promise)))
    (error "Body cannot be empty")))

;;;###autoload
(defmacro concur-promise-let (bindings &rest body)
  "Asynchronously bind values using promises in parallel. Supports destructuring.

Each binding is of the form (VAR FORM) or ((PATTERN...) FORM), where FORM returns a promise.

BODY can use `<>` to refer to the list of all resolved values (in order)."
  (let* ((forms (--map (cadr it) bindings))
         (patterns (--map (car it) bindings)))
    `(concur-promise-then
      (concur-promise-all ,@forms)
      (lambda (<>)
        (let ,(--map-indexed
               (lambda (i pat)
                 `(,pat (nth ,i <>)))
               patterns)
          ,@body)))))

(defun concur-promise-delayed (secs)
  "Return a promise that resolves after SECS seconds."
  (let ((p (concur-promise-new)))
    (run-at-time secs nil (lambda () (concur-promise-resolve p t)))
    p))

;;;###autoload
(defmacro concur-promise-let* (bindings &rest body)
  "Like `let*`, but for chaining async promises sequentially.
Each binding is resolved before the next one.

Example:
  (concur-promise-let* ((x (fetch-data))
                        (y (process-data x)))
    (message \"Processed data: %s\" y))

Each binding must be a (var expr) pair.
The `<>` symbol can be used in BODY to refer to the resolved value of the current promise."
  (declare (indent 1))
  (if (null bindings)
      `(concur-promise-resolve (progn ,@body))
    (let ((binding (car bindings)))
      (unless (and (listp binding)
                   (= (length binding) 2)
                   (symbolp (car binding)))
        (error "Invalid binding in `concur-promise-let*`: %S. Expected (var expr) pair." binding))
      (let ((var (car binding))
            (form (cadr binding)))
        `(concur-promise-then ,form
           (lambda (<>)
             (let ((,var <>))
               (concur-promise-let* ,(cdr bindings) ,@body))))))))

;;;###autoload
(defmacro concur-promise-loop (args &rest body)
  "Asynchronously iterate over LIST-FORM, binding each element to VAR.
Each step in BODY may use `<>` as the result of the previous promise.

Supports the following keyword clauses:
  :catch   - Defines an error handler that is triggered on failure.
  :finally - Defines a handler that runs after the loop finishes (whether success or failure).

Example:
  (concur-promise-loop (x '(1 2 3))
    (message \"Got: %s\" x)
    (do-something-async <>)
    :catch (message \"Caught error: %s\" <>)
    :finally (message \"Loop finished\"))

This example iterates over the list `(1 2 3)`, binding each element to `x`. 
After each iteration, `do-something-async` is executed asynchronously, 
and errors are caught in `:catch`."
  (let* ((var (car args))  
         (list-form (cadr args))
         (items (gensym "items"))
         (result (gensym "result"))
         (catch-fn nil)
         (finally-fn nil)
         (core-forms '()))
    ;; Parse keyword clauses
    (while body
      (let ((form (pop body)))
        (pcase form
          (:catch   (setq catch-fn (pop body)))
          (:finally (setq finally-fn (pop body)))
          (_        (push form core-forms)))))
    (setq core-forms (nreverse core-forms))

    `(let ((,items ,list-form)
           (,result (concur-promise-resolve nil)))
       (dolist (,var ,items ,result)
         (setq ,result
               (concur-promise-then ,result
                 (lambda (_)
                   ,(cl-reduce
                      (lambda (acc form)
                        `(concur-promise-then ,acc (lambda (<>) ,form)))
                      core-forms
                      :initial-value `(concur-promise-resolve nil))))))
       ,(when catch-fn
          `(setq ,result
                 (concur-promise-catch ,result (lambda (<>) ,catch-fn))))
       ,(when finally-fn
          `(setq ,result
                 (concur-promise-finally ,result (lambda (<>) ,finally-fn))))
       ,result)))

;;;###autoload
(defun concur-promise-spawn (program args &optional buffer)
  "Start PROGRAM with ARGS asynchronously using `start-process`.
Returns a promise resolving to (:exit :stdout :stderr).

BUFFER is the buffer to collect stdout (defaults to a new buffer).
A temporary stderr buffer will always be created.

Example:
  (proc-promise-spawn \"ls\" '(\"-l\" \"/\"))
  
This example runs the `ls -l /` command asynchronously and returns a promise that resolves
with the exit code and the output of stdout and stderr."
  (let ((stdout-buf (or buffer (generate-new-buffer "*concur-promise-stdout*")))
        (stderr-buf (generate-new-buffer "*concur-promise-stderr*"))
        (p (concur-promise-new)))
    (let ((proc (apply #'start-process
                       "concur-promise-subprocess"
                       stdout-buf
                       program args)))
      (set-process-sentinel
       proc
       (lambda (_proc _event)
         (when (memq (process-status _proc) '(exit signal))
           (let* ((exit-code (process-exit-status _proc))
                  (stdout (with-current-buffer stdout-buf (buffer-string)))
                  (stderr (with-current-buffer stderr-buf (buffer-string))))
             (kill-buffer stdout-buf)
             (kill-buffer stderr-buf)
             (concur-promise-resolve p
               (list :exit exit-code :stdout stdout :stderr stderr))))))
      ;; Attach stderr if supported
      (set-process-plist proc (list :stderr-buffer stderr-buf))
      p)))

;;;###autoload
(defun concur-promise-cmd (&rest keys)
  "Run an async command using `concur-proc` and return a promise.

KEYS are passed to `concur-proc`, and should include:
  :command, :args, and optionally :cwd, :env, :trace, :discard-ansi, etc.
  If :die-on-error is non-nil, the promise will reject if the command exits with a non-zero code.
  Optionally, include :log-max-len (default 80) to control stdout/stderr truncation in logs.

Returns a promise that resolves with trimmed stdout (a string),
or rejects with a plist containing :error, :exit, :stdout, :stderr, :cmd, and :args."
  (let* ((params keys)
         (log-max-len (or (plist-get keys :log-max-len) 80))
         (promise (concur-promise-new))
         (callback
          (lambda (res)
            (let* ((exit   (plist-get res :exit))
                   (stdout (s-trim (or (plist-get res :stdout) "")))
                   (stderr (or (plist-get res :stderr) ""))
                   (cmd    (plist-get res :cmd))
                   (args   (plist-get res :args))
                   (die-on-error (plist-get params :die-on-error)))
              (log!
               "%s %s | exit=%d | stdout=%s | stderr=%s"
               cmd
               (s-join " " args)
               exit
               (if (> (length stdout) log-max-len)
                   (format "%s..." (substring stdout 0 log-max-len))
                 stdout)
               (if (> (length stderr) log-max-len)
                   (format "%s..." (substring stderr 0 log-max-len))
                 stderr))
              (if (and die-on-error (not (zerop exit)))
                  (concur-promise-reject
                   promise
                   (list
                    :error (format "Command failed: %s %s (exit %d)"
                                   cmd
                                   (s-join " " args)
                                   exit)
                    :exit exit
                    :stdout stdout
                    :stderr stderr
                    :cmd cmd
                    :args args))
                (concur-promise-resolve promise stdout))))))

    ;; Run the async command and apply the callback
    (setf (concur-promise-proc promise)
          (apply #'concur-proc
                 (append params (list :callback callback))))

    ;; Register post-run resolution handler
    (concur-promise-then promise
                         (lambda (res err)
                           (if err
                               (concur-promise-reject promise err)
                             (concur-promise-resolve promise res))))
    promise))
    
;;; Aliases

(defalias 'concur-> 'concur-promise->)
(defalias 'concur-then 'concur-promise-then)
(defalias 'concur-catch 'concur-promise-catch)
(defalias 'concur-finally 'concur-promise-finally)
(defalias 'concur-await 'concur-promise-await)
(defalias 'concur-resolve 'concur-promise-resolve)
(defalias 'concur-resolved? 'concur-promise-resolved?)
(defalias 'concur-resolved! 'concur-promise-resolved!)
(defalias 'concur-cancel 'concur-promise-cancel)
(defalias 'concur-cancelled? 'concur-promise-cancelled?)
(defalias 'concur-reject 'concur-promise-reject)
(defalias 'concur-rejected? 'concur-promise-rejected?)
(defalias 'concur-rejected! 'concur-promise-rejected!)
(defalias 'concur-chain 'concur-promise-chain)
(defalias 'concur-all 'concur-promise-all)
(defalias 'concur-race 'concur-promise-race)
(defalias 'concur-delay 'concur-promise-delay)
(defalias 'concur-timeout 'concur-promise-timeout)
(defalias 'concur-retry 'concur-promise-retry)
(defalias 'concur-let 'concur-promise-let)
(defalias 'concur-let* 'concur-promise-let*)
(defalias 'concur-loop 'concur-promise-loop)
(defalias 'concur-cmd 'concur-promise-cmd)
(defalias 'concur-spawn 'concur-promise-spawn)
(defalias 'concur-do! 'concur-promise-do!)

(provide 'concur-promise)
;;; concur-promise.el ends here
