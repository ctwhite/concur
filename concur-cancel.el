;;; concur-cancel.el --- Primitives for Cooperative Cancellation -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides primitives for the cooperative cancellation of
;; asynchronous tasks. The core component is the `concur-cancel-token`, a
;; thread-safe object that can be passed to asynchronous operations.
;;
;; Tasks can periodically check their token's status and should terminate
;; gracefully if cancellation has been signaled. Callbacks can also be
;; registered to execute clean-up logic upon cancellation.
;;
;; Core Components:
;; - `concur-cancel-token`: A self-contained, thread-safe object representing
;;   a cancellation signal.
;; - `concur:make-cancel-token`: Creates a new cancel token.
;; - `concur:cancel-token-cancel`: Signals cancellation on a token.
;; - `concur:cancel-token-cancelled-p`: Checks if a token is cancelled.
;; - `concur:cancel-token-add-callback`: Registers a function to run on cancellation.
;; - `concur:throw-if-cancelled!`: A function for cooperative cancellation points.
;; - `concur:cancel-token-linked`: Creates a token that is chained to a source token.

;;; Code:

(require 'cl-lib)
(require 'concur-log)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-cancel-error
  "A promise or task was cancelled."
  'concur-error)

(define-error 'concur-cancel-invalid-token-error
  "An operation was attempted on an invalid cancel token."
  'concur-type-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-cancel-token (:constructor %%make-cancel-token))
  "Represents a token for signaling cancellation to async operations.
This is a self-contained, thread-safe object.

Fields:
- `cancelled-p` (boolean): `t` if the token has been canceled.
- `name` (string): An optional, human-readable name for debugging.
- `callbacks` (list): A list of `concur-cancel-callback-info` structs.
- `lock` (concur-lock): A mutex protecting the `cancelled-p` and `callbacks`
  fields from concurrent access.
- `data` (any): Optional, arbitrary data to associate with the token."
  (cancelled-p nil :type boolean)
  (name "" :type string)
  (callbacks '() :type list)
  (lock (concur:make-lock) :type concur-lock)
  (data nil))

(cl-defstruct (concur-cancel-callback-info
               (:constructor %%make-cancel-callback-info))
  "Encapsulates a registered cancellation callback and its dispatcher.

Fields:
- `callback` (function): The zero-argument function to call on cancellation.
- `dispatcher` (function or nil): An optional function `(lambda (callback))`
  used to schedule the `callback` for asynchronous execution."
  (callback nil :type function)
  (dispatcher nil :type (or function null)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-token (token function-name)
  "Signal an error if TOKEN is not a `concur-cancel-token`.

Arguments:
- `TOKEN` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
  (unless (concur-cancel-token-p token)
    (signal 'concur-cancel-invalid-token-error
            (list (format "%s: Invalid cancel token" function-name) token))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:make-cancel-token (&optional name data)
  "Create and return a new, active cancel token.

Arguments:
- `NAME` (string, optional): A human-readable name for debugging.
- `DATA` (any, optional): Additional data to associate with the token.

Returns:
- (concur-cancel-token): A new, active cancel token."
  (let* ((token-name (or name ""))
         (token (%%make-cancel-token :name token-name
                                     :data data
                                     :lock (concur:make-lock
                                            (format "cancel-lock-%s"
                                                    token-name)))))
    (concur--log :debug nil "Created cancel token: %S"
                 (or name (format "token-%s" (sxhash token))))
    token))

;;;###autoload
(defun concur:cancel-token-cancelled-p (token)
  "Check if the cancel TOKEN has been canceled.

Arguments:
- `TOKEN` (concur-cancel-token): The token to check.

Returns:
- (boolean): `t` if the token has been cancelled, `nil` otherwise."
  (concur--validate-token token 'concur:cancel-token-cancelled-p)
  (concur-cancel-token-cancelled-p token))

;;;###autoload
(defun concur:throw-if-cancelled! (token)
  "Check if TOKEN is cancelled and signal a `concur-cancel-error` if so.
This function provides a cooperative cancellation point for long-running
Lisp tasks. It should be placed inside loops or between computational
steps to allow a task to be gracefully terminated.

Arguments:
- `TOKEN` (concur-cancel-token): The cancellation token to check.

Returns:
- `nil` if the token is not cancelled.

Signals:
- `concur-cancel-error` if the token has been cancelled."
  (concur--validate-token token 'concur:throw-if-cancelled!)
  (when (concur:cancel-token-cancelled-p token)
    (signal 'concur-cancel-error
            (list (concur:make-error
                   :type :cancel
                   :message (format "Task cancelled by token %S"
                                    (concur-cancel-token-name token))
                   :cause token)))))

;;;###autoload
(defun concur:cancel-token-cancel (token)
  "Cancel TOKEN and invoke all registered callbacks asynchronously.
This function is idempotent; it does nothing if the token is already canceled.

Arguments:
- `TOKEN` (concur-cancel-token): The token to cancel.

Returns:
- (boolean): `t` if the token was canceled now, `nil` if already canceled."
  (concur--validate-token token 'concur:cancel-token-cancel)
  (let (was-active-now-cancelled callbacks-to-run)
    (concur:with-mutex! (concur-cancel-token-lock token)
      (unless (concur-cancel-token-cancelled-p token)
        (setq was-active-now-cancelled t)
        (setf (concur-cancel-token-cancelled-p token) t)
        (setq callbacks-to-run (concur-cancel-token-callbacks token))
        (setf (concur-cancel-token-callbacks token) '())))

    (when was-active-now-cancelled
      (concur--log :info nil "Canceling token: %S"
                   (concur-cancel-token-name token))
      (dolist (info callbacks-to-run)
        (let ((fn (concur-cancel-callback-info-callback info))
              (dispatcher (concur-cancel-callback-info-dispatcher info)))
          (condition-case err
              (if dispatcher (funcall dispatcher fn) (run-at-time 0 nil fn))
            (error
             (concur--log :error nil "Cancel callback failed for token %S: %S"
                          (concur-cancel-token-name token) err))))))
    was-active-now-cancelled))

;;;###autoload
(cl-defun concur:cancel-token-add-callback (token callback &key dispatcher)
  "Register CALLBACK to be run when TOKEN is canceled.
If TOKEN is already canceled, the CALLBACK is scheduled immediately.

Arguments:
- `TOKEN` (concur-cancel-token): The token to monitor.
- `CALLBACK` (function): A zero-argument function to call upon cancellation.
- `:DISPATCHER` (function, optional): A function `(lambda (callback))`
  to schedule the callback. Defaults to `run-at-time 0 nil`.

Returns:
- `nil`."
  (concur--validate-token token 'concur:cancel-token-add-callback)
  (unless (functionp callback)
    (error "CALLBACK must be a function: %S" callback))
  (when (and dispatcher (not (functionp dispatcher)))
    (error "DISPATCHER must be a function: %S" dispatcher))

  (if (concur:cancel-token-cancelled-p token)
      (if dispatcher (funcall dispatcher callback) (run-at-time 0 nil callback))
    (concur:with-mutex! (concur-cancel-token-lock token)
      ;; Check again inside lock in case of race condition.
      (if (concur-cancel-token-cancelled-p token)
          (if dispatcher (funcall dispatcher callback) (run-at-time 0 nil callback))
        (let ((info (%%make-cancel-callback-info :callback callback
                                                 :dispatcher dispatcher)))
          ;; Avoid adding the same callback function multiple times.
          (cl-pushnew info (concur-cancel-token-callbacks token)
                      :key #'concur-cancel-callback-info-callback
                      :test #'eq))))))

;;;###autoload
(defun concur:cancel-token-remove-callback (token callback)
  "Unregister a specific CALLBACK from TOKEN.
This is used for explicit cleanup if a task completes successfully and no
longer needs to listen for cancellation.

Arguments:
- `TOKEN` (concur-cancel-token): The token to unregister from.
- `CALLBACK` (function): The specific callback function to remove.

Returns:
- (boolean): `t` if the callback was found and removed, `nil` otherwise."
  (concur--validate-token token 'concur:cancel-token-remove-callback)
  (let (removed-p)
    (concur:with-mutex! (concur-cancel-token-lock token)
      (let* ((hooks (concur-cancel-token-callbacks token))
             (new-hooks (cl-delete
                         callback hooks
                         :key #'concur-cancel-callback-info-callback
                         :test #'eq)))
        (when (< (length new-hooks) (length hooks))
          (setq removed-p t)
          (setf (concur-cancel-token-callbacks token) new-hooks))))
    removed-p))

;;;###autoload
(defun concur:cancel-token-linked (source-token &optional name data)
  "Create a new token that is cancelled when `SOURCE-TOKEN` is cancelled.
This is useful for propagating cancellation signals down a task hierarchy.

Arguments:
- `SOURCE-TOKEN` (concur-cancel-token): The token to chain from.
- `NAME` (string, optional): A descriptive name for the new token.
- `DATA` (any, optional): Additional data for the new token.

Returns:
- (concur-cancel-token): The new linked cancel token."
  (concur--validate-token source-token 'concur:cancel-token-linked)
  (let ((new-token (concur:make-cancel-token name data)))
    (concur:cancel-token-add-callback
     source-token
     (lambda () (concur:cancel-token-cancel new-token)))
    new-token))

;;;###autoload
(defun concur:cancel-token-link-promise (token promise)
  "Link a TOKEN to a PROMISE, cancelling TOKEN when PROMISE settles.
This automatically manages the token's lifecycle based on the
promise's completion (either resolved or rejected).

Arguments:
- `TOKEN` (concur-cancel-token): The token to cancel.
- `PROMISE` (concur-promise): The promise to link.

Returns:
- (concur-cancel-token): The `TOKEN` that was linked."
  (concur--validate-token token 'concur:cancel-token-link-promise)
  (unless (concur-promise-p promise)
    (error "Argument must be a concur-promise: %S" promise))
  (concur:then promise
               (lambda (_) (concur:cancel-token-cancel token))
               (lambda (_) (concur:cancel-token-cancel token)))
  token)

(provide 'concur-cancel)
;;; concur-cancel.el ends here