;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-cancel.el --- Concurrency primitives for cancellation -*- lexical-binding: t; -*-

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
;; - `concur:cancel-token-linked`: Creates a token that cancels when another
;;   token cancels.
;; - `concur:cancel-token-link-promise`: Links a token to a promise, canceling
;;   the token when the promise settles.

;;; Code:

(require 'cl-lib)        ; For cl-defstruct, cl-delete, cl-loop
;; No longer requires ht.el for hash table operations.
(require 'concur-log)    ; For `concur--log`
(require 'concur-core)   ; For `define-error`, `concur-error`, `concur-promise-p`,
                         ; `concur:make-error`, `concur:then`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Structs and Errors

(define-error 'concur-cancel-error
  "A promise or task was cancelled."
  'concur-error)

(eval-and-compile
  (cl-defstruct (concur-cancel-token (:constructor %%make-cancel-token))
    "Represents a token for signaling cancellation to async operations.

  Arguments:
  - `cancelled-p` (boolean): `t` if the token has been canceled. Defaults
    to `nil`.
  - `name` (string): An optional, human-readable name for debugging.
    Defaults to \"\".
  - `data` (any): Optional, arbitrary data to associate with the token.
    Defaults to `nil`."
    (cancelled-p nil :type boolean)
    (name "" :type string)
    (data nil)))

(eval-and-compile
  (cl-defstruct (concur-cancel-callback-info
                 (:constructor %%make-cancel-callback-info))
    "Encapsulates information about a registered cancellation callback.

  Arguments:
  - `callback` (function): The actual zero-argument function to call.
  - `dispatcher` (function or nil): An optional function `(lambda (callback))`
    that will be used to schedule the `callback`. If `nil`, `run-at-time 0`
    is used for asynchronous dispatch. Defaults to `nil`."
    (callback nil :type function)
    (dispatcher nil :type (or function null))))

(defvar concur--cancel-token-callbacks-map (make-hash-table :test #'eq)
  "Global hash table mapping cancel tokens to their cancellation callbacks.
The key is a `concur-cancel-token` and the value is a list of
`concur-cancel-callback-info` structs. This map stores pending
cancellation callbacks.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(defun concur:make-cancel-token (&optional name data)
  "Create and return a new, active cancel token.

  Arguments:
  - `NAME` (string, optional): A human-readable name for debugging.
  - `DATA` (any, optional): Additional data to associate with the token.

  Returns:
  - (concur-cancel-token): A new cancel token, initialized as active."
  (let ((token (%%make-cancel-token :name (or name "") :data data)))
    (when (fboundp 'concur--log)
      (concur--log :debug nil "Created cancel token: %S"
                   (or name (format "token-%s" (sxhash token)))))
    token))

;;;###autoload
(defun concur:cancel-token-cancelled-p (token)
  "Check if the cancel TOKEN has been canceled.

  Arguments:
  - `TOKEN` (concur-cancel-token): The token to check.

  Returns:
  - (boolean): `t` if the token is valid and has been cancelled, `nil`
    otherwise. Signals an error if `TOKEN` is not a `concur-cancel-token`."
  (unless (concur-cancel-token-p token)
    (user-error "concur:cancel-token-cancelled-p: Invalid cancel token: %S"
                token))
  (concur-cancel-token-cancelled-p token))

;;;###autoload
(defun concur:throw-if-cancelled! (token)
  "Check if TOKEN is cancelled and signal a `concur-cancel-error` if so.
This function provides a cooperative cancellation point for long-running
Lisp tasks. It should be placed inside loops or between computational steps
to allow a task to be gracefully terminated.

  Arguments:
  - `TOKEN` (concur-cancel-token): The cancellation token to check.

  Returns:
  - `nil` if the token is not cancelled.

  Signals:
  - `concur-cancel-error`: if the token has been cancelled."
  (unless (concur-cancel-token-p token)
    (user-error "concur:throw-if-cancelled!: Invalid cancel token: %S" token))
  (when (concur:cancel-token-cancelled-p token)
    (signal 'concur-cancel-error
            (list (concur:make-error :type :cancel
                                     :message (format "Task cancelled by token %S."
                                                      (concur-cancel-token-name token))
                                     :cause token)))))

;;;###autoload
(defun concur:cancel-token-cancel! (token)
  "Cancel TOKEN, mark it inactive, and invoke all registered callbacks.
This function is idempotent; it does nothing if the token is already canceled.
Callbacks are dispatched asynchronously to prevent blocking.

  Arguments:
  - `TOKEN` (concur-cancel-token): The token to cancel.

  Returns:
  - (boolean): `t` if the token was successfully canceled now, `nil` if it was
    already canceled or invalid."
  (unless (concur-cancel-token-p token)
    (user-error "concur:cancel-token-cancel!: Invalid cancel token: %S" token))
  (if (concur:cancel-token-cancelled-p token)
      nil ; Already canceled
    (when (fboundp 'concur--log)
      (concur--log :info nil "Canceling token: %S"
                   (concur-cancel-token-name token)))
    (setf (concur-cancel-token-cancelled-p token) t)

    ;; Invoke and clear all associated callbacks.
    (when-let ((callback-infos
                (gethash concur--cancel-token-callbacks-map token)))
      (remhash token concur--cancel-token-callbacks-map) ; Clear callbacks
      (dolist (info callback-infos)
        (let ((fn (concur-cancel-callback-info-callback info))
              (dispatcher (concur-cancel-callback-info-dispatcher info)))
          ;; Each callback is wrapped in condition-case to prevent one from
          ;; halting others, and dispatched asynchronously.
          (condition-case err 
              (if (functionp dispatcher)
                  (funcall dispatcher fn)
                (run-at-time 0 nil fn))
            (error
             (when (fboundp 'concur--log)
               (concur--log :error nil "Cancel callback failed for token %S: %S"
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
    that will be used to schedule the `callback`. If `nil`, `run-at-time 0`
    is used for asynchronous dispatch.

  Returns:
  - `nil` (side-effect: adds callback or schedules it)."
  (unless (concur-cancel-token-p token)
    (user-error "concur:cancel-token-add-callback: Invalid cancel token: %S"
                token))
  (unless (functionp callback)
    (user-error "concur:cancel-token-add-callback: CALLBACKS must be a function: %S"
                callback))
  ;; Validate dispatcher if provided
  (when (and dispatcher (not (functionp dispatcher)))
    (user-error "concur:cancel-token-add-callback: DISPATCHER must be a function: %S"
                dispatcher))

  (if (concur:cancel-token-cancelled-p token)
      ;; Token is already canceled, schedule the callback asynchronously.
      (if (functionp dispatcher)
          (funcall dispatcher callback)
        (run-at-time 0 nil callback))
    ;; Token is active, add the info struct if not already present.
    (let ((info (%%make-cancel-callback-info :callback callback
                                             :dispatcher dispatcher))
          (hooks (gethash concur--cancel-token-callbacks-map token)))
      ;; Avoid adding the same callback function multiple times.
      (unless (member callback hooks
                      :key #'concur-cancel-callback-info-callback)
        (puthash token (cons info hooks)
                 concur--cancel-token-callbacks-map)))))

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
  - (boolean): `t` if a change was made (callback/token was removed),
    `nil` otherwise. Signals an error if `TOKEN` is invalid."
  (unless (concur-cancel-token-p token)
    (user-error "concur:cancel-token-unregister: Invalid cancel token: %S"
                token))
  (if callback
      ;; Remove a specific callback info struct.
      (when-let ((hooks (gethash concur--cancel-token-callbacks-map token)))
        (let ((new-hooks
               (cl-delete callback hooks
                          :key #'concur-cancel-callback-info-callback)))
          (if (null new-hooks)
              (remhash token concur--cancel-token-callbacks-map)
            (puthash token new-hooks concur--cancel-token-callbacks-map))
          ;; Return t if the list of hooks has shrunk.
          (< (length new-hooks) (length hooks))))
    ;; Unregister the token and all its hooks completely.
    (remhash token concur--cancel-token-callbacks-map)))

;;;###autoload
(defun concur:cancel-token-linked (source-token &optional name data)
  "Create a new cancel token that gets cancelled if `SOURCE-TOKEN` is cancelled.
This is useful for propagating cancellation signals down a hierarchy of tasks.

  Arguments:
  - `SOURCE-TOKEN` (concur-cancel-token): The token whose cancellation will
    trigger the new token's cancellation.
  - `NAME` (string, optional): A descriptive name for the new token.
  - `DATA` (any, optional): Additional data for the new token.

  Returns:
  - (concur-cancel-token): The newly created linked cancel token."
  (unless (concur-cancel-token-p source-token)
    (user-error "concur:cancel-token-linked: Invalid SOURCE-TOKEN: %S"
                source-token))
  (let ((new-token (concur:make-cancel-token name data)))
    (concur:cancel-token-add-callback
     source-token
     (lambda () (concur:cancel-token-cancel! new-token)))
    new-token))

;;;###autoload
(defun concur:cancel-token-link-promise (token promise)
  "Link a `TOKEN` to a `PROMISE`, so that `TOKEN` is cancelled when `PROMISE` settles.
This is useful for automatically cleaning up resources associated with a token
when the primary task (`PROMISE`) it controls finishes.

  Arguments:
  - `TOKEN` (concur-cancel-token): The token to cancel.
  - `PROMISE` (concur-promise): The promise to link.

  Returns:
  - (concur-cancel-token): The `TOKEN` that was linked."
  (unless (concur-cancel-token-p token)
    (user-error "concur:cancel-token-link-promise: Invalid TOKEN: %S" token))
  (unless (concur-promise-p promise)
    (user-error "concur:cancel-token-link-promise: Invalid PROMISE: %S" promise))
  (concur:then promise
               (lambda (_) (concur:cancel-token-cancel! token "Promise settled"))
               (lambda (_) (concur:cancel-token-cancel! token "Promise settled")))
  token)

(provide 'concur-cancel)
;;; concur-cancel.el ends here