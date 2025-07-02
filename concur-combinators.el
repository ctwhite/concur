;;; concur-combinators.el --- Combinator functions for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides high-level functions that operate on collections of
;; promises, allowing for complex asynchronous control flow. It includes
;; standard combinators like `concur:all` and `concur:race`, as well as
;; powerful utilities for processing collections like `concur:map-parallel`,
;; `concur:filter-series`, and `concur:reduce`.
;;
;; **Promise Mode Propagation:**
;; Combinator functions correctly determine and propagate the strongest
;; concurrency mode from their input promises to their resulting promise,
;; ensuring appropriate synchronization. Users can also explicitly provide
;; a `:mode` keyword to override this behavior.

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-list (arg fn-name)
  "Signal an error if ARG is not a list."
  (unless (listp arg)
    (error "%s: Argument must be a list, but got %S" fn-name arg)))

(defun concur--validate-function (arg fn-name)
  "Signal an error if ARG is not a function."
  (unless (functionp arg)
    (error "%s: Argument must be a function, but got %S" fn-name arg)))

(defun concur--determine-strongest-mode (promises-list default-mode)
  "Determine the 'strongest' concurrency mode from a list of promises.
The hierarchy is `:thread` (strongest) > `:async` > `:deferred`.

Arguments:
- `PROMISES-LIST` (list): A list of `concur-promise` objects and/or values.
- `DEFAULT-MODE` (symbol): The mode to return if no promises are found.

Returns:
- (symbol): The strongest concurrency mode found in the list."
  (let ((strongest default-mode))
    (dolist (p promises-list)
      (when (concur-promise-p p)
        (let ((mode (concur-promise-mode p)))
          (cond
           ((eq mode :thread) (setq strongest :thread) (cl-return))
           ((eq mode :async) (setq strongest :async))))))
    strongest))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Core Combinators

