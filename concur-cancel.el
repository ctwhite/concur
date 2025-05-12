;;; concur-cancel.el --- Concurrency primitives for cancellation ---
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
;; - `concur-cancel-token`: A structure representing a cancel token. Each token is associated
;;   with a specific task and can be marked as active to indicate that the task should be canceled.
;; 
;; - `concur--cancel-token-table`: A hash table that maps cancel tokens to their associated tasks.
;; 
;; - `concur--cancel-token-hooks`: A hash table mapping cancel tokens to a list of callback
;;   functions that will be invoked when the token is canceled.
;;
;; Functions in this file include:
;; - `concur-cancel-register-token`: Registers a cancel token with a task.
;; - `concur-cancel-remove-token`: Removes a cancel token from the registry.
;; - `concur-cancel-get-task`: Retrieves the task associated with a cancel token.
;; - `concur-cancel-token-on-cancel`: Registers a callback to be invoked when a token is canceled.
;;
;; This system is designed to be flexible, allowing for easy task cancellation and the handling
;; of cancellation events through registered callbacks.
;;
;;; Code:

(require 'cl-lib)
(require 'ht)

(cl-defstruct concur-cancel-token
  "A structure representing a cancel token that can be used to cancel asynchronous tasks.

Fields:
  - active: A boolean value indicating whether the cancel token is active. If `active` is 
      non-nil, tasks associated with this token can be canceled.
  - name: An optional human-readable name for the cancel token, which can be useful for 
      debugging or logging purposes.

The `concur-cancel-token` struct is used to signal cancellation for tasks. If a task checks 
for cancellation and finds that its associated cancel token is active, it can halt execution early."
  active
  name)

(defvar concur--cancel-token-table (ht)
  "Registry mapping cancel tokens to their associated tasks.")

(defvar concur--cancel-token-hooks (ht)
  "Hash table mapping cancel tokens to a list of cancel callbacks.")

(defun concur-cancel-register-token (token task)
  "Associate TOKEN with TASK in the cancel token registry."
  (ht-set! concur--cancel-token-table token task))

(defun concur-cancel-remove-token (token)
  "Remove TOKEN from the cancel token registry."
  (ht-remove! concur--cancel-token-table token))

;;;###autoload
(defun concur-cancel-token-create (&optional name)
  "Create and return a new cancel token. 
This function creates a new cancel token and marks it as active by default.
The token is automatically registered for cancellation.
Returns:
  A cancel token struct, initialized with an `:active` field set to t."
  (let ((token (make-concur-cancel-token :active t :name name)))
    ;; Register the token as soon as it is created
    (concur-cancel-register-token token)
    token))

;;;###autoload
(defun concur-cancel-token-cancel (token)
  "Cancel the given TOKEN, marking it as inactive, and notify all registered observers.
This function sets the cancel token's `:active` field to nil to indicate the task
associated with this token should be canceled.

Arguments:
  - token: The cancel token to cancel. Should be a valid cancel token object.
  
Side Effects:
  - Sets the `:active` field of the token to nil, marking it as canceled.
  
Error Handling:
  - Signals an error if the token is not a valid cancel token."
  (setf (concur-cancel-token-active token) nil)
  (let ((callbacks (ht-get concur--cancel-token-hooks token)))
    (mapc (lambda (fn)
            (condition-case err
                (funcall fn)
              (error (log! "Cancel callback error: %S" err :level :error))))
          callbacks)
    ;; Optionally remove hooks to avoid leaks
    (ht-remove! concur--cancel-token-hooks token)))

;;;###autoload
(defun concur-cancel-token-active-p (token)
  "Check if the cancel TOKEN is still active (i.e., not canceled).
This function checks the `:active` field of the token to determine if the task
associated with this token should still be active.

Arguments:
  - token: The cancel token to check. Should be a valid cancel token object.
  
Returns:
  - t if the token is active (not canceled).
  - nil if the token is canceled or invalid."
  (if (not token)
      (error "Invalid token: nil"))
  (concur-cancel-token-active token))

;;;###autoload
(defun concur-cancel-token-check (token)
  "Check if the task should be canceled by evaluating the cancel TOKEN.
If the token is canceled, this function logs the cancellation and returns `t` to
indicate that the task should be canceled. If the token is still active, it returns `nil`.

Arguments:
  - token: The cancel token to check.
  
Returns:
  - t if the token is canceled (task should be canceled).
  - nil if the token is active (task should continue)."
  (if (not (concur-cancel-token-active-p token))
      (progn
        (log! "Task canceled due to token %s." (concur-cancel-token-name token))
        t)  ;; Return t to indicate cancellation
    nil))  ;; Return nil if the task is still active

(defun concur-cancel-token-name (token)
  "Return a human-readable name for the cancel TOKEN.
If the token contains a `:name` field, return that; otherwise, generate a unique name."
  (or (plist-get (concur-cancel-token-data token) :name)
      (symbol-name (gensym "cancel-token-"))))

;;;###autoload
(defun concur-cancel-token-on-cancel (token callback)
  "Register CALLBACK to be run when TOKEN is canceled.
Deduplicates based on `eq` identity of CALLBACK."
  (let* ((callbacks (ht-get concur--cancel-token-hooks token))
         (already-registered (member callback callbacks)))
    (unless already-registered
      (ht-set! concur--cancel-token-hooks token (cons callback callbacks)))))

(provide 'concur-cancel)
;;; concur-cancel.el ends here