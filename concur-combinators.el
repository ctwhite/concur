;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-combinators.el --- Combinator functions for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides functions that operate on collections of promises,
;; allowing for complex asynchronous control flow. It includes standard
;; combinators like `concur:all` (wait for all to fulfill), `concur:race`
;; (wait for the first to settle), and `concur:any` (wait for the first to
;; fulfill). It also includes higher-level utilities like `concur:timeout`
;; and `concur:retry`.
;;
;; **Promise Mode Propagation:**
;; Combinator functions correctly determine and propagate the strongest
;; concurrency mode from their input promises to their resulting promise,
;; ensuring appropriate synchronization for aggregated asynchronous results.
;; Users can also explicitly provide a `:mode` keyword to override this.

;;; Code:

(require 'cl-lib)        ; For cl-loop, cl-coerce, cl-delete-duplicates, etc.
(require 'dash)          ; For --each-indexed, --map, -some, -count
(require 'concur-core)   ; For `concur-promise` types, `concur:make-promise`,
                         ; `concur:resolved!`, `concur:rejected!`,
                         ; `concur:resolve`, `concur:reject`, `concur:status`,
                         ; `concur:value`, `concur:error-value`,
                         ; `concur:error-message`, `concur:pending-p`,
                         ; `concur:rejected-p`, `concur:make-error`,
                         ; `concur:with-executor`, `concur-promise-mode`
(require 'concur-chain)  ; For `concur:then`
(require 'concur-lock)   ; For mutexes (`concur:with-mutex!`)
(require 'concur-log)    ; For `concur--log`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Helpers

(defun concur-determine-strongest-mode (promises-list default-mode)
  "Determine the 'strongest' concurrency mode from a list of promises.
`:thread` is strongest, then `:async`, then `:deferred`.

  Arguments:
  - `promises-list` (list): List of `concur-promise` objects or values.
  - `default-mode` (symbol): The mode to return if no promises are found.

  Returns:
  - (symbol): The strongest concurrency mode."
  (let ((strongest default-mode))
    (dolist (p promises-list)
      (when (concur-promise-p p)
        (let ((mode (concur-promise-mode p)))
          (cond
           ((eq mode :thread) (setq strongest :thread) (cl-return))
           ((eq mode :async) (setq strongest :async))
           ((eq mode :deferred) (setq strongest :deferred)))))
      (when (eq strongest :thread) (cl-return)))
    strongest))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Combinators

;;;###autoload
(cl-defun concur:all (promises-list &key mode)
  "Return a promise that resolves when all input promises resolve.
The returned promise resolves with a list of the resolved values, in the
same order as `PROMISES-LIST`. If any promise in the list rejects, this
promise immediately rejects with that same error.

  Arguments:
  - `PROMISES-LIST` (list): A list of promises or awaitable values.
  - `:MODE` (symbol, optional): The concurrency mode for the returned promise.
    If `nil`, the strongest mode from the input promises is used.

  Returns:
  - (concur-promise): A new promise that fulfills with a list of values."
  (unless (listp promises-list)
    (user-error "concur:all: PROMISES-LIST must be a list: %S" promises-list))
  (when (null promises-list)
    (concur--log :debug nil "concur:all: Empty promise list, resolving to '().")
    (cl-return-from concur:all (concur:resolved! '())))

  (let* ((total (length promises-list))
         (results (make-vector total nil))
         (result-mode (or mode (concur-determine-strongest-mode
                                promises-list :deferred)))
         (agg-promise (concur:make-promise :mode result-mode :name "concur:all-promise"))
         (resolved-count 0)
         (lock (concur:make-lock (format "concur-all-lock-%S" (gensym))
                                 :mode result-mode)))
    (concur--log :debug nil "concur:all: Waiting for %d promises in mode %S."
                 total result-mode)
    (--each-indexed promises-list
     (lambda (i p)
       (concur:then (concur:resolved! p) ; Normalize values to promises
        (lambda (res)
          (concur:with-mutex! lock
            ;; Only proceed if the aggregate promise is still pending.
            (when (concur:pending-p agg-promise)
              (aset results i res)
              (cl-incf resolved-count)
              (concur--log :debug (concur-promise-id agg-promise)
                           "Promise %d resolved. %d/%d resolved."
                           i resolved-count total)
              (when (= resolved-count total)
                (concur--log :info (concur-promise-id agg-promise)
                             "All %d promises resolved." total)
                (concur:resolve agg-promise (cl-coerce results 'list))))))
        (lambda (err)
          (concur:with-mutex! lock
            ;; If any promise rejects, the aggregate promise immediately rejects.
            (when (concur:pending-p agg-promise)
              (concur--log :warn (concur-promise-id agg-promise)
                           "Promise %d rejected, rejecting `concur:all` promise. Error: %S"
                           i err)
              (concur:reject agg-promise err)))))))
    agg-promise))

;;;###autoload
(cl-defun concur:race (promises-list &key mode)
  "Return a promise that settles with the outcome of the first promise to settle.
'Settling' means either resolving or rejecting. As soon as any promise in
`PROMISES-LIST` settles, the returned promise adopts its state.

  Arguments:
  - `PROMISES-LIST` (list): A list of promises or awaitable values.
  - `:MODE` (symbol, optional): The concurrency mode for the returned promise.
    If `nil`, the strongest mode from the input promises is used.

  Returns:
  - (concur-promise): A new promise that settles first."
  (unless (listp promises-list)
    (user-error "concur:race: PROMISES-LIST must be a list: %S" promises-list))
  (when (null promises-list)
    (user-error "concur:race: Cannot race an empty list of promises."))

  (let* ((result-mode (or mode (concur-determine-strongest-mode
                                promises-list :deferred)))
         (race-promise (concur:make-promise :mode result-mode :name "concur:race-promise")))
    (concur--log :debug nil "concur:race: Waiting for first of %d promises in mode %S."
                 (length promises-list) result-mode)
    (dolist (p promises-list)
      ;; Attach handlers to every promise. The first one to settle will win
      ;; by settling `race-promise`. Subsequent settlements are ignored
      ;; due to idempotency of `concur:resolve` and `concur:reject`.
      (concur:then (concur:resolved! p) ; Normalize values to promises
                   (lambda (res)
                     (concur--log :debug (concur-promise-id race-promise)
                                  "A promise won `concur:race` (resolved).")
                     (concur:resolve race-promise res))
                   (lambda (err)
                     (concur--log :debug (concur-promise-id race-promise)
                                  "A promise won `concur:race` (rejected).")
                     (concur:reject race-promise err))))
    race-promise))

;;;###autoload
(cl-defun concur:any (promises-list &key mode)
  "Return a promise that resolves with the first promise to fulfill (resolve).
If all promises in `PROMISES-LIST` reject, the returned promise rejects
with a standardized `concur-error` of type `:aggregate-error` containing a
list of all rejection reasons.

  Arguments:
  - `PROMISES-LIST` (list): A list of promises or awaitable values.
  - `:MODE` (symbol, optional): The concurrency mode for the returned promise.
    If `nil`, the strongest mode from the input promises is used.

  Returns:
  - (concur-promise): A new promise."
  (unless (listp promises-list)
    (user-error "concur:any: PROMISES-LIST must be a list: %S" promises-list))
  (when (null promises-list)
    (concur--log :warn nil "concur:any: Empty promise list, rejecting with no promises error.")
    (cl-return-from concur:any
      (concur:rejected! (concur:make-error :type :aggregate-error
                                           :message "No promises provided to `concur:any`."))))

  (let* ((total (length promises-list))
         (errors (make-vector total nil)) ; To collect all errors
         (result-mode (or mode (concur-determine-strongest-mode
                                promises-list :deferred)))
         (any-promise (concur:make-promise :mode result-mode :name "concur:any-promise"))
         (rejected-count 0)
         (lock (concur:make-lock (format "concur-any-lock-%S" (gensym))
                                 :mode result-mode)))
    (concur--log :debug nil "concur:any: Waiting for first success among %d promises in mode %S."
                 total result-mode)
    (--each-indexed promises-list
     (lambda (i p)
       (concur:then (concur:resolved! p) ; Normalize values to promises
        ;; on-resolved: If any promise fulfills, `any-promise` wins.
        (lambda (res)
          (concur:with-mutex! lock
            (when (concur:pending-p any-promise)
              (concur--log :info (concur-promise-id any-promise)
                           "A promise won `concur:any` (resolved).")
              (concur:resolve any-promise res))))
        ;; on-rejected: Collect errors and reject only if all fail.
        (lambda (err)
          (concur:with-mutex! lock
            (when (concur:pending-p any-promise)
              (aset errors i err)
              (cl-incf rejected-count)
              (concur--log :debug (concur-promise-id any-promise)
                           "Promise %d rejected. %d/%d rejected."
                           i rejected-count total)
              (when (= rejected-count total)
                (concur--log :warn (concur-promise-id any-promise)
                             "All %d promises rejected, rejecting `concur:any` promise." total)
                (concur:reject
                 any-promise
                 (concur:make-error
                  :type :aggregate-error
                  :message "All promises were rejected in `concur:any`."
                  :cause (cl-coerce errors 'list))))))))))
    any-promise))

;;;###autoload
(cl-defun concur:all-settled (promises-list &key mode)
  "Return a promise that resolves after all input promises have settled.
This promise *never* rejects. It always resolves with a list of status
objects, each describing the outcome of an input promise.

  Arguments:
  - `PROMISES-LIST` (list): A list of promises or awaitable values.
  - `:MODE` (symbol, optional): The concurrency mode for the returned promise.
    If `nil`, the strongest mode from the input promises is used.

  Returns:
  - (concur-promise): A promise that resolves to a list of status objects.
    Each status object is a plist like:
    `(:status 'fulfilled :value ...)` or `(:status 'rejected :reason ...)`."
  (unless (listp promises-list)
    (user-error "concur:all-settled: PROMISES-LIST must be a list: %S" promises-list))
  (when (null promises-list)
    (concur--log :debug nil "concur:all-settled: Empty promise list, resolving to '().")
    (cl-return-from concur:all-settled (concur:resolved! '())))

  (let* ((total (length promises-list))
         (outcomes (make-vector total nil)) ; To store final status objects
         (result-mode (or mode (concur-determine-strongest-mode
                                promises-list :deferred)))
         (agg-promise (concur:make-promise :mode result-mode :name "concur:all-settled-promise"))
         (settled-count 0)
         (lock (concur:make-lock (format "all-settled-lock-%S" (gensym))
                                 :mode result-mode)))
    (concur--log :debug nil "concur:all-settled: Waiting for %d promises to settle in mode %S."
                 total result-mode)
    (--each-indexed promises-list
     (lambda (i p)
       (let ((promise (concur:resolved! p))) ; Ensure it's a promise
         (concur:finally
          promise ; This is called regardless of resolve/reject
          (lambda ()
            (concur:with-mutex! lock
              (when (concur:pending-p agg-promise) ; Still aggregate pending?
                (aset outcomes i
                      (if (concur:rejected-p promise)
                          `(:status 'rejected
                                    :reason ,(concur:error-value promise))
                        `(:status 'fulfilled
                                  :value ,(concur:value promise))))
                (cl-incf settled-count)
                (concur--log :debug (concur-promise-id agg-promise)
                             "Promise %d settled. %d/%d settled."
                             i settled-count total)
                (when (= settled-count total)
                  (concur--log :info (concur-promise-id agg-promise)
                               "All %d promises settled." total)
                  (concur:resolve agg-promise
                                  (cl-coerce outcomes 'list))))))))))
    agg-promise))

;;;###autoload
(defun concur:map-series (items fn)
  "Process a list of `ITEMS` sequentially with an async function `FN`.
Each item is passed to `FN` only after the promise returned for the
previous item has resolved. This is useful for tasks that must be
run one after another, where order matters.

  Arguments:
  - `ITEMS` (list): The list of items to process.
  - `FN` (function): A function that takes one item and returns a promise.

  Returns:
  - (concur-promise): A promise that resolves with a list of the results."
  (unless (listp items)
    (user-error "concur:map-series: ITEMS must be a list: %S" items))
  (unless (functionp fn)
    (user-error "concur:map-series: FN must be a function: %S" fn))

  (concur--log :debug nil "concur:map-series: Mapping %d items sequentially."
               (length items))
  (let ((results-promise (concur:resolved! '() :name "map-series-collector")))
    (dolist (item items)
      (setq results-promise
            (concur:then results-promise
                         (lambda (collected-results)
                           (concur:then (funcall fn item) ; Call FN for current item
                                        (lambda (current-result)
                                          (cons current-result
                                                collected-results)) ; Prepend result
                                        (lambda (err) ; Propagate error
                                          (concur:rejected! err)))))))
    ;; The results are collected in reverse order; reverse them back at the end.
    (concur:then results-promise #'nreverse)))

;;;###autoload
(defun concur:map-parallel (items fn)
  "Process a list of `ITEMS` in parallel with an async function `FN`.
All calls to `FN` are initiated concurrently. This is much faster
than `map-series` for tasks that can run independently.

  Arguments:
  - `ITEMS` (list): The list of items to process.
  - `FN` (function): A function that takes one item and returns a promise.

  Returns:
  - (concur-promise): A promise that resolves with a list of the results."
  (unless (listp items)
    (user-error "concur:map-parallel: ITEMS must be a list: %S" items))
  (unless (functionp fn)
    (user-error "concur:map-parallel: FN must be a function: %S" fn))

  (concur--log :debug nil "concur:map-parallel: Mapping %d items in parallel."
               (length items))
  (concur:all (--map (funcall fn it) items)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Utilities

;;;###autoload
(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with VALUE after a delay of SECONDS.

  Arguments:
  - `SECONDS` (number): The delay duration in seconds. Must be non-negative.
  - `VALUE` (any, optional): The value to resolve the promise with.
    Defaults to `t`.

  Returns:
  - (concur-promise): A new promise that will resolve after the specified delay."
  (unless (and (numberp seconds) (>= seconds 0))
    (user-error "concur:delay: SECONDS must be a non-negative number: %S"
                seconds))
  (concur:with-executor
      (lambda (resolve _reject)
        (concur--log :debug nil "concur:delay: Delaying for %Ss." seconds)
        (run-at-time seconds nil
                     (lambda ()
                       (concur--log :debug nil "concur:delay: Delay finished.")
                       (funcall resolve (or value t)))))))

;;;###autoload
(defun concur:timeout (promise timeout-seconds)
  "Return a promise that rejects if the input PROMISE does not settle in time.
This creates a race between the input `PROMISE` and a timer. If the
input promise settles first, the new promise adopts its state. If the
timer finishes first, the new promise is rejected with a `concur:timeout-error`.

  Arguments:
  - `PROMISE` (concur-promise): The promise to apply a timeout to.
  - `TIMEOUT-SECONDS` (number): The timeout duration in seconds.
    Must be positive.

  Returns:
  - (concur-promise): A new promise that wraps the original with a timeout."
  (unless (concur-promise-p promise)
    (user-error "concur:timeout: PROMISE must be a promise: %S" promise))
  (unless (and (numberp timeout-seconds) (> timeout-seconds 0))
    (user-error "concur:timeout: TIMEOUT-SECONDS must be a positive number: %S"
                timeout-seconds))
  (concur--log :debug nil "concur:timeout: Setting %Ss timeout for promise %S."
               timeout-seconds (concur-promise-id promise))
  (concur:race
   (list promise
         (concur:rejected! ; A promise that rejects after the timeout
          (concur:make-error
           :type :timeout
           :message (format "Operation timed out after %Ss."
                            timeout-seconds)
           :cause (concur:delay timeout-seconds))))))

;;;###autoload
(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an async function `FN` up to `RETRIES` times on failure.
`FN` must be a function that takes no arguments and returns a promise.

  Arguments:
  - `FN` (function): The zero-argument async function to try.
  - `:RETRIES` (integer, optional): The maximum number of attempts.
    Default is 3. Must be at least 1.
  - `:DELAY` (number or function, optional): The delay in seconds between
    retries. If a function, it is called with `(attempt-number error)` and
    should return a number representing the delay. Defaults to 0.1s.
  - `:PRED` (function, optional): A predicate called with the error object.
    A retry is only attempted if the predicate returns non-nil.
    Default is `#'always` (always retry on any error).

  Returns:
  - (concur-promise): A promise that resolves with the first successful
    result from `FN`, or rejects with the last error if all retries fail."
  (unless (functionp fn)
    (user-error "concur:retry: FN must be a function: %S" fn))
  (unless (and (integerp retries) (>= retries 1))
    (user-error "concur:retry: RETRIES must be a positive integer: %S"
                retries))
  (unless (or (numberp delay) (functionp delay))
    (user-error "concur:retry: DELAY must be a number or a function: %S" delay))
  (unless (functionp pred)
    (user-error "concur:retry: PRED must be a function: %S" pred))

  (concur:with-executor (lambda (resolve reject)
    (let ((attempt 0))
      (cl-labels
          ((do-try ()
             (cl-incf attempt)
             (concur--log :debug nil "concur:retry: Attempt %d/%d for function %S."
                          attempt retries fn)
             (concur:then (funcall fn)
              ;; Success: resolve the master promise.
              #'resolve
              ;; Error: decide whether to retry or give up.
              (lambda (err)
                (if (and (< attempt retries) (funcall pred err))
                    (delay-and-retry err)
                  (concur--log :error nil "concur:retry: All attempts failed for %S. Last error: %S"
                               fn err)
                  (funcall reject err))))) ; Give up, reject master promise
           (delay-and-retry (err)
             (let ((delay-sec (if (functionp delay)
                                  (funcall delay attempt err)
                                delay)))
               (concur--log :debug nil "concur:retry: Delaying %Ss before next attempt."
                            delay-sec)
               (concur:then (concur:delay delay-sec) #'do-try))))
        ;; Start the first attempt.
        (do-try))))))

(provide 'concur-combinators)
;;; concur-combinators.el ends here