;;;###autoload
(cl-defun concur:all (promises-list &key mode)
  "Return a promise that resolves when all input promises resolve.
The returned promise resolves with a list of the resolved values, in the
same order as `PROMISES-LIST`. If any promise rejects, this promise
immediately rejects with that same error. Non-promise values in the
input list are treated as already-resolved promises.

Arguments:
- `PROMISES-LIST` (list): A list of promises and/or values.
- `:MODE` (symbol, optional): The concurrency mode for the returned promise.
  If nil, the strongest mode from the input promises is used.

Returns:
- `(concur-promise)`: A new promise that fulfills with a list of values."
  (concur--validate-list promises-list 'concur:all)
  (if (null promises-list)
      (concur:resolved! '())
    (let* ((total (length promises-list))
           (results (make-vector total nil))
           (result-mode (or mode (concur--determine-strongest-mode
                                  promises-list :deferred)))
           (agg-promise (concur:make-promise :mode result-mode :name "concur:all"))
           (resolved-count 0)
           (lock (concur:make-lock "concur-all-lock" :mode result-mode)))
      (cl-loop for p in promises-list for i from 0 do
        (concur:then (concur:resolved! p) ; Normalize values to promises.
         (lambda (res)
           (concur:with-mutex! lock
             (when (concur:pending-p agg-promise)
               (aset results i res)
               (cl-incf resolved-count)
               (when (= resolved-count total)
                 (concur:resolve agg-promise (cl-coerce results 'list))))))
         (lambda (err)
           (concur:with-mutex! lock
             (when (concur:pending-p agg-promise)
               (concur:reject agg-promise err))))))
      agg-promise)))

;;;###autoload
(cl-defun concur:all-settled (promises-list &key mode)
  "Return a promise that resolves after all input promises have settled.
This promise *never* rejects. It always resolves with a list of status
plists, each describing the outcome of an input promise.

Arguments:
- `PROMISES-LIST` (list): A list of promises and/or values.
- `:MODE` (symbol, optional): The concurrency mode for the returned promise.

Returns:
- `(concur-promise)`: A promise that resolves to a list of status plists.
  Each status object is like `(:status \'fulfilled :value ...)` or
  `(:status \'rejected :reason ...)`.

Example:
  (concur:all-settled (list (concur:resolved! 1) (concur:rejected! \"err\")))
  ;; Resolves to: '((:status fulfilled :value 1) (:status rejected ...))"
  (concur--validate-list promises-list 'concur:all-settled)
  (if (null promises-list)
      (concur:resolved! '())
    (let* ((total (length promises-list))
           (outcomes (make-vector total nil))
           (result-mode (or mode (concur--determine-strongest-mode
                                  promises-list :deferred)))
           (agg-promise (concur:make-promise :mode result-mode
                                             :name "concur:all-settled"))
           (settled-count 0)
           (lock (concur:make-lock "all-settled-lock" :mode result-mode)))
      (cl-loop for p in promises-list for i from 0 do
        (let ((promise (concur:resolved! p)))
          (concur:finally
           promise
           (lambda ()
             (concur:with-mutex! lock
               (when (concur:pending-p agg-promise)
                 (aset outcomes i (if (concur:rejected-p promise)
                                      `(:status 'rejected
                                        :reason ,(concur:error-value promise))
                                    `(:status 'fulfilled
                                      :value ,(concur:value promise))))
                 (cl-incf settled-count)
                 (when (= settled-count total)
                   (concur:resolve agg-promise (cl-coerce outcomes 'list)))))))))
      agg-promise)))

;;;###autoload
(cl-defun concur:race (promises-list &key mode)
  "Return a promise that settles with the outcome of the first promise to settle.
\'Settling\' means either resolving or rejecting. As soon as any promise in
`PROMISES-LIST` settles, the returned promise adopts that outcome.

Arguments:
- `PROMISES-LIST` (list): A list of promises and/or values.
- `:MODE` (symbol, optional): The concurrency mode for the returned promise.

Returns:
- `(concur-promise)`: A new promise that settles with the first outcome."
  (concur--validate-list promises-list 'concur:race)
  (when (null promises-list)
    (error "concur:race cannot race an empty list of promises"))
  (let* ((result-mode (or mode (concur--determine-strongest-mode
                                promises-list :deferred)))
         (race-promise (concur:make-promise :mode result-mode :name "concur:race")))
    (dolist (p promises-list)
      (concur:then (concur:resolved! p)
                   (lambda (res) (concur:resolve race-promise res))
                   (lambda (err) (concur:reject race-promise err))))
    race-promise))

;;;###autoload
(cl-defun concur:any (promises-list &key mode)
  "Return a promise that resolves with the value of the first promise to fulfill.
If all promises in `PROMISES-LIST` reject, the returned promise rejects
with an `:aggregate-error` containing a list of all rejection reasons.

Arguments:
- `PROMISES-LIST` (list): A list of promises and/or values.
- `:MODE` (symbol, optional): The concurrency mode for the returned promise.

Returns:
- `(concur-promise)`: A new promise."
  (concur--validate-list promises-list 'concur:any)
  (if (null promises-list)
      (concur:rejected!
       (concur:make-error :type :aggregate-error
                          :message "No promises provided to `concur:any`."))
    (let* ((total (length promises-list))
           (errors (make-vector total nil))
           (result-mode (or mode (concur--determine-strongest-mode
                                  promises-list :deferred)))
           (any-promise (concur:make-promise :mode result-mode :name "concur:any"))
           (rejected-count 0)
           (lock (concur:make-lock "concur-any-lock" :mode result-mode)))
      (cl-loop for p in promises-list for i from 0 do
        (concur:then (concur:resolved! p)
         (lambda (res)
           (concur:with-mutex! lock
             (when (concur:pending-p any-promise)
               (concur:resolve any-promise res))))
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
                   :message "All promises were rejected in `concur:any`."
                   :cause (cl-coerce errors 'list)))))))))
      any-promise)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Collection Processing

;;;###autoload
(defun concur:props (alist)
  "Like `concur:all`, but for an alist of promises.
Resolves all promises in the `alist` values and returns a promise that
resolves to a new alist with the same keys and the resolved values.

Arguments:
- `ALIST` (alist): An alist of `(key . promise-or-value)` pairs.

Returns:
- `(concur-promise)`: A promise that resolves with an alist of results."
  (let* ((keys (cl-mapcar #'car alist))
         (promises (cl-mapcar #'cdr alist)))
    (concur:then (concur:all promises)
                 (lambda (values) (cl-mapcar #'cons keys values)))))

;;;###autoload
(defun concur:reduce (items reducer initial-value)
  "Asynchronously reduce `ITEMS` to a single value using `REDUCER`.
Applies the async `REDUCER` function against an accumulator and each
item in `ITEMS` sequentially to reduce it to a single value.

Arguments:
- `ITEMS` (list): The list of items to reduce.
- `REDUCER` (function): A function `(lambda (accumulator item))` that
  returns a promise for the next accumulated value.
- `INITIAL-VALUE` (any): The initial value of the accumulator.

Returns:
- `(concur-promise)`: A promise that resolves with the final accumulated value."
  (concur--validate-list items 'concur:reduce)
  (concur--validate-function reducer 'concur:reduce)
  (cl-labels ((reduce-loop (items-left accumulator)
              (if (null items-left)
                  (concur:resolved! accumulator)
                (concur:then (funcall reducer accumulator (car items-left))
                              (lambda (new-acc)
                                (reduce-loop (cdr items-left) new-acc))))))
    (reduce-loop items initial-value)))

;;;###autoload
(defun concur:map-series (items fn)
  "Process `ITEMS` sequentially with an async function `FN`.
Each item is passed to `FN` only after the promise from the previous
item has resolved. This is for ordered, dependent tasks.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): A function `(lambda (item) ...)` that returns a promise.

Returns:
- `(concur-promise)`: A promise that resolves with a list of the results."
  (concur--validate-list items 'concur:map-series)
  (concur--validate-function fn 'concur:map-series)
  (concur:then
   (concur:reduce items
                  (lambda (acc item)
                    (concur:then (funcall fn item)
                                 (lambda (result) (cons result acc))))
                  '())
   #'nreverse))

;;;###autoload
(defun concur:map-parallel (items fn)
  "Process `ITEMS` in parallel with an async function `FN`.
All calls to `FN` are initiated concurrently. Use this for independent tasks.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): A function `(lambda (item) ...)` that returns a promise.

Returns:
- `(concur-promise)`: A promise that resolves with a list of the results."
  (concur--validate-list items 'concur:map-parallel)
  (concur--validate-function fn 'concur:map-parallel)
  (concur:all (cl-mapcar fn items)))

;;;###autoload
(defun concur:filter-series (items predicate)
  "Filter `ITEMS` sequentially with an async `PREDICATE`.
Each item is tested only after the promise from the previous item's
test has resolved.

Arguments:
- `ITEMS` (list): The list of items to filter.
- `PREDICATE` (function): An async function `(lambda (item))` that returns
  a promise for a boolean value.

Returns:
- `(concur-promise)`: A promise that resolves with the list of filtered items."
  (concur--validate-list items 'concur:filter-series)
  (concur--validate-function predicate 'concur:filter-series)
  (concur:then
   (concur:reduce items
                  (lambda (acc item)
                    (concur:then (funcall predicate item)
                                 (lambda (should-keep)
                                   (if should-keep (cons item acc) acc))))
                  '())
   #'nreverse))

;;;###autoload
(defun concur:filter-parallel (items predicate)
  "Filter `ITEMS` in parallel with an async `PREDICATE`.
All calls to `PREDICATE` are initiated concurrently.

Arguments:
- `ITEMS` (list): The list of items to filter.
- `PREDICATE` (function): An async function `(lambda (item))` that returns
  a promise for a boolean value.

Returns:
- `(concur-promise)`: A promise that resolves with the list of filtered items."
  (concur--validate-list items 'concur:filter-parallel)
  (concur--validate-function predicate 'concur:filter-parallel)
  (let* ((pred-promises (cl-mapcar predicate items))
         (pairs (cl-mapcar #'cons items pred-promises)))
    (concur:then
     (concur:all (cl-mapcar #'cdr pairs))
     (lambda (results)
       (let (filtered-items)
         (cl-loop for (item . _) in pairs
                  for should-keep in results
                  if should-keep do (push item filtered-items))
         (nreverse filtered-items))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Utilities

;;;###autoload
(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with `VALUE` after `SECONDS`.

Arguments:
- `SECONDS` (number): The delay duration. Must be non-negative.
- `VALUE` (any, optional): The value to resolve with. Defaults to `t`.

Returns:
- `(concur-promise)`: A new promise that resolves after the delay."
  (unless (and (numberp seconds) (>= seconds 0))
    (error "concur:delay: SECONDS must be a non-negative number: %S" seconds))
  (concur:with-executor
      (lambda (resolve _reject)
        (run-at-time seconds nil (lambda () (funcall resolve (or value t)))))))

;;;###autoload
(defun concur:timeout (promise timeout-seconds)
  "Return a promise that rejects if `PROMISE` does not settle in time.
This creates a race between `PROMISE` and a timer. If `PROMISE` settles
first, the new promise adopts its state. If the timer finishes first,
the new promise rejects with a `concur:timeout-error`.

Arguments:
- `PROMISE` (concur-promise): The promise to apply a timeout to.
- `TIMEOUT-SECONDS` (number): The timeout duration. Must be positive.

Returns:
- `(concur-promise)`: A new promise wrapping the original with a timeout."
  (unless (concur-promise-p promise)
    (error "concur:timeout: PROMISE must be a promise: %S" promise))
  (unless (and (numberp timeout-seconds) (> timeout-seconds 0))
    (error "concur:timeout: TIMEOUT-SECONDS must be a positive number: %S"
           timeout-seconds))
  (concur:race
   (list promise
         (concur:then (concur:delay timeout-seconds)
                      (lambda (_)
                        (concur:rejected!
                         (concur:make-error
                          :type :timeout
                          :message (format "Operation timed out after %Ss."
                                           timeout-seconds))))))))

;;;###autoload
(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an async function `FN` up to `RETRIES` times on failure.
`FN` must be a function that takes no arguments and returns a promise.

Arguments:
- `FN` (function): The zero-argument async function to try.
- `:RETRIES` (integer): Max attempts. Default is 3. Must be >= 1.
- `:DELAY` (number or function): Seconds between retries. If a function, it is
  called with `(attempt-number error)` and should return a number of
  seconds (e.g., for exponential backoff). Default is 0.1s.
- `:PRED` (function): A predicate `(lambda (error) ...)` called on failure.
  A retry is only attempted if it returns non-nil.

Returns:
- `(concur-promise)`: A promise that resolves with the first successful
  result, or rejects with the last error if all retries fail."
  (concur--validate-function fn 'concur:retry)
  (unless (and (integerp retries) (>= retries 1))
    (error "concur:retry: RETRIES must be a positive integer: %S" retries))
  (unless (or (numberp delay) (functionp delay))
    (error "concur:retry: DELAY must be a number or function: %S" delay))
  (concur--validate-function pred 'concur:retry)

  (concur:with-executor (lambda (resolve-fn reject-fn) 
    (let ((attempt 0))
      (cl-labels
          ((do-try ()
             (cl-incf attempt)
             (concur:then
              (funcall fn)
              (lambda (res) (funcall resolve-fn res)) ; Call local `resolve-fn` explicitly
              (lambda (err) ; On error, decide whether to retry.
                (if (and (< attempt retries) (funcall pred err))
                    (delay-and-retry err)
                  (funcall reject-fn err))))) ; Call local `reject-fn` explicitly
           (delay-and-retry (err)
             (let ((delay-sec (if (functionp delay)
                                  (funcall delay attempt err)
                                delay)))
               (concur:then (concur:delay delay-sec) #'do-try))))
        (do-try))))))

(provide 'concur-combinators)
;;; concur-combinators.el ends here