;;; concur-future.el --- Concurrency primitives for asynchronous tasks ---

;;; Commentary:
;;
;; This library provides concurrency primitives for handling asynchronous
;; tasks in Emacs. It integrates with `concur-promise` for promise-based
;; management of task resolution and rejection, and `concur-exec` for task
;; execution.
;;
;; This module introduces higher-level abstractions like futures, allowing
;; tasks to be executed concurrently while waiting for results without blocking
;; the main Emacs event loop. Futures provide a way to work with the result of
;; asynchronous tasks without directly using callbacks.
;;

;;; Code:

(require 'cl-lib)   
(require 'dash)
(require 'concur-lock)
(require 'concur-promise)
(require 'concur-var)
(require 'ht)

(cl-defstruct
    (concur-future
     (:constructor nil)
     (:constructor concur-future-create (&key promise thunk evaluated?)))
  "A lazy future represents a deferred computation that returns a promise when forced.

FIELDS:

- PROMISE: The cached promise, evaluated once the thunk is forced. Remains nil until evaluated.
- THUNK: A zero-argument function representing the computation to run lazily.
- evaluated?: Non-nil if the thunk has already been evaluated, indicating the promise is cached."
  promise     ;; Cached promise after evaluation
  thunk       ;; Zero-argument function returning a promise
  evaluated? ;; Boolean flag indicating evaluation state
)

;;;###autoload
(defun concur-future-new (thunk)
  "Create a `future` from a THUNK of one argument (the promise).
THUNK should be a function that accepts a promise and eventually
resolves or rejects it. It won't be executed until forced via
`concur-future-evaluate`."
  (concur-future-create
   :promise (concur-promise-new)  ;; Create an empty promise
   :thunk thunk                   ;; The thunk to resolve/reject the promise
   :evaluated? nil))              ;; Flag indicating the future hasn't been evaluated yet
         
(defmacro concur-future-once! (future &rest body)
  "Evaluate BODY only once per FUTURE. Safe to call multiple times.

This macro ensures that the FUTURE's thunk is only evaluated once, even if
called multiple times. The evaluation is guarded by the `concur-future-evaluated?`
slot, which is set to `t` after the first execution.

Does not return the promise directly — use `concur-future-force` for that."
  (declare (indent 1))
  `(concur-once-do! (concur-future-evaluated? ,future)
     (:else
      (concur--log! "[future] Already evaluated: %S" ,future)
      (if (concur-future-promise ,future)
          (concur--log! "[future] Promise is already resolved: %S" ,future)
        (concur--log! "[future] Promise is not resolved, but future was marked evaluated.")))

     (concur--log! "[future] Evaluating thunk for: %S" ,future)
     (let ((thunk (concur-future-thunk ,future))
           (promise (concur-future-promise ,future)))
       (if (and thunk promise)
           (funcall thunk promise)
         (concur--log! "[future] Missing thunk or promise in FUTURE: %S" ,future)))))
         
;;;###autoload
(defun concur-future-force (future)
  "Force FUTURE's thunk to run if not already. Returns the internal promise.
Returns nil if FUTURE is nil or not a valid concur-future object."
  (cond
   ((null future)
    (concur--log! "[future-force] FUTURE is nil. Nothing to evaluate.")
    nil)

   ((not (concur-future-p future))
    (concur--log! "[future-force] Invalid FUTURE object: %S" future)
    nil)

   (t
    (concur-future-once! future)
    (let ((promise (concur-future-promise future)))
      (concur--log! "[future-force] Returning promise from FUTURE: %S" promise)
      promise))))

(defalias 'concur-future-evaluate #'concur-future-force)

;;;###autoload
(defun concur-future-wrap (fn)
  "Wrap a no-arg function FN into a `future`.
The returned future will call FN and resolve or reject based on
its result. If FN throws an error, it is caught and causes rejection."
  (concur-future-new
   (lambda (promise)  ; This lambda is executed when the future is forced
     (condition-case ex
         (progn
           (let ((result (funcall fn)))
             (concur-promise-resolve promise result)))  
       (error (concur-promise-reject promise ex))))))

;;;###autoload
(defun concur-future-attach (future promise &optional evaluate)
  "Attach PROMISE to FUTURE so that once FUTURE is evaluated, PROMISE is resolved.

If EVALUATE is non-nil (default), the future will be forced.
If nil, it is assumed the caller will evaluate the future later."
  (let ((existing-promise (concur-future-promise future)))
    (unless (concur-promise-p existing-promise)
      (error "Cannot attach a future that does not have a valid promise"))

    ;; Forward resolution/rejection to attached promise.
    (concur-promise-then existing-promise
                         (lambda (result)
                           (concur-promise-resolve promise result)))
    (concur-promise-catch existing-promise
                          (lambda (error)
                            (concur-promise-reject promise error)))

    ;; Optionally force the future.
    (when (and (not (concur-future-evaluated? future))
               (or (null evaluate) (eq evaluate t))) ; default is to evaluate
      (concur-future-force future)))
  promise)

;;;###autoload
(defun concur-future-from-process (command &optional args cwd env input)
  "Return a `future` that runs COMMAND asynchronously with ARGS.
CWD sets the working directory, ENV sets environment variables,
INPUT is a string to send to stdin.

The future resolves with trimmed STDOUT or rejects with a plist
containing :error, :exit, :stdout, and :stderr."
  (concur-future-wrap
   (lambda ()
     (concur-promise-run
      :command command
      :args args
      :cwd cwd
      :env env
      :stdin input
      :discard-ansi t
      :die-on-error t))))

;;;###autoload
(cl-defun concur-futures (futures &key (max 4) (delay 0) (order 'ordered))
  "Run FUTURES (list of futures or thunks) with MAX concurrency.
Optional DELAY throttles task launching. ORDER can be 'ordered or 'unordered.

Returns a promise that resolves to a hash table of results or errors, keyed by index."
  (let* ((total (length futures))
         (results (ht-create))
         (queue (-map-indexed (lambda (i fut)
                                (list :index i
                                      :future (if (concur-future-p fut)
                                                  fut
                                                (concur-future-wrap fut))))
                              futures))
         (active 0)
         (done 0)
         (promise (concur-promise-new)))

    (cl-labels
        ((run-next ()
           (while (and queue (< active max))
             (pcase-let* ((`(:index ,i :future ,fut) (pop queue)))
               (setq active (1+ active))
               (when delay (sit-for delay))
               (concur-promise-then
                (concur-future-evaluate fut)
                (lambda (result)
                  (ht-set! results i result)
                  (setq done (1+ done)
                        active (1- active))
                  (if (= done total)
                      (concur-promise-resolve promise results)
                    (run-next)))
                (lambda (err)
                  (ht-set! results i err)
                  (setq done (1+ done)
                        active (1- active))
                  (if (= done total)
                      (concur-promise-resolve promise results)
                    (run-next))))))))

      (run-next))

    (concur-promise->future promise)))

(provide 'concur-future)
;;; concur-future.el ends here