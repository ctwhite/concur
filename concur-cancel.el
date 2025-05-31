;;; concur-cancel.el --- Concurrency primitives for cancellation --- -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file defines concurrency primitives for handling cancellation of asynchronous tasks.
;; It provides the infrastructure for associating cancel tokens with tasks and for registering
;; callbacks that will be invoked when a task is canceled.
;;
;; Concurrency tasks can check for cancellation using their associated cancel token and halt
;; execution if the token is marked as active. This mechanism allows tasks to be canceled safely
;; and efficiently in concurrent operations.
;;
;; The following structures and variables are defined:
;;
;; - `concur-cancel-token`: A structure representing a cancel token. Each token can be marked
;;   as inactive to signal cancellation.
;;
;; - `concur-cancel-token--active-tokens`: A hash table that keeps track of all currently active
;;   (not yet cancelled) cancel tokens.
;;
;; - `concur-cancel-token--hooks`: A hash table mapping cancel tokens to a list of callback
;;   functions that will be invoked when the token is canceled.
;;
;; Functions in this file include:
;; - `concur-cancel-token-create`: Creates a new cancel token.
;; - `concur-cancel-token-cancel`: Signals cancellation for a token and invokes its callbacks.
;; - `concur-cancel-token-active?`: Checks if a token is still active.
;; - `concur-cancel-token-check`: A convenience function to check activity and log cancellation.
;; - `concur-cancel-token-on-cancel`: Registers a callback to be invoked on cancellation.
;; - `concur-cancel-token-unregister`: Removes a token from the active registry and its associated hooks.
;;
;; This system is designed to be flexible, allowing for easy task cancellation and the handling
;; of cancellation events through registered callbacks.
;;
;;; Code:

(require 'cl-lib)
(require 'ht)
(require 'scribe)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Internal Structs                           ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (concur-cancel-token
            (:constructor nil)
            (:constructor concur-cancel-token--create (&key active name data)))
  "A structure representing a cancel token that can be used to cancel asynchronous tasks.

The `concur-cancel-token` struct is used to signal cancellation for tasks. If a task checks
for cancellation and finds that its associated cancel token is active, it can halt execution early.

Fields:

`active`  A boolean value indicating whether the cancel token is active. If `active` is
          non-nil, tasks associated with this token can be canceled.
`name`    An optional human-readable name for the cancel token, which can be useful for
          debugging or logging purposes.
`data`    An optional plist containing additional data associated with the cancel token."

  active
  name
  data)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Global Registries                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar concur-cancel-token--active-tokens (ht)
  "Registry mapping currently active cancel tokens to themselves.
Used to track all tokens that have been created and not yet explicitly unregistered.")

(defvar concur-cancel-token--hooks (ht)
  "Hash table mapping cancel tokens to a list of cancel callbacks.
These callbacks are invoked when the associated token is cancelled.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Internal Helpers                           ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun concur-cancel-token--get-name (token)
  "Return a human-readable name for the cancel TOKEN.
If the token has a `name` field, return that; otherwise, generate a unique name."
  (if (concur-cancel-token-p token)
      (or (concur-cancel-token-name token)
          (format "cancel-token-%s" (sxhash token))) ; Use object-hash for unique ID
    "invalid-token")) ; Fallback for invalid token

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Public API                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur-cancel-token-create (&optional name data)
  "Create and return a new cancel token.
This function creates a new cancel token and marks it as active by default.
The token is automatically registered in an internal registry of active tokens.

Arguments:
  - NAME: Optional string, a human-readable name for the token.
  - DATA: Optional plist, additional data to associate with the token.

Returns:
  A new `concur-cancel-token` struct, initialized with an `:active` field set to t."
  (let ((token (concur-cancel-token--create :active t :name name :data data)))
    (log! :info "concur-cancel-token-create: Creating cancel token: %S (name: %S)."
          token (concur-cancel-token--get-name token))
    ;; Register the token as soon as it is created
    (ht-set! concur-cancel-token--active-tokens token t)
    token))

;;;###autoload
(defun concur-cancel-token-cancel (token)
  "Cancel the given TOKEN, marking it as inactive, and notify all registered observers.
This function sets the cancel token's `:active` field to nil to indicate the task
associated with this token should be canceled. All callbacks registered with
`concur-cancel-token-on-cancel` for this token will be invoked.

Arguments:
  - TOKEN: The `concur-cancel-token` to cancel.

Side Effects:
  - Sets the `:active` field of the token to nil, marking it as canceled.
  - Invokes all registered cancellation callbacks for this token.
  - Clears the registered callbacks for this token to prevent memory leaks.
  - Removes the token from the `concur-cancel-token--active-tokens` registry.

Error Handling:
  - Signals an error if the token is not a valid `concur-cancel-token` object."
  (unless (concur-cancel-token-p token)
    (error "concur-cancel-token-cancel: Invalid cancel token object: %S" token))

  (if (concur-cancel-token-active token)
      (progn
        (log! :info "concur-cancel-token-cancel: Canceling token: %S (name: %S)."
              token (concur-cancel-token--get-name token))
        (setf (concur-cancel-token-active token) nil) ; Mark as inactive

        (let ((callbacks (ht-get concur-cancel-token--hooks token)))
          (when callbacks
            (log! :debug "concur-cancel-token-cancel: Invoking %d callbacks for token %S."
                  (length callbacks) (concur-cancel-token--get-name token))
            (mapc (lambda (fn)
                    (condition-case err
                        (funcall fn)
                      (error (log! :error "concur-cancel-token-cancel: Callback for token %S failed: %S."
                                   (concur-cancel-token--get-name token) err :trace))))
                  callbacks)
            ;; Clear hooks to avoid memory leaks
            (ht-remove! concur-cancel-token--hooks token)))
        ;; Remove from active tokens registry
        (ht-remove! concur-cancel-token--active-tokens token))
    (log! :debug "concur-cancel-token-cancel: Token %S (name: %S) already cancelled. No-op."
          token (concur-cancel-token--get-name token))))

