;;; concur-cancel.el --- Concurrency primitives for cancellation -*- lexical-binding: t; -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Maintainer: Christian White <christiantwhite@protonmail.com>
;; Created: June 1, 2025
;; Version: 0.3.2
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5") (ht "2.3") (scribe "0.3"))
;; Homepage: https://github.com/ctwhite/concur.el
;; Keywords: concurrency, async, cancel, token
;;
;;; Commentary:
;;
;; This library defines concurrency primitives for handling the cancellation
;; of asynchronous tasks within the `concur.el` ecosystem. It provides the
;; infrastructure for creating cancel tokens, associating them with tasks,
;; signaling cancellation, and registering callbacks to be invoked when a
;; task is canceled.
;;
;; Asynchronous tasks can cooperatively check their associated cancel token
;; using `concur:cancel-token-active?` or `concur:cancel-token-check` and
;; should terminate their execution if the token has been canceled. This
;; mechanism allows tasks to be interrupted safely and efficiently.
;;
;; Core Components:
;; - `concur-cancel-token` (struct): Represents a cancel token.
;;   Each token can be marked as inactive (canceled).
;; - `concur:make-cancel-token` (formerly `concur:cancel-token-create`):
;;   Creates a new, active cancel token.
;; - `concur:cancel-token-cancel`: Signals cancellation for a token, marks it
;;   inactive, and invokes its registered cancellation callbacks.
;; - `concur:cancel-token-active?`: Checks if a token is still active (not canceled).
;; - `concur:cancel-token-check`: A utility to check token activity and log if canceled.
;; - `concur:cancel-token-on-cancel`: Registers a callback function to be
;;   invoked when a specific token is canceled.
;; - `concur:cancel-token-unregister`: Removes a token from the active registry
;;   and clears its associated hooks, useful for cleanup when a token is no
;;   longer needed and hasn't been canceled.
;;
;; This system is designed to be flexible, allowing for robust task cancellation
;; and the handling of cancellation events through registered callbacks.

;;; Code:

