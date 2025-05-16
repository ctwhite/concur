;;; concur-future.el --- Concurrency primitives for asynchronous tasks --- -*- lexical-binding: t; -*-
;;
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
;;
;;; Code:

(require 'cl-lib)   
(require 'dash)
(require 'concur-primitives)
(require 'concur-promise)
(require 'ht)
(require 'scribe)

(cl-defstruct
    (concur-future
     (:constructor nil)
     (:constructor concur-future-create (&key promise thunk evaluated?)))
  "A lazy future represents a deferred computation that returns a promise when forced.

Fields:

`promise`    The cached promise, evaluated once the thunk is forced. Remains nil until evaluated.
`thunk`      A zero-argument function representing the computation to run lazily.
`evaluated?` Non-nil if the thunk has already been evaluated, indicating the promise is cached."

  promise   
  thunk     
  evaluated?)

;;;###autoload
(defun concur-future-new (thunk)
  "Wrap a no-arg function FN into a `future`.
The returned future will call FN and resolve or reject based on
its result. If FN throws an error, it is caught and causes rejection."
  (let ((promise (concur-promise-new)))  
    (let ((future (concur-future-create
                   :thunk (lambda ()
                     (condition-case ex
                         (let ((result (funcall thunk)))
                           ;; Resolve the promise when the function succeeds
                           (concur-promise-resolve promise result))
                       (error
                        ;; Reject the promise when the function fails
                        (concur-promise-reject promise ex))))
                   :promise promise
                   :evaluated? nil)))
      ;; Return the future object
      future)))

;;;###autoload
(defun concur-future-error? (future)
  "Return non-nil if FUTURE is in an error state.

Arguments:
  PROMISE -- A `concur-future` instance.

Return:
  Non-nil if the FUTURE has an error associated with it (i.e., evaluated with an error)."
  (concur-promise-error? (concur-future-promise future)))

(defmacro concur-future-once! (future &rest body)
  "Evaluate BODY only once per FUTURE. Safe to call multiple times.

This macro ensures that the FUTURE's thunk is only evaluated once, even if
called multiple times. The evaluation is guarded by the `concur-future-evaluated?`
slot, which is set to `t` after the first execution.

Does not return the promise directly — use `concur-future-force` for that."
  (declare (indent 1))
  `(once-do! (concur-future-evaluated? ,future)
     (:else
      (log! "Already evaluated: %S" ,future :level 'warn)
      (if (concur-future-promise ,future)
          (log! "Promise is already resolved: %S" ,future :level 'warn)
        (log! "Promise is not resolved, but future was marked evaluated." :level 'warn)))

     (log! "Evaluating thunk for: %S" ,future)
     (let ((thunk (concur-future-thunk ,future)))           
       (if thunk
           (funcall thunk)
         (log! "Missing thunk or promise in FUTURE: %S" ,future :level 'warn)))))
         
;;;###autoload
(defun concur-future-force (future)
  "Force FUTURE's thunk to run if not already. Returns the internal promise.
Returns nil if FUTURE is nil or not a valid concur-future object."
  (log! "Forcing FUTURE: %S" future)
  (cond
   ((null future)
    (log! "FUTURE is nil. Nothing to evaluate." :level 'warn)
    nil)

   ((not (concur-future-p future))
    (log! "Invalid FUTURE object: %S" future :level 'warn)
    nil)

   (t
    (concur-future-once! future)
    (let ((promise (concur-future-promise future)))
      (log! "Returning promise from FUTURE: %S" promise)
      promise))))

(defalias 'concur-future-evaluate #'concur-future-force)

;;;###autoload
(defun concur-future-attach (future promise &optional evaluate)
  "Attach PROMISE to FUTURE so that once FUTURE is evaluated, PROMISE is resolved.

If EVALUATE is non-nil (default), the future will be forced.
If nil, it is assumed the caller will evaluate the future later."
  (log! "Attaching promise %S to future %S" promise future)
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

(provide 'concur-future)
;;; concur-future.el ends here