;;;###autoload
(defun concur-cancel-token-active? (token)
  "Check if the cancel TOKEN is still active (i.e., not canceled).
This function checks the `:active` field of the token to determine if the task
associated with this token should still be active.

Arguments:
  - TOKEN: The `concur-cancel-token` to check.

Returns:
  - t if the token is active (not canceled).
  - nil if the token is canceled or invalid."
  (unless (concur-cancel-token-p token)
    (log! :warn "concur-cancel-token-active?: Invalid cancel token object: %S. Returning nil." token)
    (cl-return-from concur-cancel-token-active? nil))
  (concur-cancel-token-active token))

;;;###autoload
(defun concur-cancel-token-check (token)
  "Check if the task should be canceled by evaluating the cancel TOKEN.
If the token is canceled, this function logs the cancellation and returns `t` to
indicate that the task should be canceled. If the token is still active, it returns `nil`.

Arguments:
  - TOKEN: The `concur-cancel-token` to check.

Returns:
  - t if the token is canceled (task should be canceled).
  - nil if the token is active (task should continue).

Throws:
  - An error if TOKEN is not a valid `concur-cancel-token` object."
  (unless (concur-cancel-token-p token)
    (error "concur-cancel-token-check: Invalid cancel token object: %S" token))

  (if (not (concur-cancel-token-active? token))
      (progn
        (log! :info "concur-cancel-token-check: Task canceled due to token %S (name: %S)."
              token (concur-cancel-token--get-name token))
        t)  ;; Return t to indicate cancellation
    nil))  ;; Return nil if the task is still active

;;;###autoload
(defun concur-cancel-token-on-cancel (token callback)
  "Register CALLBACK to be run when TOKEN is canceled.
The CALLBACK will be invoked with no arguments when `concur-cancel-token-cancel`
is called on the `TOKEN`. If the token is already cancelled, the callback is
invoked immediately (asynchronously).

Arguments:
  - TOKEN: The `concur-cancel-token` to register the callback for.
  - CALLBACK: A zero-argument function to be called on cancellation.

Side Effects:
  - Adds the callback to the token's internal list of hooks.
  - Callbacks are deduplicated based on `eq` identity.

Throws:
  - An error if TOKEN is not a valid `concur-cancel-token` object or CALLBACK is not a function."
  (unless (concur-cancel-token-p token)
    (error "concur-cancel-token-on-cancel: Invalid cancel token object: %S" token))
  (unless (functionp callback)
    (error "concur-cancel-token-on-cancel: CALLBACK must be a function, but got %S" callback))

  (log! :debug "concur-cancel-token-on-cancel: Registering cancel callback for token: %S (name: %S)."
        token (concur-cancel-token--get-name token))

  (if (concur-cancel-token-active? token)
      (let* ((callbacks (ht-get concur-cancel-token--hooks token))
             (already-registered (member callback callbacks)))
        (unless already-registered
          (ht-set! concur-cancel-token--hooks token (cons callback callbacks))))
    ;; If token is already cancelled, run callback immediately (asynchronously)
    (log! :debug "concur-cancel-token-on-cancel: Token %S already cancelled, invoking callback immediately." token)
    (run-at-time 0 nil (lambda () (ignore-errors (funcall callback))))))

;;;###autoload
(defun concur-cancel-token-unregister (token &optional callback)
  "Unregister a specific CALLBACK from TOKEN, or TOKEN entirely from active registry.

If CALLBACK is provided, only that specific callback is removed from the token's hooks.
If CALLBACK is omitted, the TOKEN itself is removed from the active token registry
and all its associated hooks are cleared. This effectively cleans up the token
from the system, assuming it's no longer needed.

Arguments:
  - TOKEN: The `concur-cancel-token` to unregister from.
  - CALLBACK: Optional. The specific function to remove from the token's callbacks.

Returns: Non-nil if successful, nil otherwise.

Throws:
  - An error if TOKEN is not a valid `concur-cancel-token` object."
  (unless (concur-cancel-token-p token)
    (error "concur-cancel-token-unregister: Invalid cancel token object: %S" token))

  (if callback
      (progn
        (unless (functionp callback)
          (error "concur-cancel-token-unregister: CALLBACK must be a function, but got %S" callback))
        (log! :debug "concur-cancel-token-unregister: Unregistering specific callback %S from token %S."
              callback (concur-cancel-token--get-name token))
        (let* ((current-callbacks (ht-get concur-cancel-token--hooks token))
               (new-callbacks (-remove (lambda (cb) (eq cb callback)) current-callbacks)))
          (if (< (length new-callbacks) (length current-callbacks))
              (progn
                (if (null new-callbacks)
                    (ht-remove! concur-cancel-token--hooks token) ; Remove entry if no callbacks left
                  (ht-set! concur-cancel-token--hooks token new-callbacks))
                t)
            nil)))
    (progn
      (log! :info "concur-cancel-token-unregister: Unregistering token %S (name: %S) completely."
            token (concur-cancel-token--get-name token))
      ;; Remove all hooks associated with this token
      (ht-remove! concur-cancel-token--hooks token)
      ;; Remove the token from the active registry
      (ht-remove! concur-cancel-token--active-tokens token)
      t)))

(provide 'concur-cancel)
;;; concur-cancel.el ends here








