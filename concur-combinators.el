;;; concur-combinators.el --- Combinator functions for Concur Promises -*-
;;; lexical-binding: t; -*-

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

(require 'cl-lib)
(require 'dash)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Combinators

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
  (concur-promise) A new promise that fulfills with a list of values."
  (if (null promises-list)
      (concur:resolved! '())
    (let* ((total (length promises-list))
           (results (make-vector total nil))
           (result-mode (or mode (concur-determine-strongest-mode
                                  promises-list :deferred)))
           (agg-promise (concur:make-promise :mode result-mode))
           (resolved-count 0)
           (lock (concur:make-lock "all-lock" :mode result-mode)))
      (--each-indexed promises-list
       (lambda (i p)
         (concur:then (concur:resolved! p) ; Normalize values to promises
          (lambda (res)
            (concur:with-mutex! lock
              ;; Check pending-p, as it could have been rejected already.
              (when (concur:pending-p agg-promise)
                (aset results i res)
                (cl-incf resolved-count)
                (when (= resolved-count total)
                  (concur:resolve agg-promise (cl-coerce results 'list))))))
          (lambda (err)
            (concur:with-mutex! lock
              (when (concur:pending-p agg-promise)
                (concur:reject agg-promise err)))))))
      agg-promise)))

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
  (concur-promise) A new promise that settles first."
  (let* ((result-mode (or mode (concur-determine-strongest-mode
                                promises-list :deferred)))
         (race-promise (concur:make-promise :mode result-mode)))
    (dolist (p promises-list)
      ;; Attach handlers to every promise. The first one to settle will win.
      (concur:then (concur:resolved! p)
                   (lambda (res) (concur:resolve race-promise res))
                   (lambda (err) (concur:reject race-promise err))))
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
  (concur-promise) A new promise."
  (if (null promises-list)
      (concur:rejected! (concur:make-error :type :aggregate-error
                                           :message "No promises provided."))
    (let* ((total (length promises-list))
           (errors (make-vector total nil))
           (result-mode (or mode (concur-determine-strongest-mode
                                  promises-list :deferred)))
           (any-promise (concur:make-promise :mode result-mode))
           (rejected-count 0)
           (lock (concur:make-lock "any-lock" :mode result-mode)))
      (--each-indexed promises-list
       (lambda (i p)
         (concur:then (concur:resolved! p)
          ;; on-resolved: If any promise fulfills, we win.
          (lambda (res)
            (concur:with-mutex! lock
              (when (concur:pending-p any-promise)
                (concur:resolve any-promise res))))
          ;; on-rejected: Collect errors and reject only if all fail.
          (lambda (err)
            (concur:with-mutex! lock
              (when (concur:pending-p any-promise)
                (aset errors i err)
                (cl-incf rejected-count)
                (when (= rejected-count total)
                  (concur:reject
                   any-promise
                   (concur:make-error
                    :type :aggregate-error
                    :message "All promises were rejected."
                    :cause (cl-coerce errors 'list))))))))))
      any-promise)))

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
  (concur-promise): A promise that resolves to a list of status objects.
  Each status object is a plist like:
  `(:status 'fulfilled :value ...)` or `(:status 'rejected :reason ...)`."
  (if (null promises-list)
      (concur:resolved! '())
    (let* ((total (length promises-list))
           (outcomes (make-vector total nil))
           (result-mode (or mode (concur-determine-strongest-mode
                                  promises-list :deferred)))
           (agg-promise (concur:make-promise :mode result-mode))
           (settled-count 0)
           (lock (concur:make-lock "all-settled-lock" :mode result-mode)))
      (--each-indexed promises-list
       (lambda (i p)
         (let ((promise (concur:resolved! p)))
           (concur:finally
            promise
            (lambda ()
              (concur:with-mutex! lock
                (when (concur:pending-p agg-promise)
                  (aset outcomes i
                        (if (concur:rejected-p promise)
                            `(:status 'rejected
                                      :reason ,(concur:error-value promise))
                          `(:status 'fulfilled
                                    :value ,(concur:value promise))))
                  (cl-incf settled-count)
                  (when (= settled-count total)
                    (concur:resolve agg-promise
                                    (cl-coerce outcomes 'list))))))))))
      agg-promise)))

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
  (concur-promise): A promise that resolves with a list of the results."
  (let ((results-promise (concur:resolved! '())))
    (dolist (item items)
      (setq results-promise
            (concur:then results-promise
                         (lambda (collected-results)
                           (concur:then (funcall fn item)
                                        (lambda (current-result)
                                          (cons current-result
                                                collected-results)))))))
    ;; The results are collected in reverse; reverse them back at the end.
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
  (concur-promise): A promise that resolves with a list of the results."
  (concur:all (--map (funcall fn it) items)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Utilities

;;;###autoload
(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with VALUE after a delay of SECONDS.

Arguments:
- `SECONDS` (number): The delay duration in seconds.
- `VALUE` (any, optional): The value to resolve the promise with. Defaults to `t`.

Returns:
  (concur-promise): A new promise that will resolve after the specified delay."
  (concur:with-executor
      (lambda (resolve _reject)
        (run-at-time seconds nil
                     (lambda () (funcall resolve (or value t)))))))

;;;###autoload
(defun concur:timeout (promise timeout-seconds)
  "Return a promise that rejects if the input PROMISE does not settle in time.
This creates a race between the input `PROMISE` and a timer. If the
input promise settles first, the new promise adopts its state. If the
timer finishes first, the new promise is rejected with a `concur:timeout-error`.

Arguments:
- `PROMISE` (concur-promise): The promise to apply a timeout to.
- `TIMEOUT-SECONDS` (number): The timeout duration in seconds.

Returns:
  (concur-promise): A new promise that wraps the original with a timeout."
  (concur:race
   (list promise
         (concur:then (concur:delay timeout-seconds)
                      (lambda (_)
                        (concur:rejected!
                         (concur:make-error
                          :type :timeout
                          :message "Promise timed out")))))))

;;;###autoload
(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an async function `FN` up to `RETRIES` times on failure.
`FN` must be a function that takes no arguments and returns a promise.

Arguments:
- `FN` (function): The zero-argument async function to try.
- `:RETRIES` (integer, optional): The maximum number of attempts. Default is 3.
- `:DELAY` (number or function, optional): The delay in seconds between
  retries. If a function, it is called with `(attempt-number error)`.
- `:PRED` (function, optional): A predicate called with the error. A retry
  is only attempted if the predicate returns non-nil. Default is `#'always`.

Returns:
  (concur-promise): A promise that resolves with the first successful
  result from `FN`, or rejects with the last error if all retries fail."
  (concur:with-executor (lambda (resolve reject)
    (let ((attempt 0))
      (cl-labels
          ((do-try ()
             (cl-incf attempt)
             (concur:then (funcall fn)
              ;; Success: resolve the master promise.
              #'resolve
              ;; Error: decide whether to retry or give up.
              (lambda (err)
                (if (and (< attempt retries) (funcall pred err))
                    (delay-and-retry err)
                  (funcall reject err)))))
           (delay-and-retry (err)
             (let ((delay-sec (if (functionp delay)
                                  (funcall delay attempt err)
                                delay)))
               (concur:then (concur:delay delay-sec) #'do-try))))
        ;; Start the first attempt.
        (do-try))))))

(provide 'concur-combinators)
;;; concur-combinators.el ends here