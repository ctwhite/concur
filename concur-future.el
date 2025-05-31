;;; concur-future.el --- Concurrency primitives for asynchronous tasks -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides primitives for working with "futures" in Emacs Lisp.
;; Futures represent the result of a computation that may not have
;; completed yet. They are a key concept in asynchronous programming,
;; allowing you to start a long-running task and retrieve its result
;; later without blocking the main thread of execution.
;;
;; Key Concepts:
;;
;; -   Future: A `concur-future` object represents a deferred computation.
;;     It holds a thunk (a zero-argument function) that will be evaluated
;;     when the future's value is needed. The future also holds a promise,
;;     which will eventually be resolved or rejected with the result
;;     or error from the computation.
;;
;; -   Lazy Evaluation: Futures are evaluated lazily. The computation
;;     is not performed until the future is "forced" (i.e., its value is
;;     needed). This allows for efficient chaining of asynchronous
;;     operations.
;;
;; -   Promises: Futures use promises (`concur-promise`) internally to
;;     manage the asynchronous result. The promise is resolved when the
;;     computation completes successfully, or rejected if an error occurs.
;;
;; Core Functionality:
;;
;; -   `concur:make-future`: Creates a new future from a thunk.
;; -   `concur:force`: Forces the evaluation of a future (if it
;;      hasn't already been evaluated) and returns the associated promise.
;; -   `concur:future-get`: Forces the future and gets the result, with
;;       optional timeout (blocking).
;; -   `concur:map-future` / `concur:then-future`: Applies a
;;       transformation function to the result of a future, creating a
;;       new future.
;; -   `concur:catch-future`: Attaches an error handler to a future,
;;       creating a new future that handles potential errors from the
;;       original future.
;; -   `concur:all-futures`: Runs multiple futures concurrently.
;; -   `concur:from-promise`: Wraps an existing promise in a future.
;;
;; Usage:
;;
;; Futures are useful for representing the results of asynchronous
;; operations, such as:
;;
;; -   Running a process in the background.
;; -   Performing a network request.
;; -   Executing a time-consuming computation.
;;
;; By using futures, you can start these operations without blocking
;; the main Emacs thread, and then retrieve the results later when
;; they are available.
;;
;; Example:
;;
;;  (defun my-async-computation (x)
;;    ;; This thunk should return a value or throw an error.
;;    ;; The future will wrap this into a promise.
;;    (if (> x 0)
;;        (* x 2)
;;      (error "x must be positive")))
;;
;;  (let ((my-future (concur:make-future (lambda () (my-async-computation 5)))))
;;    (message "Starting computation...")
;;    ;; Force the future and chain asynchronously
;;    (concur:then (concur:force my-future) ; Using concur:then from concur-promise
;;                 (lambda (result err)
;;                   (if err
;;                       (message "Computation failed with error: %S" err)
;;                     (message "Computation finished with result: %S" result)))))
;;
;; In this example, `my-async-computation` returns a value directly. The
;; `concur:make-future` function creates a future that wraps this computation.
;; When `concur:force` is called, the thunk runs, and its result
;; resolves the future's internal promise. `concur:then` (from `concur-promise.el`)
;; is then used to handle the successful result and potential error asynchronously.
;;
;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-primitives) ; For `once-do!`
(require 'concur-promise)    ; For `concur-promise` and related functions
(require 'ht)                ; For hash table operations
(require 'scribe nil t)      ; For logging (`log!`)

;; Ensure `log!` is available if scribe isn't fully loaded/configured elsewhere
(unless (fboundp 'log!)
  (defun log! (level format-string &rest args)
    "Placeholder logging function if scribe's log! is not available."
    (apply #'message (concat "CONCUR-FUTURE-LOG " (symbol-name level) ": " format-string) args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Internal Structs                                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct
    (concur-future
     (:constructor nil) ; Disable default constructor
     (:constructor concur-future-create ; Keep internal constructor name
      (&key promise thunk evaluated? context)))
  "A lazy future represents a deferred computation that
returns a promise when forced.

Fields:
`promise`    The cached promise, evaluated once the thunk is forced. Remains
             nil until evaluated.
`thunk`      A zero-argument function representing the computation to run lazily.
             This thunk should return a value or signal an error. The future
             will wrap its outcome into the internal promise.
`evaluated?` Non-nil if the thunk has already been evaluated, indicating the
             promise is cached.
`context`    Optional context (e.g., a hash table) to associate with the future.
             Useful for passing data to the thunk if the thunk accepts it."
  promise
  thunk
  evaluated?
  context)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                              Public API                                    ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:make-future (thunk &optional context)
  "Wrap a no-arg function THUNK into a `future`.

The returned future will call THUNK when forced. If THUNK returns a value,
the future's internal promise resolves with that value. If THUNK throws
an error, it is caught and causes the future's internal promise to reject.

Parameters:
  THUNK:  A zero-argument function to execute. This function should perform
          a computation and return its result, or signal an error.
  CONTEXT: Optional context (e.g., a hash table) to
           associate with the future.

Returns:
  A new `concur-future` object."
  (let ((promise (concur:make-promise))) ; Use new name from concur-promise
    (let ((future (concur-future-create
                   :thunk (lambda ()
                            (condition-case ex
                                (let ((result (funcall thunk)))
                                  (concur:resolve promise result)) ; Use new name
                              (error
                               (concur:reject promise ex)))) ; Use new name
                   :promise promise
                   :evaluated? nil
                   :context context)))
      (log! :debug "concur:make-future: Created future: %S with context: %S" future context)
      future)))

;;;###autoload
(defmacro concur:future-once! (future)
  "Evaluate FUTURE's internal thunk only once. Safe to call multiple times.

This macro ensures that the FUTURE's thunk is only evaluated once. The
evaluation is guarded by the `concur-future-evaluated?` slot, which is set
to `t` after the first execution.

This macro's primary purpose is to trigger the internal `thunk` which in turn
resolves or rejects the future's `promise` slot.

Parameters:
  FUTURE: A `concur-future` object.
"
  (declare (indent 1))
  `(once-do! (concur-future-evaluated? ,future)
     (:else
      (log! :debug "concur:future-once!: Future %S already evaluated." ,future))
     (log! :debug "concur:future-once!: Evaluating thunk for future: %S" ,future)
     (let ((thunk (concur-future-thunk ,future)))
       (if thunk
           (funcall thunk)
         (log! :warn "concur:future-once!: Missing thunk in future %S. Cannot evaluate." ,future)))))

;;;###autoload
(defun concur:force (future)
  "Force FUTURE's thunk to run if not already.
Returns the internal promise.

Returns nil if FUTURE is nil or not a valid `concur-future` object.

Parameters:
  FUTURE: A `concur-future` object.

Returns:
  The promise associated with the future, or nil on error."
  (log! :debug "concur:force: Forcing future: %S" future)
  (cond
   ((null future)
    (log! :warn "concur:force: FUTURE is nil. Nothing to evaluate." :trace)
    nil)
   ((not (concur-future-p future))
    (log! :error "concur:force: Invalid FUTURE object: %S" future :trace)
    (error "Invalid future object: %S" future))
   (t
    (concur:future-once! future) ; Use new macro name
    (let ((promise (concur-future-promise future)))
      (log! :debug "concur:force: Returning promise %S from future %S." promise future)
      promise))))

;;;###autoload
(defun concur:future-get (future &optional timeout throw-on-error)
  "Force the future and get its result, blocking until available or timeout.

This function forces the future's evaluation (if it hasn't happened yet)
and then retrieves the result from the underlying promise. It will block
the Emacs UI until the promise settles or the `timeout` is exceeded.

WARNING: This function is blocking. Use with extreme caution.

Parameters:
  FUTURE         -- A `concur-future` object.
  TIMEOUT        -- Optional timeout in seconds. If nil, wait indefinitely.
  THROW-ON-ERROR -- If non-nil, raise an Emacs error on rejection or timeout.

Returns:
  The result value of the resolved future. If rejected or cancelled and
  `THROW-ON-ERROR` is nil, returns `nil` and logs the error."
  (log! :info "concur:future-get: Getting result from future %S (timeout: %S, throw-on-error: %S)."
        future timeout throw-on-error)
  (let ((promise (concur:force future))) ; Use new name
    (unless promise
      (error "concur:future-get: Failed to force future %S to get promise." future))
    (concur:await promise timeout throw-on-error))) ; Use new name from concur-promise

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Future Chaining                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:map-future (future transform-fn &optional context)
  "Apply a transformation function to the result of a future.

Creates a new future that, when forced, evaluates `FUTURE`, then applies
`TRANSFORM-FN` to its result. The new future's promise resolves with the
transformed value or rejects if `TRANSFORM-FN` errors/returns a rejected promise.

Parameters:
  FUTURE:       A `concur-future` object.
  TRANSFORM-FN: A function `(lambda (result error))` that receives the outcome
                of the original future. If it returns a promise, it will be
                chained. If it returns a non-promise value, the returned promise
                is resolved with it.
  CONTEXT:      Optional context for the new future.

Returns:
  A new `concur-future` representing the transformed computation."
  (log! :debug "concur:map-future: Creating mapped future from %S with transform %S."
        future transform-fn)
  (let* ((new-promise (concur:make-promise)) ; Use new name
         (new-future (concur-future-create
                      :thunk (lambda ()
                               (let ((original-promise (concur:force future))) ; Use new name
                                 (unless original-promise
                                   (concur:reject ; Use new name
                                    new-promise (format "Failed to force original future %S" future)))
                                 ;; Assuming transform-fn is (lambda (value) ...) or (lambda (value error) ...)
                                 ;; concur:then handles both cases and promise assimilation
                                 (concur:then original-promise ; Use new name from concur-promise
                                              (lambda (value error)
                                                (if error
                                                    (concur:reject new-promise error) ; Propagate error
                                                  ;; If no error, call transform-fn with value
                                                  (condition-case ex
                                                      (let ((transformed (funcall transform-fn value)))
                                                        (if (concur-promise-p transformed)
                                                            (concur:then transformed
                                                                         (lambda (v) (concur:resolve new-promise v))
                                                                         (lambda (e) (concur:reject new-promise e)))
                                                          (concur:resolve new-promise transformed)))
                                                    (error (concur:reject new-promise ex))))))))
                      :promise new-promise
                      :evaluated? nil
                      :context context)))
    new-future))

;;;###autoload
(defun concur:then-future (future callback-fn &optional context)
  "Alias for `concur:map-future` when `callback-fn` primarily handles success.
`callback-fn` is `(lambda (result) ...)` or `(lambda (result error) ...)`."
  (concur:map-future future callback-fn context))

;;;###autoload
(defun concur:catch-future (future error-callback-fn &optional context)
  "Attach an error handler to a future.

Creates a new future. If original `FUTURE` resolves, result passes through.
If original `FUTURE` rejects, `ERROR-CALLBACK-FN` `(lambda (error))` is called,
and its result (or error) is used for the new future.

Parameters:
  FUTURE:            A `concur-future` object.
  ERROR-CALLBACK-FN: A function `(lambda (error))` that receives the
                       rejection reason. Its return value (or promise)
                       determines the new future's resolution.
  CONTEXT:           Optional context for the new future.

Returns:
  A new `concur-future` object."
  (log! :debug "concur:catch-future: Creating catch future from %S with handler %S."
        future error-callback-fn)
  (let* ((new-promise (concur:make-promise)) ; Use new name
         (new-future (concur-future-create
                      :thunk (lambda ()
                               (let ((original-promise (concur:force future))) ; Use new name
                                 (unless original-promise
                                   (concur:reject ; Use new name
                                    new-promise (format "Failed to force original future %S" future)))
                                 (concur:catch original-promise error-callback-fn))) ; Use new name from concur-promise
                      :promise new-promise
                      :evaluated? nil
                      :context context)))
    new-future))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Future Composition                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(cl-defun concur:all-futures (futures &key (max 4) (delay 0) (order 'ordered))
  "Run FUTURES (list of futures or thunks) with MAX concurrency.
Optional DELAY throttles task launching. ORDER can be 'ordered or 'unordered.

Returns a promise that resolves to a list of results (if 'ordered) or a hash table
(if 'unordered), containing results or errors, keyed by original index."
  (unless (member order '(ordered unordered))
    (error "concur:all-futures: Invalid value for :order. Must be 'ordered or 'unordered, but got %S." order))

  (let* ((total (length futures))
         (results (if (eq order 'ordered)
                      (make-vector total nil) 
                    (ht-create)))             
         (queue (cl-loop for i from 0 below total
                         for fut-or-thunk in futures
                         collect (list :index i
                                       :future (if (concur-future-p fut-or-thunk)
                                                   fut-or-thunk
                                                 (concur:make-future fut-or-thunk))))) ; Use new name
         (active-count 0)
         (completed-count 0)
         (main-promise (concur:make-promise)) ; Use new name
         (next-launch-time (float-time)))

    (cl-labels
        ((store-result (index value)
           (if (eq order 'ordered)
               (aset results index value)
             (ht-set! results index value)))

         (get-final-result ()
           (if (eq order 'ordered)
               (cl-coerce results 'list)
             results))

         (launch-next-future-cooperatively ()
           "Attempts to launch the next future from the queue, respecting concurrency and delay."
           (cond
            ((concur-promise-resolved? main-promise)
             (log! :debug "Main promise already settled, stopping launch attempts."))

            ((= completed-count total)
             (log! :info "All individual futures completed. Resolving main promise.")
             (concur:resolve main-promise (get-final-result))) ; Use new name

            ((and (not (null queue)) (< active-count max))
             (let* ((current-time (float-time))
                    (time-to-wait (- next-launch-time current-time)))
               (if (> time-to-wait 0)
                   (progn
                     (log! :debug "Throttling. Next launch in %.2f seconds." time-to-wait)
                     (run-at-time time-to-wait nil #'launch-next-future-cooperatively))
                 (pcase-let* ((`(:index ,i :future ,fut) (pop queue)))
                   (cl-incf active-count)
                   (log! :debug "Launching future at index %d. Active: %d/%d."
                         i active-count max)

                   (concur:then ; Use new name from concur-promise
                    (concur:force fut) ; Use new name
                    (lambda (res err) 
                      (log! :debug "Future at index %d settled. Res: %S, Err: %S." i res err)
                      (store-result i (if err err res)) 
                      (cl-incf completed-count)
                      (cl-decf active-count)
                      (launch-next-future-cooperatively)))

                   (when (> delay 0)
                     (setq next-launch-time (+ current-time delay)))
                   (launch-next-future-cooperatively)))))
            (t
             (log! :debug "No futures to launch right now. Waiting for completions."))))
      (launch-next-future-cooperatively)))
    (concur:from-promise main-promise))) ; Use new name

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Utility Functions                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:from-promise (promise)
  "Create a `concur-future` that is already evaluated and holds the given PROMISE.
This is useful for wrapping a promise into the future abstraction."
  (unless (concur-promise-p promise)
    (error "concur:from-promise: Input must be a concur-promise object, got %S" promise))
  (concur-future-create :promise promise :thunk nil :evaluated? t))

(provide 'concur-future)
;;; concur-future.el ends here