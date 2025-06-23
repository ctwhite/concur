;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-coroutine.el --- Coroutine-Promise Bridge for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides the bridge between Emacs's built-in `coroutines`
;; library and the `concur` promise system. Its primary function,
;; `concur:from-coroutine`, allows any coroutine runner to be treated as a
;; `concur-promise`, enabling seamless integration into asynchronous promise
;; chains.
;;
;; This module also registers a function with `concur-normalize-awaitable-hook`
;; in `concur-core.el` so that coroutine runners are automatically
;; normalized into `concur-promise` objects wherever awaitables are accepted.

;;; Code:

(require 'cl-lib)        ; For cl-defmacro, cl-labels
(require 'coroutines)    ; For coroutine functions (send!, coroutine-done, etc.)
(require 'concur-core)   ; For core promise types and functions (concur:make-promise,
                         ; concur:then, concur:reject, concur:make-error,
                         ; concur-promise-id, concur-promise-p)
(require 'concur-chain)  ; For `concur:then` (used by the internal driver)
(require 'concur-log)    ; For `concur--log`

;; This constant is used by coroutines to signal awaiting an external promise.
(declare-function yield--await-external-status-key "yield")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(cl-defmacro concur:from-coroutine (runner-form &key cancel-token (mode :deferred))
  "Create a `concur-promise` that settles with the outcome of a coroutine.
This macro bridges the `coroutines` library with the `concur` promise system.
The coroutine's execution is driven by a hidden function that resumes the
coroutine whenever an awaited promise resolves or a yield occurs.

  Arguments:
  - `RUNNER-FORM` (form): An expression evaluating to a coroutine runner
    (e.g., `(coroutine-create (lambda () ...))`).
  - `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to link to the
    promise's lifecycle for cancellation. If the token is cancelled, the
    coroutine's promise will be rejected.
  - `:MODE` (symbol, optional): The concurrency mode for the promise created
    by this coroutine. Defaults to `:deferred`. This mode determines how
    the coroutine's internal state machine operates and how its callbacks
    are scheduled.

  Returns:
  - (concur-promise): A promise that resolves when the coroutine
    completes (signals `coroutine-done`), or rejects if it throws an
    error (signals `error`) or is cancelled (signals `coroutine-cancelled`)."
  (declare (indent 1) (debug t))
  (let ((runner (gensym "runner-"))
        (resolve (gensym "resolve-"))
        (reject (gensym "reject-"))
        (resume-val (gensym "resume-val-"))
        (yielded-val (gensym "yielded-val-"))
        (awaited-promise (gensym "awaited-promise-"))
        (driver (gensym "drive-coro-")))
    ;; The promise's mode is set here in `with-executor`.
    `(concur:with-executor (lambda (,resolve ,reject)
       (let ((,runner ,runner-form))
         (concur--log :debug nil "Starting coroutine %S." ,runner)
         ;; Use `cl-labels` for a local recursive function to drive the coroutine.
         (cl-labels
             ((,driver (&optional ,resume-val)
                (condition-case err
                    (pcase (send! ,runner ,resume-val)
                      ;; Case 1: Coroutine yields an external promise to await.
                      ;; `concur:await!` expands to `(yield! (list yield--await-external-status-key PROMISE))`
                      (`(,yield--await-external-status-key ,,awaited-promise)
                       (concur--log :debug nil "Coroutine %S yielded promise %S. Awaiting..."
                                    ,runner (concur-promise-id ,awaited-promise))
                       (concur:then ,awaited-promise
                                    (function ,driver) ; On resolve, resume driver.
                                    (function ,reject))) ; On reject, fail the coroutine.
                      ;; Case 2: Coroutine yields a plain value (ignored by driver).
                      (,yielded-val
                       (concur--log :debug nil "Coroutine %S yielded value %S. Resuming."
                                    ,runner ,yielded-val)
                       ;; Resume with `nil` per standard coroutine protocol,
                       ;; continuing to the next iteration.
                       (funcall ,driver nil)))
                  ;; Case 3: Coroutine is done. Resolve the master promise.
                  (coroutine-done
                   (concur--log :info nil "Coroutine %S finished with result: %S"
                                ,runner (car err))
                   (funcall ,resolve (car err)))
                  ;; Case 4: Coroutine was explicitly cancelled. Reject.
                  (coroutine-cancelled
                   (concur--log :warn nil "Coroutine %S cancelled: %S"
                                ,runner err)
                   (funcall ,reject err))
                  ;; Case 5: Coroutine signalled an ordinary Lisp error. Reject.
                  (error
                   (concur--log :error nil "Coroutine %S threw error: %S"
                                ,runner err)
                   (funcall ,reject err)))))
           ;; Initial call to start the coroutine driver.
           (,driver))))
     :cancel-token ,cancel-token
     :mode ,mode)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Integration with concur-normalize-awaitable-hook

(defun concur-coroutine-normalize-awaitable (awaitable)
  "Normalize an AWAITABLE into a promise if it's a coroutine runner.
This function is intended for `concur-normalize-awaitable-hook` and allows
core functions like `concur:then` to transparently accept coroutine runners.

  Arguments:
  - `AWAITABLE` (any): The object to potentially normalize.

  Returns:
  - (concur-promise or nil): A promise if `AWAITABLE` was a coroutine
    runner, otherwise `nil`."
  ;; Heuristically check if it's a function. Coroutine runners are functions.
  ;; `condition-case` is used to catch `error` if it's not actually a runner.
  (if (functionp awaitable)
      (condition-case nil
          ;; NOTE: When normalizing implicitly, we cannot know the intended
          ;; concurrency mode, so we must use the default `:deferred`.
          ;; Explicitly calling `concur:from-coroutine` or `concur:async!` is
          ;; the way to specify a different mode or cancel token.
          (concur--log :debug nil "Normalizing coroutine %S to promise."
                       awaitable)
          (concur:from-coroutine awaitable :mode :deferred)
        (error ; If `concur:from-coroutine` fails, it's not a valid runner.
         (concur--log :debug nil "Normalization failed for non-coroutine %S."
                      awaitable)
         nil))
    nil))

;; Plug into the core promise system by adding to `concur-normalize-awaitable-hook`.
(add-hook 'concur-normalize-awaitable-hook
          #'concur-coroutine-normalize-awaitable)

(provide 'concur-coroutine)
;;; concur-coroutine.el ends here