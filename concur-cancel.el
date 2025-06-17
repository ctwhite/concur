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
;; - `concur:cancel-token-active-p`: Checks if a token is still active.
;; - `concur:cancel-token-on-cancel`: Registers a callback for cancellation.

;;; Code:

(require 'cl-lib)
(require 'ht)
(require 'concur-hooks)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Structs and Registries

;; The struct must be defined at compile time so other modules can refer to
;; the `concur-cancel-token` type in their own definitions.
(eval-and-compile
  (cl-defstruct (concur-cancel-token (:constructor %%make-cancel-token))
    "Represents a token for signaling cancellation to async operations.
Do not construct directly; use `concur:make-cancel-token`.

Fields:
- `active` (boolean): `t` if the token has not been canceled.
- `name` (string): An optional, human-readable name for debugging.
- `data` (any): Optional, arbitrary data to associate with the token."
    (active t :type boolean)
    name
    data))

(defvar concur--cancel-token-hooks (ht-create)
  "Global hash table mapping cancel tokens to their cancellation callbacks.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-cancel-token (&optional name data)
  "Create and return a new, active cancel token.

Arguments:
- NAME (string, optional): A human-readable name for debugging.
- DATA (any, optional): Additional data to associate with the token.

Returns:
A new `concur-cancel-token` struct, initialized as active."
  (let ((token (%%make-cancel-token :name name :data data)))
    (concur--log :debug "Created cancel token: %S"
                 (or name (format "token-%s" (sxhash token))))
    token))

;;;###autoload
(defun concur:cancel-token-active-p (token)
  "Check if the cancel TOKEN is still active (i.e., not canceled).

Arguments:
- TOKEN (`concur-cancel-token`): The token to check.

Returns:
`t` if the token is valid and active, `nil` otherwise."
  (and (concur-cancel-token-p token)
       (concur-cancel-token-active token)))

;;;###autoload
(defun concur:cancel-token-check (token)
  "Check if TOKEN is canceled, logging a message if it is.
This is a convenience function for tasks to poll for cancellation.

Arguments:
- TOKEN (`concur-cancel-token`): The cancel token to check.

Returns:
`t` if the token is canceled (indicating the task should terminate),
`nil` otherwise."
  (unless (concur:cancel-token-active-p token)
    (concur--log :debug "Task canceled via token: %S"
                 (concur-cancel-token-name token))
    t))

;;;###autoload
(defun concur:cancel-token-cancel (token)
  "Cancel TOKEN, mark it inactive, and invoke all registered callbacks.
This function is idempotent; it does nothing if the token is already inactive.
The callbacks are invoked once and then cleared for the token.

Arguments:
- TOKEN (`concur-cancel-token`): The token to cancel.

Returns:
`t` if the token was successfully canceled, `nil` if it was already inactive."
  (when (concur:cancel-token-active-p token)
    (concur--log :info "Canceling token: %S" (concur-cancel-token-name token))
    (setf (concur-cancel-token-active token) nil)

    ;; Invoke and clear all associated callbacks.
    (when-let ((callbacks (ht-get concur--cancel-token-hooks token)))
      (ht-remove! concur--cancel-token-hooks token)
      (dolist (fn callbacks)
        (condition-case err
            (funcall fn)
          (error (concur--log :error "Cancel callback failed for token %S: %S"
                              (concur-cancel-token-name token) err)))))
    t))

;;;###autoload
(defun concur:cancel-token-on-cancel (token callback)
  "Register CALLBACK to be run when TOKEN is canceled.
If TOKEN is already canceled, the CALLBACK is run immediately (after a
0-second timer to ensure asynchronicity).

Arguments:
- TOKEN (`concur-cancel-token`): The token to monitor.
- CALLBACK (function): A zero-argument function to call upon cancellation.

Returns:
`nil`."
  (unless (concur-cancel-token-p token)
    (error "Invalid cancel token: %S" token))
  (unless (functionp callback)
    (error "Callback must be a function: %S" callback))

  (if (concur:cancel-token-active-p token)
      ;; Token is active, add the hook if it's not already present.
      (let ((hooks (ht-get concur--cancel-token-hooks token)))
        (unless (memq callback hooks)
          (ht-set! concur--cancel-token-hooks token (cons callback hooks))))
    ;; Token is already canceled, run the callback asynchronously.
    (run-at-time 0 nil callback)))

;;;###autoload
(defun concur:cancel-token-unregister (token &optional callback)
  "Unregister CALLBACK from TOKEN, or unregister the TOKEN entirely.
This is used for explicit cleanup if a token is no longer needed and has not
been (or will not be) canceled.

Arguments:
- TOKEN (`concur-cancel-token`): The token to unregister.
- CALLBACK (function, optional): The specific callback to remove. If `nil`,
  the entire token and all its hooks are cleared from the registry.

Returns:
`t` if a change was made, `nil` otherwise."
  (unless (concur-cancel-token-p token)
    (error "Invalid cancel token: %S" token))
  (if callback
      ;; Remove a specific callback.
      (when-let ((hooks (ht-get concur--cancel-token-hooks token)))
        (let ((new-hooks (delq callback hooks)))
          (if (null new-hooks)
              (ht-remove! concur--cancel-token-hooks token)
            (ht-set! concur--cancel-token-hooks token new-hooks))
          ;; Return t if the list of hooks was actually changed.
          (< (length new-hooks) (length hooks))))
    ;; Unregister the token and all its hooks completely.
    (ht-remove! concur--cancel-token-hooks token)))

(provide 'concur-cancel)
;;; concur-cancel.el ends here