;;; concur-coroutine.el --- Coroutine-Promise Bridge for Concur -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This module provides the bridge between Emacs's `coroutines` library and
;; the `concur` promise system. Its primary function, `concur:from-coroutine`,
;; allows any coroutine runner to be treated as a `concur-promise`, enabling
;; seamless integration into asynchronous promise chains.
;;
;; This module also registers a function with `concur-normalize-awaitable-hook`
;; in `concur-core.el` so that coroutine runners are automatically
;; normalized into `concur-promise` objects wherever awaitables are accepted.

;;; Code:

(require 'cl-lib)
(require 'coroutines)
(require 'concur-promise)

;; This constant is used by coroutines to signal awaiting an external promise.
(declare-function yield--await-external-status-key "yield")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro concur:from-coroutine (runner-form &optional cancel-token-form)
  "Create a `concur-promise` that settles with the outcome of a coroutine.
This macro bridges the `coroutines` library with the `concur` promise system.

Arguments:
- `runner-form`: (form) An expression evaluating to a coroutine runner.
- `cancel-token-form`: (form, optional) An expression evaluating to a
  `concur-cancel-token` to link to this promise's lifecycle.

Returns:
- (`concur-promise`) A promise that resolves when the coroutine
  completes, or rejects if it throws an error or is cancelled."
  (declare (indent 1) (debug t))
  (let* ((runner (gensym "runner-"))
         (resolve (gensym "resolve-"))
         (reject (gensym "reject-"))
         (resume-val (gensym "resume-val-"))
         (yielded-val (gensym "yielded-val-"))
         (awaited-promise (gensym "awaited-promise-"))
         (driver (gensym "drive-coro-")))
    `(let ((,runner ,runner-form))
       (concur:with-executor
           (lambda (,resolve ,reject)
             ;; Use `cl-labels` to define a local recursive function that can
             ;; drive the coroutine by repeatedly calling `send!`.
             (cl-labels
                 ((,driver (&optional ,resume-val)
                    (condition-case err
                        (pcase (send! ,runner ,resume-val)
                          ;; Case 1: Coroutine yields an external promise to await.
                          (`(,yield--await-external-status-key ,,awaited-promise)
                           (concur--log :debug "[CORO] Coroutine yields promise %s."
                                        ,awaited-promise)
                           (concur:then ,awaited-promise
                                        (function ,driver) ; On resolve, resume driver
                                        (function ,reject))) ; On reject, fail all
                          ;; Case 2: Coroutine yields a plain value.
                          (,yielded-val
                           (concur--log :debug "[CORO] Coroutine yields value, resuming.")
                           ;; Resume with `nil` per standard coroutine protocol.
                           (funcall ,driver nil)))
                      ;; Case 3: Coroutine is done.
                      (coroutine-done
                       (concur--log :debug "[CORO] Coroutine done. Result: %S." (car err))
                       (funcall ,resolve (car err)))
                      ;; Case 4: Coroutine was explicitly cancelled.
                      (coroutine-cancelled
                       (concur--log :debug "[CORO] Coroutine cancelled: %S." err)
                       (funcall ,reject err))
                      ;; Case 5: Coroutine signalled an ordinary Lisp error.
                      (error
                       (concur--log :error "[CORO] Coroutine errored: %S." err)
                       (funcall ,reject err)))))
               ;; Initial call to start the coroutine driver.
               (,driver)))
         :cancel-token ,cancel-token-form))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Integration with concur-normalize-awaitable-hook

(defun concur-coroutine-normalize-awaitable (awaitable)
  "Normalizes an AWAITABLE into a promise if it's a coroutine runner.
This function is intended for `concur-normalize-awaitable-hook`.

Arguments:
- `awaitable`: (any) The object to potentially normalize.

Returns:
- (`concur-promise` or nil): The `concur-promise` if `awaitable` is a
  coroutine runner, otherwise `nil`."
  ;; Heuristically check if it's a function, as coroutine runners are.
  (if (functionp awaitable)
      (condition-case nil ; Catch errors if it's not a valid runner.
          (let ((coro-promise (concur:from-coroutine awaitable)))
            (concur--log :debug "[CORO] Normalized coroutine %S to promise %S."
                         awaitable coro-promise)
            coro-promise)
        (error nil)) ; If `concur:from-coroutine` fails, it's not for us.
    nil))

;; --- Plug into the core promise system ---
;; Add this function to the normalization hook so that core functions
;; like `concur:then` can transparently accept coroutine runners.
(add-hook 'concur-normalize-awaitable-hook #'concur-coroutine-normalize-awaitable)

(provide 'concur-coroutine)
;;; concur-coroutine.el ends here