(require 'cl-lib)
(require 'ht)            ; For hash tables
(require 'scribe nil t)  ; Optional scribe for logging

;; Ensure `log!` is available if scribe isn't fully loaded/configured.
(unless (fboundp 'log!)
  (defun log! (level format-string &rest args)
    "Placeholder logging function if scribe's log! is not available."
    (apply #'message (concat "CONCUR-CANCEL-LOG [" (if (keywordp level) (symbol-name level) (format "%S" level)) "]: " format-string) args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Internal Structs                           ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (concur-cancel-token
               (:constructor nil) ; Prevent direct use of cl-defstruct constructor
               (:constructor concur--cancel-token-create-internal (&key active name data))) ; Internal constructor
  "Represents a token that can be used to signal cancellation to asynchronous operations.
Tasks associated with a cancel token should periodically check its status and
terminate gracefully if cancellation has been requested.

Fields:
`active`  (boolean): t if the token is active (operation should continue),
          nil if cancelled.
`name`    (string, optional): A human-readable name for debugging.
`data`    (plist, optional): Arbitrary data associated with the token."
  active
  name
  data)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Global Registries                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar concur--cancel-token-active-tokens (ht-create)
  "Registry mapping currently active (uncanceled and not unregistered) cancel tokens to t.
This helps in tracking tokens that are still potentially in use.")

(defvar concur--cancel-token-hooks (ht-create)
  "Hash table mapping cancel tokens to a list of cancellation callback functions.
These callbacks are invoked when the associated token is canceled via `concur:cancel-token-cancel`.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Internal Helpers                           ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun concur--cancel-token-get-name (token)
  "Internal helper to return a human-readable name for the cancel TOKEN.
If the token has a `name` field, return that; otherwise, generate a unique name
based on its object hash for identification."
  (if (concur-cancel-token-p token)
      (or (concur-cancel-token-name token)
          (format "cancel-token-%s" (sxhash token)))
    "invalid-token"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Public API                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:make-cancel-token (&optional name data)
  "Create and return a new, active cancel token.
The token is automatically registered in an internal registry of active tokens.
This function is analogous to `concur:make-promise`.

Arguments:
  NAME (string, optional): A human-readable name for the token (for debugging).
  DATA (plist, optional): Additional data to associate with the token.

Returns:
  A new `concur-cancel-token` struct, initialized with `:active t`."
  (let ((token (concur--cancel-token-create-internal :active t :name name :data data)))
    (log! :info "concur:make-cancel-token: Creating cancel token: %S (name: %S)."
          token (concur--cancel-token-get-name token))
    (ht-set! concur--cancel-token-active-tokens token t)
    token))

;;;###autoload
(defun concur:cancel-token-cancel (token)
  "Cancel the given TOKEN, marking it as inactive, and invoke registered callbacks.
If the token is already inactive, this function does nothing.
Callbacks are invoked once and then cleared for the token.
The token is removed from the active tokens registry.

Arguments:
  TOKEN (concur-cancel-token): The cancel token to cancel.

Side Effects:
  - Sets the `:active` field of TOKEN to nil.
  - Invokes all registered cancellation callbacks for TOKEN.
  - Clears callbacks for TOKEN and removes it from active registry.

Throws:
  - An error if TOKEN is not a valid `concur-cancel-token` object."
  (unless (concur-cancel-token-p token)
    (error "concur:cancel-token-cancel: Invalid cancel token object: %S" token))

  (if (concur-cancel-token-active token) ; Check if it's currently active
      (progn
        (log! :info "concur:cancel-token-cancel: Canceling token: %S (name: %S)."
              token (concur--cancel-token-get-name token))
        (setf (concur-cancel-token-active token) nil) ; Mark as inactive

        (let ((callbacks (ht-get concur--cancel-token-hooks token)))
          (when callbacks
            (log! :debug "concur:cancel-token-cancel: Invoking %d callbacks for token %S."
                  (length callbacks) (concur--cancel-token-get-name token))
            (mapc (lambda (fn)
                    (condition-case err
                        (funcall fn)
                      (error (log! :error "concur:cancel-token-cancel: Callback for token %S failed: %S."
                                   (concur--cancel-token-get-name token) err :trace))))
                  (copy-sequence callbacks)) 
            (ht-remove! concur--cancel-token--hooks token)))
        (ht-remove! concur--cancel-token-active-tokens token))
    (log! :debug "concur:cancel-token-cancel: Token %S (name: %S) already cancelled. No-op."
          token (concur--cancel-token-get-name token))))

;;;###autoload
(defun concur:cancel-token-active? (token)
  "Check if the cancel TOKEN is still active (i.e., not canceled).
Returns t if the token is active, nil if canceled or if TOKEN is invalid."
  (unless (concur-cancel-token-p token)
    (log! :warn "concur:cancel-token-active?: Invalid cancel token object: %S. Returning nil." token)
    (cl-return-from concur:cancel-token-active? nil))
  (concur-cancel-token-active token))

;;;###autoload
(defun concur:cancel-token-check (token)
  "Check if TOKEN is canceled. Log and return t if canceled, else nil.
This is a convenience function for tasks to poll for cancellation.

Arguments:
  TOKEN (concur-cancel-token): The cancel token to check.

Returns:
  t if the token is canceled (task should typically terminate).
  nil if the token is active (task can continue).

Throws:
  An error if TOKEN is not a valid `concur-cancel-token` object."
  (unless (concur-cancel-token-p token)
    (error "concur:cancel-token-check: Invalid cancel token object: %S" token))

  (if (not (concur:cancel-token-active? token))
      (progn
        (log! :info "concur:cancel-token-check: Task canceled due to token %S (name: %S)."
              token (concur--cancel-token-get-name token))
        t)
    nil))

;;;###autoload
(defun concur:cancel-token-on-cancel (token callback)
  "Register CALLBACK to be run when TOKEN is canceled.
CALLBACK is a zero-argument function.
If TOKEN is already cancelled, CALLBACK is run immediately (asynchronously).
Callbacks are deduplicated based on `eq` identity.

Arguments:
  TOKEN (concur-cancel-token): The token to monitor.
  CALLBACK (function): The function to call upon cancellation.

Side Effects:
  Adds CALLBACK to TOKEN's list of cancellation hooks.

Throws:
  An error if TOKEN is not a valid `concur-cancel-token` or CALLBACK is not a function."
  (unless (concur-cancel-token-p token)
    (error "concur:cancel-token-on-cancel: Invalid cancel token object: %S" token))
  (unless (functionp callback)
    (error "concur:cancel-token-on-cancel: CALLBACK must be a function, got %S" callback))

  (log! :debug "concur:cancel-token-on-cancel: Registering cancel callback for token: %S (name: %S)."
        token (concur--cancel-token-get-name token))

  (if (concur:cancel-token-active? token)
      (let* ((callbacks (ht-get concur--cancel-token--hooks token))
             (already-registered (member callback callbacks)))
        (unless already-registered
          (ht-set! concur--cancel-token--hooks token (cons callback callbacks))))
    (log! :debug "concur:cancel-token-on-cancel: Token %S already cancelled, invoking callback immediately."
          (concur--cancel-token-get-name token))
    (run-at-time 0 nil (lambda () (ignore-errors (funcall callback))))))

;;;###autoload
(defun concur:cancel-token-unregister (token &optional callback)
  "Unregister CALLBACK from TOKEN, or unregister TOKEN entirely.
If CALLBACK is provided, only that specific callback is removed.
If CALLBACK is nil, TOKEN is removed from the active token registry
and all its associated hooks are cleared. This is for explicit cleanup
if a token is no longer needed and hasn't been (or won't be) canceled.

Arguments:
  TOKEN (concur-cancel-token): The token to unregister from.
  CALLBACK (function, optional): The specific callback to remove.

Returns:
  t if a callback was removed or the token was fully unregistered, nil otherwise.

Throws:
  An error if TOKEN is not valid or if CALLBACK (if given) is not a function."
  (unless (concur-cancel-token-p token)
    (error "concur:cancel-token-unregister: Invalid cancel token object: %S" token))

  (if callback
      (progn
        (unless (functionp callback)
          (error "concur:cancel-token-unregister: CALLBACK must be a function, got %S" callback))
        (log! :debug "concur:cancel-token-unregister: Unregistering specific callback from token %S."
              (concur--cancel-token-get-name token))
        (let* ((current-callbacks (ht-get concur--cancel-token--hooks token))
               (new-callbacks (-remove (lambda (cb) (eq cb callback)) current-callbacks)))
          (if (< (length new-callbacks) (length current-callbacks)) 
              (progn
                (if (null new-callbacks)
                    (ht-remove! concur--cancel-token--hooks token)
                  (ht-set! concur--cancel-token--hooks token new-callbacks))
                t) 
            (progn
              (log! :debug "concur:cancel-token-unregister: Callback not found on token %S."
                    (concur--cancel-token-get-name token))
              nil)))) 
    (progn
      (log! :info "concur:cancel-token-unregister: Unregistering token %S (name: %S) completely."
            token (concur--cancel-token-get-name token))
      (ht-remove! concur--cancel-token--hooks token)
      (ht-remove! concur--cancel-token-active-tokens token)
      t)))

(provide 'concur-cancel)
;;; concur-cancel.el ends here