;;; concur-promise-utils.el --- Utility and integration functions for Concur Promises
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides utility functions and integrations with other Emacs
;; asynchronous systems, such as the `coroutines` library. It contains
;; helpers for creating promises from various asynchronous patterns.

;;; Code:

(require 'cl-lib)
(require 'concur-promise-core)
(require 'concur-promise-chain)
(require 'concur-promise-combinators)
(require 'coroutines)

;; Forward declarations for byte-compiler
(declare-function yield--internal-throw-form "" (value tag))
(declare-function concur--process-handler "concur-promise-chain"
                  (handler-form handler-type-str initial-param-bindings))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Utilities and Integrations

;;;###autoload
(defmacro concur:from-callback (fetch-fn-form)
  "Wrap a callback-based async function into a `concur-promise`.
The function `FETCH-FN-FORM` should expect a single callback argument,
which will be invoked as `(callback result error)`.

Arguments:
- FETCH-FN-FORM (form): An expression evaluating to a function that
  takes one argument: a callback function of the form `(result error)`.

Returns:
A `concur-promise` that resolves with `result` or rejects with `error`."
  (declare (indent 1) (debug t))
  `(concur:with-executor
       (lambda (resolve reject)
         (funcall ,fetch-fn-form
                  (lambda (result error)
                    (if error
                        (funcall reject error)
                      (funcall resolve result)))))))

;;;###autoload
(defmacro concur:from-coroutine (runner-form &optional cancel-token-form)
  "Create a `concur-promise` that settles with the outcome of a coroutine.
This macro bridges the `coroutines` library with the `concur` promise system,
allowing a coroutine's execution to be represented as a promise.

Arguments:
- RUNNER-FORM (form): An expression evaluating to a coroutine runner
  (as returned by `coroutine-start`).
- CANCEL-TOKEN-FORM (form, optional): An expression evaluating to a
  `concur-cancel-token` to link to this promise's lifecycle.

Returns:
A `concur-promise` that resolves when the coroutine completes successfully,
or rejects if the coroutine throws an error or is cancelled."
  (declare (indent 1) (debug t))
  (let* ((runner-sym (gensym "runner-"))
         (promise-sym (gensym "promise-"))
         (resolve-sym (gensym "resolve-"))
         (reject-sym (gensym "reject-"))
         (resume-val-sym (gensym "resume-val-"))
         (yielded-val-sym (gensym "yielded-val-"))
         (awaited-promise-sym (gensym "awaited-promise-"))
         ;; This is the name of the local recursive function.
         (driver-sym (gensym "drive-coro-")))
    `(let ((,runner-sym ,runner-form))
       (concur:with-executor
           (lambda (,resolve-sym ,reject-sym)
             ;; Use `cl-labels` to define a local recursive function that can
             ;; drive the coroutine by repeatedly calling `send!`.
             (cl-labels
                 ((,driver-sym (&optional ,resume-val-sym)
                    (condition-case err
                        (pcase (send! ,runner-sym ,resume-val-sym)
                          ;; Case 1: Coroutine yields an external promise to await.
                          (`(:await-external ,,awaited-promise-sym)
                           ;; We chain the next step of the driver to the
                           ;; yielded promise. The `concur:then` macro will
                           ;; correctly handle lifting `driver-sym` and `reject-sym`.
                           (concur:then ,awaited-promise-sym
                                        #',driver-sym
                                        #',reject-sym))
                          ;; Case 2: Coroutine yields a plain value.
                          (,yielded-val-sym
                           (funcall #',driver-sym ,yielded-val-sym)))
                      ;; Case 3: Coroutine is done, resolve the main promise.
                      (coroutine-done (funcall ,resolve-sym (car err)))
                      ;; Case 4: Coroutine was cancelled or errored.
                      (coroutine-cancelled (funcall ,reject-sym err))
                      (error (funcall ,reject-sym err)))))
               ;; Initial call to start the coroutine driver.
               (,driver-sym)))
         :cancel-token ,cancel-token-form))))

(defun concur:delay (seconds &optional value)
  "Return a promise that resolves with VALUE after SECONDS.

Arguments:
- SECONDS (number): The number of seconds to wait before resolving.
- VALUE (any, optional): The value the promise will resolve with. If `nil`,
  the promise resolves with `t`.

Returns:
A `concur-promise` that resolves after the specified delay."
  (concur:with-executor
      (lambda (resolve _reject)
        (run-at-time seconds nil
                     (lambda () (funcall resolve (or value t)))))))

(defun concur:timeout (timed-promise timeout-seconds)
  "Wrap a promise, rejecting it if it does not settle within a timeout.
This effectively races the original promise against a delay promise.

Arguments:
- TIMED-PROMISE (`concur-promise`): The promise to apply a timeout to.
- TIMEOUT-SECONDS (number): The maximum number of seconds to wait.

Returns:
A new `concur-promise` that adopts the state of the original promise,
or rejects with a `concur:timeout-error` if the timeout is reached first."
  (concur:race
   (list timed-promise
         (concur:delay timeout-seconds)
         (concur:then (concur:delay timeout-seconds)
                      (lambda (_)
                        (concur:rejected!
                         '(concur:timeout-error
                           "Promise timed out")))))))

(cl-defun concur:retry (fn &key (retries 3) (delay 0.1) (pred #'always))
  "Retry an asynchronous function `FN` up to `RETRIES` times on failure.

Arguments:
- FN (function): A zero-argument function that returns a `concur-promise`.
- :RETRIES (integer, optional): Max number of retry attempts. Defaults to 3.
- :DELAY (number or function, optional): Delay in seconds before each retry.
  If a function, it receives the attempt number (1-indexed) and should
  return the delay time. Defaults to 0.1 seconds.
- :PRED (function, optional): A predicate `(error)` that returns `t` if the
  given error should trigger a retry. Defaults to `#'always`.

Returns:
A `concur-promise` that resolves with `FN`'s successful result, or rejects
if all retry attempts fail."
  (let ((retry-promise (concur:make-promise)) (attempt 0))
    (cl-labels
        ((delay-and-retry ()
           (let ((d (if (functionp delay) (funcall delay attempt) delay)))
             (concur:then (concur:delay d) #'do-try)))
         (do-try ()
           (concur:catch
            (funcall fn)
            (lambda (err)
              (if (and (< (cl-incf attempt) retries) (funcall pred err))
                  (delay-and-retry)
                (concur:rejected! err))))))
      (concur:then (do-try)
                   (lambda (res) (concur:resolve retry-promise res))
                   (lambda (err) (concur:reject retry-promise err))))
    retry-promise))

(cl-defun concur:promise-semaphore-acquire (sem &key timeout)
  "Acquire a slot from SEM, returning a promise.

Arguments:
- SEM (`concur-semaphore`): The semaphore to acquire a slot from.
- :TIMEOUT (number, optional): Max time in seconds to wait for a slot.

Returns:
A `concur-promise` that resolves with `t` on successful acquisition, or
rejects with a `concur:semaphore-timeout` error on timeout."
  (concur:with-executor
      (lambda (resolve reject)
        (concur:semaphore-acquire
         sem
         (lambda () (funcall resolve t))
         :timeout timeout
         :timeout-callback
         (lambda ()
           (funcall reject '(concur:semaphore-timeout
                             "Semaphore acquire timed out")))))))

(provide 'concur-promise-utils)
;;; concur-promise-utils.el ends here