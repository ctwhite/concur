;;; concur-async.el --- Cooperative async primitives for Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides high-level asynchronous programming primitives for Emacs,
;; building upon the `concur` library. It offers a simplified interface for
;; managing concurrent operations, integrating with Emacs's event loop and
;; providing features like cooperative multitasking, thread management,
;; and error handling.
;;
;; Key Features:
;;
;; -  `concur:async!`: A versatile function to run functions asynchronously
;;      with various execution modes (deferred, delayed, background process,
;;      native thread).
;; -  `concur:await!`: A macro to synchronously-looking await the result of
;;      an asynchronous operation (future or promise), with optional timeout.
;; -  Thread management: Spawns and manages native threads for CPU-bound
;;      asynchronous operations.
;; -  Error handling: Provides robust error propagation and handling for
;;      asynchronous tasks.
;; -  Tracing: Optional logging of asynchronous stack traces for debugging.
;; -  Hooks: Extensible lifecycle hooks for asynchronous operations
;;      (`concur-async-hooks`, `concur-await-hooks`).
;; -  `concur:sequence!`: Run async operations in sequence.
;; -  `concur:parallel!`: Run async operations in parallel.
;; -  `concur:race!`: Race multiple async operations.
;; -  `concur:timeout!`: Apply a timeout to an async operation.
;;
;; Dependencies:
;;
;; -  `async`: For managing asynchronous processes.
;; -  `cl-lib`: Common Lisp extensions for Emacs Lisp.
;; -  `concur-promise`: Promise implementation for `concur`.
;; -  `concur-future`: Future implementation for `concur`.
;; -  `concur-primitives`: Core primitives of the `concur` library.
;; -  `scribe`: Logging utility.
;;
;; Usage:
;;
;; This file is typically used as part of the `concur` library. Users
;; can use `concur:async!` to initiate asynchronous operations and
;; `concur:await!` to wait for their results. The library provides
;; mechanisms to define how the asynchronous operations are executed
;; (e.g., in a separate thread, in a background process, or deferred
;; in the Emacs event loop).
;;
;; Examples:
;;
;; 1. Basic `concur:async!`:
;;    (concur:async!
;;        (lambda ()
;;          (message "Async task started...")
;;          (sleep-for 0.5) ; Simulate a long-running operation
;;          (message "Async task finished!"))
;;      'deferred "my-deferred-task")
;;
;; 2. Using `concur:await!`:
;;    (let ((result (concur:await!
;;                     (concur:async!
;;                         (lambda ()
;;                           (sleep-for 0.1)
;;                           (+ 1 2))
;;                       'deferred)
;;                   :timeout 5)))
;;      (message "Result: %s" result))
;;    ;; => Prints "Result: 3"
;;
;; 3. `concur:sequence!` example:
;;    (concur:await!
;;     (concur:sequence!
;;      '(1 2 3)
;;      (lambda (num)
;;        (message "Processing %d sequentially..." num)
;;        (concur:async! (lambda () (sleep-for 0.1) (* num 10)) 'deferred))))
;;    ;; => Processes 1, then 2, then 3, with 0.1s delay between each.
;;    ;;    Resolves with '(10 20 30) after ~0.3 seconds total.
;;
;; 4. `concur:parallel!` example:
;;    (concur:await!
;;     (concur:parallel!
;;      '(1 2 3)
;;      (lambda (num)
;;        (message "Processing %d in parallel..." num)
;;        (concur:async! (lambda () (sleep-for (* num 0.1)) (* num 10)) 'deferred))))
;;    ;; => Initiates all tasks at once.
;;    ;;    Resolves with '(10 20 30) after ~0.3 seconds (due to longest delay).
;;
;; 5. `concur:race!` example:
;;    (concur:await!
;;      (concur:race!
;;        (concur:async! (lambda () (sleep-for 0.5) "Slow Winner") 'deferred)
;;        (concur:async! (lambda () (sleep-for 0.1) "Fast Winner") 'deferred)))
;;    ;; => Resolves with "Fast Winner" after 0.1 seconds.
;;
;; 6. `concur:timeout!` example:
;;    (condition-case err
;;        (concur:await!
;;          (concur:timeout!
;;            (concur:async! (lambda () (sleep-for 2) "Too Slow") 'deferred)
;;            0.5))
;;      (concur-timeout (message "Operation timed out: %S" err)))
;;    ;; => Prints "Operation timed out: (concur-timeout \"Promise timed out\")" after 0.5 seconds.
;;
;;; Code:

(require 'async)
(require 'cl-lib)
(require 'concur-cancel)
(require 'concur-future)
(require 'concur-primitives)
(require 'concur-promise)
(require 'ht)
(require 'scribe nil t) ; Optional scribe

;; Ensure `log!` is available if scribe isn't fully loaded/configured elsewhere
(unless (fboundp 'log!)
  (defun log! (level format-string &rest args)
    "Placeholder logging function if scribe's log! is not available."
    (apply #'message (concat "CONCUR-ASYNC-LOG " (symbol-name level) ": " format-string) args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Customization                                  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom concur-async-enable-tracing t
  "Whether to record and log async stack traces for `concur:async!` tasks."
  :type 'boolean
  :group 'concur)

(defcustom concur-async-await-poll-interval 0.01
  "Polling interval in seconds used by `concur:await!` when blocking.
A small value (e.g. 0.005 = 5ms) gives more responsiveness, but may use more CPU."
  :type 'number
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Hooks                                      ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar concur-async-hooks nil
  "Hook run during `concur:async!`.

Each function receives (EVENT LABEL FUTURE &optional ERR), where EVENT is one of:
  :started     — before task is scheduled
  :succeeded   — when resolved successfully
  :failed      — if an error is caught during async execution (ERR is error object)
  :cancelled   — if the task is cancelled before completion")

(defvar concur-await-hooks nil
  "Hook run for await lifecycle events.

Each hook function receives:
  (EVENT LABEL TASK &optional ERR)

Where:
  - EVENT is one of :started, :yield, :timeout, :succeeded, :failed
  - LABEL is a string identifier for this await instance
  - TASK is the original awaitable (usually a concur-future or concur-promise)
  - ERR is only passed for error-related events such as :timeout or :failed.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                            Internal State                                  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar concur-async--active-threads (ht-create)
  "Hash table tracking active threads keyed by thread object.")

(defvar-local concur-async--stack nil
  "Dynamic stack of async task labels used for instrumentation and tracing.
This variable is buffer-local to prevent interference between different
Emacs contexts, but its primary use is for tracing within a single async flow.")

;; Define a custom error type for async operations
(define-error 'concur-async-error "Concurrency async operation error.")
(define-error 'concur-timeout "Concurrency timeout error.") ; Used by concur:await! and concur:timeout!

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Internal Helpers                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun concur-async--error? (value)
  "Return non-nil if VALUE is an `error` object."
  (and (consp value)
       (eq (car value) 'error)
       (symbolp (cadr value))))

(defun concur-async--push-stack-frame (label)
  "Push LABEL onto the async task stack."
  (push label concur-async--stack))

(defun concur-async--pop-stack-frame ()
  "Pop a frame from the async task stack."
  (pop concur-async--stack))

(defun concur-async--label (fn)
  "Generate a human-readable label for an async task from its function FN."
  (let ((s (prin1-to-string fn)))
    (if (> (length s) 40)
        (concat (substring s 0 37) "...")
      s)))

(defun concur-async--format-async-trace ()
  "Return a formatted trace of the current async stack."
  (mapconcat (lambda (frame)
               (format "↳ %s" frame))
             (reverse concur-async--stack)
             "\n"))

(defun concur-async--log-trace (label)
  "Log the current async stack trace for LABEL."
  (log! :trace "[%s] Async trace:\n%s" label (concur-async--format-async-trace)))

(defun concur-async--maybe-log-trace (label)
  "Log the async stack trace for LABEL if tracing is enabled."
  (when concur-async-enable-tracing
    (concur-async--log-trace label)))

(defun concur-async--run-hooks (event label future &optional err)
  "Run `concur-async-hooks` for EVENT, LABEL, and FUTURE.
ERR is included for :failed events."
  (log! :debug "[%s] Running async hooks: %s" label event)
  (run-hook-with-args 'concur-async-hooks event label future err))

(defun concur-await--run-hooks (event label task &optional err)
  "Run `concur-await-hooks` for EVENT, LABEL, and TASK (a future or promise).
ERR is only passed for error-related events like :timeout or :failed."
  (log! :debug "[%s] Running await hooks: %s" label event)
  (run-hook-with-args 'concur-await-hooks event label task err))

(defun concur-async--thread-run-future (future label cancel-token)
  "Run FUTURE in a background thread.
Returns the created thread object or nil if not started."
  (unless (concur-future-p future)
    (log! :error "concur-async--thread-run-future: Invalid future object: %S" future)
    (cl-return-from concur-async--thread-run-future nil))

  (log! :info "[%s] Spawning thread for future %S" label future)
  (if (and cancel-token (not (concur:cancel-token-active? cancel-token)))
      (progn
        (log! :warn "[%s] Not started: token %S already canceled"
               label (concur--cancel-token-get-name cancel-token))
        (concur-async--run-hooks :cancelled label future)
        nil)
    (let* ((thread
            (make-thread
             (lambda ()
               (let (result error)
                 (unwind-protect
                     (progn
                       (concur-async--push-stack-frame label)
                       (log! :debug "[%s] Thread execution started." label)
                       (condition-case e
                           (setq result (concur:future-get future)) 
                         (error
                          (setq error e))))
                   (run-at-time
                    0 nil
                    (lambda ()
                      (ht-remove! concur-async--active-threads thread)
                      (concur-async--pop-stack-frame)
                      (if error
                          (progn
                            (log! :error "[%s] Thread failed: %S" label error)
                            (concur-async--run-hooks :failed label future error))
                        (progn
                          (log! :info "[%s] Thread succeeded." label)
                          (concur-async--run-hooks :succeeded label future result))))))))
           entry)
      (setq entry `(:thread ,thread :future ,future :label ,label :cancel-token ,cancel-token))
      (ht-set! concur-async--active-threads thread entry)
      (when cancel-token
        (concur:cancel-token-on-cancel
         cancel-token
         (lambda ()
           (when (ht-contains? concur-async--active-threads thread)
             (ht-remove! concur-async--active-threads thread)
             (log! :warn "[%s] Cancelled by token %S. Killing thread."
                    label (concur--cancel-token-get-name cancel-token))
             (kill-thread thread)
             (concur-async--run-hooks :cancelled label future)))))
      (log! :info "[%s] Thread started." label)
      thread)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Public API                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:async! (fn &optional mode name cancel-token)
  "Run FN asynchronously according to MODE and return a `concur-promise`.

FN should be a zero-arg function (thunk) to execute. The return value of FN
will be the result of the promise, or an error if FN throws.

MODE determines how the function is scheduled:
- nil or 'deferred or t: schedule immediately using `run-at-time 0`.
- number: delay execution by that many seconds using `run-at-time`.
- 'async: run in a background Emacs process via `async-start`.
- 'thread: spawn a native thread via `make-thread`.

Optional arguments:
  NAME         Human-readable name for the async operation.
  CANCEL-TOKEN A cancel token object to interrupt execution.

Returns:
  A `concur-promise` that will resolve with the result of FN, or reject
  with an error if FN fails or the operation is cancelled."
  (log! :info "concur:async!: Preparing operation: %S (mode: %S, name: %S)." fn mode name)
  (let* ((label (or name (concur-async--label fn)))
         (future (concur:make-future fn)) 
         (promise (concur-future-promise future))
         (concur-async--stack (cons label concur-async--stack)))

    (concur-async--run-hooks :started label future)
    (concur-async--maybe-log-trace label)

    (unwind-protect
        (pcase mode
          ((or 'deferred 't (pred null))
           (log! :debug "concur:async!: Scheduling deferred operation for %S." label)
           (run-at-time 0 nil
                        (lambda ()
                          (concur-async--pop-stack-frame)
                          (condition-case err
                              (let* ((result-promise (concur:force future))) 
                                (concur:on-resolve 
                                 result-promise
                                 :on-resolved (lambda (res)
                                                (concur-async--run-hooks :succeeded label future)
                                                (concur:resolve promise res)) 
                                 :on-rejected (lambda (err-cb)
                                                (concur-async--run-hooks :failed label future err-cb)
                                                (concur:reject promise err-cb)))) 
                            (error
                             (log! :error "concur:async!: Deferred op for %S failed: %S." label err :trace)
                             (concur-async--run-hooks :failed label future err)
                             (concur:reject promise err)))))) 

          ((pred numberp)
           (log! :debug "concur:async!: Scheduling delayed op (%ss) for %S." mode label)
           (run-at-time mode nil
                        (lambda ()
                          (concur-async--pop-stack-frame)
                          (condition-case err
                              (let* ((result-promise (concur:force future))) 
                                (concur:on-resolve 
                                 result-promise
                                 :on-resolved (lambda (res)
                                                (concur-async--run-hooks :succeeded label future)
                                                (concur:resolve promise res)) ; Use new name
                                 :on-rejected (lambda (err-cb)
                                                (concur-async--run-hooks :failed label future err-cb)
                                                (concur:reject promise err-cb)))) ; Use new name
                            (error
                             (log! :error "concur:async!: Delayed op for %S failed: %S." label err :trace)
                             (concur-async--run-hooks :failed label future err)
                             (concur:reject promise err)))))) 

          ('async
           (log! :debug "concur:async!: Scheduling async process for %S." label)
           (async-start
            `(lambda ()
               (require 'scribe)      ; Ensure dependencies in async process
               (require 'concur-future)
               (require 'concur-promise)
               (require 'concur-primitives) 
               (concur-async--push-stack-frame ,label)
               (unwind-protect
                   (condition-case err
                       (progn
                         (log! :debug "[%s] Async process started." ,label)
                         (concur:force ,future)) ; Use new name
                     (error
                      (log! :error "[%s] Async process failed: %S." ,label err :trace)
                      err))
                 (concur-async--pop-stack-frame)))
            (lambda (result-promise-or-error)
              (concur-async--pop-stack-frame)
              (if (concur-promise-p result-promise-or-error) ; Check if it's a promise
                  (concur:on-resolve ; Use new name
                   result-promise-or-error
                   :on-resolved (lambda (res)
                                  (concur-async--run-hooks :succeeded label future)
                                  (concur:resolve promise res)) 
                   :on-rejected (lambda (err-cb)
                                  (concur-async--run-hooks :failed label future err-cb)
                                  (concur:reject promise err-cb))) 
                (progn ; Handle direct error from async-start's lambda
                  (log! :error "concur:async!: Async process for %S returned direct error: %S." label result-promise-or-error :trace)
                  (concur-async--run-hooks :failed label future result-promise-or-error)
                  (concur:reject promise result-promise-or-error)))))) 

          ('thread
           (log! :debug "concur:async!: Scheduling thread-backed op for %S." label)
           (concur-async--thread-run-future future label cancel-token))

          (_
           (let ((err (format "Unknown async run mode: %S" mode)))
             (log! :error "concur:async!: %S" err :trace)
             (concur-async--run-hooks :failed label future err)
             (concur:reject promise err)))) ; Use new name
      (concur-async--pop-stack-frame))
    promise))

;;;###autoload
(defmacro concur:await! (form &rest args)
  "Await the result of FORM (a `concur-future` or `concur-promise`).
Blocks until resolved or TIMEOUT (seconds).
ARGS: :timeout (number).
Runs `concur-await-hooks` for lifecycle events."
  (let ((task-expr (gensym "task-expr"))
        (awaitable-promise (gensym "awaitable-promise"))
        (timeout (gensym "timeout"))
        (label (gensym "label"))
        (result (gensym "result"))
        (error-val (gensym "error-val")))
    `(let* ((,task-expr ,form)
            (,timeout (plist-get (list ,@args) :timeout))
            (,label
             (format "await[%s]"
                     (or (and (symbolp ',form) (symbol-name ',form))
                         (let ((s (prin1-to-string ',form)))
                           (if (> (length s) 40)
                               (concat (substring s 0 37) "...")
                             s)))))
            (,awaitable-promise
             (cond
              ((concur-future-p ,task-expr)
               (log! :trace "[%s] Normalizing future %S -> promise." ,label ,task-expr)
               (concur:force ,task-expr)) ; Use new name
              ((concur-promise-p ,task-expr)
               ,task-expr)
              (t (error "[%s] Invalid awaitable: %S. Must be a concur-future or concur-promise." ,label ,task-expr)))))

       (concur-async--push-stack-frame ,label)
       (concur-await--run-hooks :started ,label ,task-expr)

       (log! :info "[%s] Awaiting %S%s"
             ,label ,task-expr (if ,timeout (format " (timeout: %.2fs)" ,timeout) ""))

       (unwind-protect
           (progn
             (log! :debug "[%s] Awaiting via polling (interval: %.2fs)..." ,label concur-async-await-poll-interval)
             (let ((start-time (float-time)))
               (while (and (not (concur-promise-resolved? ,awaitable-promise))
                           (or (not ,timeout)
                               (< (- (float-time) start-time) ,timeout)))
                 (concur-await--run-hooks :yield ,label ,task-expr)
                 (sleep-for concur-async-await-poll-interval)))

             (let ((awaited-outcome (concur:await ,awaitable-promise ,timeout t nil))) 
               (setq ,result (car awaited-outcome))
               (setq ,error-val (cdr awaited-outcome))))
         (concur-async--pop-stack-frame)
         (if ,error-val
             (concur-await--run-hooks :failed ,label ,task-expr ,error-val)
           (concur-await--run-hooks :succeeded ,label ,task-expr))
         (concur-await--run-hooks :done ,label ,task-expr)) ; Assuming :done is a valid hook event

       (when ,error-val
         (log! :error "[%s] Await completed with error: %S" ,label ,error-val)
         (signal (car ,error-val) (cdr ,error-val)))

       ,result)))

;;;###autoload
(defmacro concur:sequence! (items fn &rest args)
  "Process ITEMS sequentially with async FN `(lambda (item))` -> promise/future.
Returns promise with list of results or rejects on first error.
ARGS: Optional keyword args for `concur:map-series` (e.g., :cancel-token)."
  (declare (indent 2) (debug t))
  `(concur:map-series ; Use new name
    ,items
    (lambda (item)
      (let ((result (funcall ,fn item)))
        (if (or (concur-promise-p result) (concur-future-p result))
            (if (concur-future-p result) (concur-future-promise result) result)
          (concur:resolved! result)))) 
    ,@args))

;;;###autoload
(defmacro concur:parallel! (items fn &rest args)
  "Process ITEMS in parallel with async FN `(lambda (item))` -> promise/future.
Returns promise with list of results or rejects on first error.
ARGS: Optional keyword args for `concur:map-parallel` (e.g., :cancel-token)."
  (declare (indent 2) (debug t))
  `(concur:map-parallel ; Use new name
    (cl-loop for item in ,items
             collect (let ((result (funcall ,fn item)))
                       (if (or (concur-promise-p result) (concur-future-p result))
                           (if (concur-future-p result) (concur-future-promise result) result)
                         (concur:resolved! result)))) 
    (lambda (p) p) 
    ,@args))

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple async operations (promise/future FORMS).
Returns promise with outcome of the first to settle."
  (declare (indent 0) (debug t))
  (let ((promises-list (gensym "promises-list")))
    `(let ((,promises-list
            (cl-loop for form in (list ,@forms)
                     collect (let ((p-or-f form))
                               (if (concur-future-p p-or-f)
                                   (concur-future-promise p-or-f)
                                 p-or-f)))))
       (concur:race ,promises-list)))) 

;;;###autoload
(defmacro concur:timeout! (form timeout-seconds)
  "Wrap async operation FORM (promise/future) with TIMEOUT-SECONDS.
Returns promise that rejects on timeout or settles with FORM's outcome."
  (declare (indent 1) (debug t))
  (let ((p-or-f (gensym "p-or-f")))
    `(let ((,p-or-f ,form))
       (concur:timeout ; Use new name
        (if (concur-future-p ,p-or-f) (concur-future-promise ,p-or-f) ,p-or-f)
        ,timeout-seconds))))

(provide 'concur-async)
;;; concur-async.el ends here
