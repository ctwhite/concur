;;; concur-cancel.el --- Concurrency primitives for cancellation -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library defines primitives for handling the cooperative cancellation of
;; asynchronous tasks. It provides the infrastructure for creating cancel
;; tokens, associating them with tasks, signaling cancellation, and registering
;; callbacks to be invoked when a task is canceled.
;;
;; Asynchronous tasks can periodically check their associated cancel token and
;; should terminate their execution gracefully if the token has been canceled.
;;
;; Core Components:
;; - `concur-cancel-token`: A struct representing a cancel token.
;; - `concur:make-cancel-token`: Creates a new, active cancel token.
;; - `concur:cancel-token-cancel!`: Signals cancellation for a token.
;; - `concur:cancel-token-cancelled-p`: Checks if a token is cancelled.
;; - `concur:cancel-token-add-callback`: Registers a callback for cancellation.
;; - `concur:throw-if-cancelled!`: A function for cooperative cancellation in
;;   long-running Lisp tasks.

;;; Code:

(require 'cl-lib)
(require 'ht)
(require 'concur-hooks)      ; For concur--log, if available
(require 'concur-core)       ; For define-error

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Structs and Errors

(define-error 'concur-cancel-error "A promise or task was cancelled." 'concur-error)

(eval-and-compile
  (cl-defstruct (concur-cancel-token (:constructor %%make-cancel-token))
    "Represents a token for signaling cancellation to async operations.

Fields:
- `cancelled-p` (boolean): `t` if the token has been canceled.
- `name` (string): An optional, human-readable name for debugging.
- `data` (any): Optional, arbitrary data to associate with the token."
    (cancelled-p nil :type boolean)
    (name "" :type string)
    data))

(eval-and-compile
  (cl-defstruct (concur-cancel-callback-info
                 (:constructor %%make-cancel-callback-info))
    "Encapsulates information about a registered cancellation callback.

Fields:
- `callback` (function): The actual function to call.
- `dispatcher` (function or nil): An optional function to dispatch the callback."
    (callback nil :type function)
    (dispatcher nil :type (or function null))))

(defvar concur--cancel-token-hooks (ht-create)
  "Global hash table mapping cancel tokens to their cancellation callbacks.
The key is a `concur-cancel-token` and the value is a list of
`concur-cancel-callback-info` structs.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-cancel-token (&optional name data)
  "Create and return a new, active cancel token.

Arguments:
- `NAME` (string, optional): A human-readable name for debugging.
- `DATA` (any, optional): Additional data to associate with the token.

Returns:
  (concur-cancel-token) A new cancel token, initialized as active."
  (let ((token (%%make-cancel-token :name (or name "") :data data)))
    (when (fboundp 'concur--log)
      (concur--log :debug "Created cancel token: %S"
                   (or name (format "token-%s" (sxhash token)))))
    token))

;;;###autoload
(defun concur:cancel-token-cancelled-p (token)
  "Check if the cancel TOKEN has been canceled.

Arguments:
- `TOKEN` (concur-cancel-token): The token to check.

Returns:
  (boolean) `t` if the token is valid and has been cancelled, `nil` otherwise."
  (and (concur-cancel-token-p token)
       (concur-cancel-token-cancelled-p token)))

;;;###autoload
(defun concur:throw-if-cancelled! (token)
  "Check if TOKEN is cancelled and signal a `concur-cancel-error` if so.
This function provides a cooperative cancellation point for long-running
Lisp tasks. It should be placed inside loops or between computational steps
to allow a task to be gracefully terminated.

Arguments:
- `TOKEN` (concur-cancel-token): The cancellation token to check.

Returns:
  `nil` if the token is not cancelled.

Signals:
  (concur-cancel-error) if the token has been cancelled."
  (when (concur:cancel-token-cancelled-p token)
    (signal 'concur-cancel-error (list "Task was cooperatively cancelled"))))

;;;###autoload
(defun concur:cancel-token-cancel! (token)
  "Cancel TOKEN, mark it inactive, and invoke all registered callbacks.
This function is idempotent; it does nothing if the token is already canceled.
Callbacks are dispatched asynchronously.

Arguments:
- `TOKEN` (concur-cancel-token): The token to cancel.

Returns:
  (boolean) `t` if the token was successfully canceled now, `nil` if it was
  already canceled."
  (when (and (concur-cancel-token-p token)
             (not (concur:cancel-token-cancelled-p token)))
    (when (fboundp 'concur--log)
      (concur--log :info "Canceling token: %S" (concur-cancel-token-name token)))
    (setf (concur-cancel-token-cancelled-p token) t)

    ;; Invoke and clear all associated callbacks.
    (when-let ((callback-infos (ht-get concur--cancel-token-hooks token)))
      (ht-remove! concur--cancel-token-hooks token)
      (dolist (info callback-infos)
        (let ((fn (concur-cancel-callback-info-callback info))
              (dispatcher (concur-cancel-callback-info-dispatcher info)))
          ;; Each callback is wrapped to prevent one from halting others.
          (condition-case err
              (if (functionp dispatcher)
                  (funcall dispatcher fn)
                ;; Default dispatch to main thread event loop to ensure asynchronicity.
                (run-at-time 0 nil fn))
            (error
             (when (fboundp 'concur--log)
               (concur--log :error "Cancel callback failed for token %S: %S"
                            (concur-cancel-token-name token) err)))))))
    t))

;;;###autoload
(cl-defun concur:cancel-token-add-callback (token callback &key dispatcher)
  "Register CALLBACK to be run when TOKEN is canceled.
If TOKEN is already canceled, the CALLBACK is scheduled to run immediately
(after a 0-second timer to ensure asynchronicity).

Arguments:
- `TOKEN` (concur-cancel-token): The token to monitor.
- `CALLBACK` (function): A zero-argument function to call upon cancellation.
- `:DISPATCHER` (function, optional): A function `(lambda (callback))`
  that will be used to schedule the `callback`. If nil, `run-at-time 0` is
  used.

Returns:
  nil."
  (unless (concur-cancel-token-p token)
    (error "Invalid cancel token: %S" token))
  (unless (functionp callback)
    (error "Callback must be a function: %S" callback))

  (if (concur:cancel-token-cancelled-p token)
      ;; Token is already canceled, schedule the callback asynchronously.
      (if (functionp dispatcher)
          (funcall dispatcher callback)
        (run-at-time 0 nil callback))
    ;; Token is active, add the info struct if not already present.
    (let ((info (%%make-cancel-callback-info :callback callback
                                             :dispatcher dispatcher))
          (hooks (ht-get concur--cancel-token-hooks token)))
      ;; Avoid adding the same callback function multiple times.
      (unless (member callback hooks :key #'concur-cancel-callback-info-callback)
        (ht-set! concur--cancel-token-hooks token (cons info hooks))))))

;;;###autoload
(defun concur:cancel-token-unregister (token &optional callback)
  "Unregister CALLBACK from TOKEN, or unregister the TOKEN entirely.
This is used for explicit cleanup if a task completes successfully and no
longer needs to listen for cancellation.

Arguments:
- `TOKEN` (concur-cancel-token): The token to unregister from.
- `CALLBACK` (function, optional): The specific callback function to remove.
  If `nil`, the entire token and all its hooks are cleared from the registry.

Returns:
  (boolean) `t` if a change was made, `nil` otherwise."
  (unless (concur-cancel-token-p token)
    (error "Invalid cancel token: %S" token))
  (if callback
      ;; Remove a specific callback info struct.
      (when-let ((hooks (ht-get concur--cancel-token-hooks token)))
        (let ((new-hooks
               (cl-delete callback hooks
                          :key #'concur-cancel-callback-info-callback)))
          (if (null new-hooks)
              (ht-remove! concur--cancel-token-hooks token)
            (ht-set! concur--cancel-token-hooks token new-hooks))
          ;; Return t if the list of hooks has shrunk.
          (< (length new-hooks) (length hooks))))
    ;; Unregister the token and all its hooks completely.
    (ht-remove! concur--cancel-token-hooks token)))

(provide 'concur-cancel)
;;; concur-cancel.el ends here