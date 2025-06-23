;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-registry.el --- Concur Promise Registry for Introspection -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides a global registry for `concur-promise` objects.
;; When enabled, it tracks all promises created and their state changes,
;; offering powerful introspection and debugging capabilities for complex
;; asynchronous workflows.
;;
;; Architectural Highlights:
;; - Global Hash Table: `concur--promise-registry` stores promises by ID.
;; - State Metadata: `concur-promise-meta` captures rich context like
;;   parent/child relationships, status history, and resources held.
;; - Lifecycle Hooks: Integrates with `concur-core.el` for seamless updates.
;; - Debugging Aids: Provides functions to list, filter, and inspect promises,
;;   as well as monitor the registry's overall status.
;; - **Robust Shutdown**: On Emacs exit, pending promises can be automatically
;;   rejected to prevent orphaned operations.

;;; Code:

(require 'cl-lib)    ; For cl-defstruct, cl-loop, cl-delete, cl-remove, cl-incf
(require 'dash)      ; For dash functions (e.g., --map, -find-if, s-contains?)
(require 's)         ; For string utilities (e.g., s-contains?)
(require 'concur-log)  ; For `concur--log`
(require 'concur-lock) ; For `concur-lock`, `concur:make-lock`, `concur:with-mutex!`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward-Declarations

(declare-function concur:make-error "concur-core")
(declare-function concur:format-promise "concur-core")
(declare-function concur:status "concur-core")
(declare-function concur-promise-state "concur-core")
(declare-function concur:reject "concur-core")
(declare-function concur:pending-p "concur-core")
(declare-function concur-promise-p "concur-core") ; Ensure concur-promise-p is declared
(declare-function concur-promise-id "concur-core")
(declare-function concur-promise-mode "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customization and Global State

(defcustom concur-enable-promise-registry t
  "If non-nil, enable the global promise registry.
When enabled, all promises created will be tracked, allowing for
introspection and debugging via functions like `concur:dump-registry`.
Disabling this saves memory and minor processing overhead."
  :type 'boolean
  :group 'concur)

(defcustom concur-registry-shutdown-on-exit-p t
  "If non-nil, automatically reject all pending promises on Emacs exit.
This ensures a cleaner shutdown of asynchronous operations and prevents
orphaned promises or resource leaks that rely on promises resolving."
  :type 'boolean
  :group 'concur)

(defvar concur--promise-registry (make-hash-table :test 'eq)
  "Global hash table mapping promise objects to `concur-promise-meta` data.
This registry is protected by `concur--promise-registry-lock`.")

(defvar concur--promise-registry-lock
  (concur:make-lock "promise-registry-lock")
  "Mutex protecting `concur--promise-registry` for thread-safety.
All access to `concur--promise-registry` must be guarded by this lock.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct Definitions

(eval-and-compile
  (cl-defstruct (concur-promise-meta (:constructor %%make-promise-meta))
    "Metadata for a promise in the global registry.
This struct stores additional, non-core information about a promise
that is useful for debugging, without bloating the `concur-promise` struct.

  Arguments:
  - `promise` (concur-promise): The promise object this metadata describes.
  - `name` (string or nil): A human-readable name for the promise,
    if provided. Defaults to `nil`.
  - `status-history` (list): A list of status changes `(timestamp . status)`.
    Defaults to `nil`.
  - `creation-time` (float): The time the promise was created (Emacs
    `float-time`). Defaults to `(float-time)`.
  - `settlement-time` (float or nil): The time the promise settled.
    Defaults to `nil`.
  - `parent-promise` (concur-promise or nil): The promise that created
    this one (e.g., in a chain). Defaults to `nil`.
  - `children-promises` (list): Promises created by this promise (e.g.,
    in a chain via `concur:then`). Defaults to `nil`.
  - `resources-held` (list): External resources currently held by this
    promise (e.g., locks, semaphores). Defaults to `nil`.
  - `tags` (list): A list of keyword tags associated with the promise,
    for filtering and categorization. Defaults to `nil`."
    (promise nil :type (satisfies concur-promise-p))
    (name nil :type (or string null))
    (status-history nil :type list)
    (creation-time (float-time) :type float)
    (settlement-time nil :type (or float null))
    (parent-promise nil :type (or null (satisfies concur-promise-p)))
    (children-promises nil :type list)
    (resources-held nil :type list)
    (tags nil :type list)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Registry Management (Called from concur-core)

(cl-defun concur-registry-register-promise (promise name &key parent-promise tags)
  "Register a new `PROMISE` in the global registry.
Creates metadata for the promise and handles parent-child links.
This function is typically called by `concur:make-promise`.

  Arguments:
  - `PROMISE` (concur-promise): The promise to register.
  - `NAME` (string): A human-readable name for the promise.
  - `:PARENT-PROMISE` (concur-promise, optional): The promise that
    caused the creation of this `PROMISE`.
  - `:TAGS` (list, optional): A list of keywords to tag this promise.

  Returns:
  - `nil` (side-effect: registers promise, updates parent-child links)."
  (when concur-enable-promise-registry
    (unless (concur-promise-p promise)
      (user-error "concur-registry-register-promise: Invalid promise: %S"
                  promise))
    (concur:with-mutex! concur--promise-registry-lock
      (let ((meta (%%make-promise-meta :promise promise :name name
                                       :parent-promise parent-promise
                                       :tags (cl-delete-duplicates tags)))) ; Store and deduplicate tags
        (puthash promise meta concur--promise-registry)
        (push (cons (float-time) (concur-promise-state promise))
              (concur-promise-meta-status-history meta))
        (concur--log :debug (concur-promise-id promise)
                     "Registered promise '%s' (State: %S). Parent: %S. Tags: %S."
                     (concur-promise-meta-name meta)
                     (concur-promise-state promise)
                     (and parent-promise (concur-promise-id parent-promise))
                     (concur-promise-meta-tags meta))

        ;; Link as child to parent promise.
        (when (and parent-promise (concur-promise-p parent-promise))
          (when-let ((parent-meta (gethash parent-promise
                                           concur--promise-registry)))
            (push promise (concur-promise-meta-children-promises parent-meta))
            (concur--log :debug (concur-promise-id parent-promise)
                         "Added child %S to parent %S."
                         (concur-promise-id promise)
                         (concur-promise-id parent-promise))))))))

(defun concur-registry-update-promise-state (promise)
  "Update the state of `PROMISE` in the global registry when it settles.
This function is called by `concur--settle-promise` in `concur-core.el`.

  Arguments:
  - `PROMISE` (concur-promise): The promise whose state has changed.

  Returns:
  - `nil` (side-effect: updates promise metadata)."
  (when concur-enable-promise-registry
    (unless (concur-promise-p promise)
      (user-error "concur-registry-update-promise-state: Invalid promise: %S"
                  promise))
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (let ((current-time (float-time)))
          (setf (concur-promise-meta-settlement-time meta) current-time)
          (push (cons current-time (concur-promise-state promise))
                (concur-promise-meta-status-history meta))
          (concur--log :debug (concur-promise-id promise)
                       "Updated promise '%s' to state %S."
                       (concur-promise-meta-name meta)
                       (concur-promise-state promise)))))))

(defun concur-registry-register-resource-hold (promise resource)
  "Record that `PROMISE` has acquired `RESOURCE`.
Called by primitives like `concur:lock-acquire`.

  Arguments:
  - `PROMISE` (concur-promise): The promise holding the resource.
  - `RESOURCE` (any): The resource object (e.g., `concur-lock`).

  Returns:
  - `nil` (side-effect: updates promise metadata)."
  (when concur-enable-promise-registry
    (unless (concur-promise-p promise)
      (user-error "concur-registry-register-resource-hold: Invalid promise: %S"
                  promise))
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (cl-pushnew resource (concur-promise-meta-resources-held meta))
        (concur--log :debug (concur-promise-id promise)
                     "Promise '%s' acquired resource %S."
                     (concur-promise-meta-name meta) resource)))))

(defun concur-registry-release-resource-hold (promise resource)
  "Record that `PROMISE` has released `RESOURCE`.
Called by primitives like `concur:lock-release`.

  Arguments:
  - `PROMISE` (concur-promise): The promise that released the resource.
  - `RESOURCE` (any): The resource object.

  Returns:
  - `nil` (side-effect: updates promise metadata)."
  (when concur-enable-promise-registry
    (unless (concur-promise-p promise)
      (user-error "concur-registry-release-resource-hold: Invalid promise: %S"
                  promise))
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (setf (concur-promise-meta-resources-held meta)
              (cl-delete resource (concur-promise-meta-resources-held meta)))
        (concur--log :debug (concur-promise-id promise)
                     "Promise '%s' released resource %S."
                     (concur-promise-meta-name meta) resource)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public Registry Inspection API

;;;###autoload
(defun concur-registry-get-promise-name (promise &optional default)
  "Return the registered name for PROMISE, or DEFAULT if not found.
This function is thread-safe and respects `concur-enable-promise-registry`.

  Arguments:
  - `PROMISE` (concur-promise): The promise to look up.
  - `DEFAULT` (any, optional): The value to return if the promise or its
    name is not found in the registry.

  Returns:
  - (string or any): The registered name, or `DEFAULT`."
  (unless (concur-promise-p promise)
    (user-error "concur-registry-get-promise-name: Invalid promise: %S" promise))
  (if (not concur-enable-promise-registry)
      default
    (concur:with-mutex! concur--promise-registry-lock
      (let* ((meta (gethash promise concur--promise-registry))
             (name (and meta (concur-promise-meta-name meta))))
        (or name default)))))

;;;###autoload
(defun concur:list-promises (&optional status-filter name-filter tags-filter)
  "Return a list of promises currently in the global registry.
Allows filtering by status, by a partial name match, or by tags.

  Arguments:
  - `STATUS-FILTER` (symbol, optional): `:pending`, `:resolved`, or `:rejected`.
    If `nil`, all statuses are included.
  - `NAME-FILTER` (string, optional): A substring to search for in promise names.
    Case-sensitive.
  - `TAGS-FILTER` (list or symbol, optional): A tag or list of tags. Promises
    must have at least one of these tags.

  Returns:
  - (list): A list of `concur-promise` objects."
  (unless concur-enable-promise-registry
    (user-error "concur:list-promises: Promise registry is not enabled."))
  (let ((matching-promises '()))
    (concur:with-mutex! concur--promise-registry-lock
      (maphash
       (lambda (promise meta)
         (when (and (or (null status-filter)
                        (eq (concur-promise-state promise) status-filter))
                    (or (null name-filter)
                        (and (concur-promise-meta-name meta)
                             (s-contains? name-filter
                                          (concur-promise-meta-name meta))))
                    (or (null tags-filter)
                        (cl-some (lambda (tag)
                                   (member tag (concur-promise-meta-tags meta)))
                                 (if (listp tags-filter) tags-filter (list tags-filter)))))
           (push promise matching-promises)))
       concur--promise-registry))
    (nreverse matching-promises)))

;;;###autoload
(defun concur:find-promise (id-or-name)
  "Find a promise in the registry by its ID (gensym) or name.

  Arguments:
  - `ID-OR-NAME` (symbol or string): The promise's gensym ID or registered name.

  Returns:
  - (concur-promise or nil): The matching promise, or `nil`."
  (unless concur-enable-promise-registry
    (user-error "concur:find-promise: Promise registry is not enabled."))
  (concur:with-mutex! concur--promise-registry-lock
    (cl-block find-promise-block
      (maphash
       (lambda (promise meta)
         (when (or (eq (concur-promise-id promise) id-or-name)
                   (and (stringp id-or-name)
                        (string= id-or-name (concur-promise-meta-name meta))))
           (cl-return-from find-promise-block promise)))
       concur--promise-registry)
      nil))) ; Return nil if loop completes without finding a match.

;;;###autoload
(defun concur:clear-registry ()
  "Clear all promises from the global registry.
Primarily for testing or debugging. Use with caution.

  Returns:
  - `nil` (side-effect: clears registry)."
  (unless concur-enable-promise-registry
    (user-error "concur:clear-registry: Promise registry is not enabled."))
  (concur:with-mutex! concur--promise-registry-lock
    (clrhash concur--promise-registry))
  (concur--log :info nil "Concur promise registry cleared."))

;;;###autoload
(defun concur:dump-registry ()
  "Dump a formatted string of all promises in the registry.
Provides a comprehensive overview of promises and their states.

  Returns:
  - (string): A multi-line string representation of the registry."
  (unless concur-enable-promise-registry
    (user-error "concur:dump-registry: Promise registry is not enabled."))
  (concur:with-mutex! concur--promise-registry-lock
    (with-temp-buffer
      (insert "--- Concur Promise Registry Dump ---\n")
      (insert (format "Total Promises: %d\n"
                      (hash-table-count concur--promise-registry)))
      (insert "-----------------------------------\n")
      (maphash
       (lambda (promise meta)
         (insert (format "Promise: %s\n" (concur:format-promise promise)))
         (insert (format "  Name: %S\n" (concur-promise-meta-name meta)))
         (insert (format "  ID: %S\n" (concur-promise-id promise)))
         (insert (format "  Mode: %S\n" (concur-promise-mode promise)))
         (insert (format "  Created: %S\n"
                         (format-time-string "%Y-%m-%d %H:%M:%S"
                                             (concur-promise-meta-creation-time meta))))
         (when (concur-promise-meta-settlement-time meta)
           (insert (format "  Settled: %S\n"
                           (format-time-string "%Y-%m-%d %H:%M:%S"
                                               (concur-promise-meta-settlement-time meta)))))
         (when-let (parent (concur-promise-meta-parent-promise meta))
           (insert (format "  Parent: %s\n" (concur:format-promise parent))))
         (when-let (children (concur-promise-meta-children-promises meta))
           (insert (format "  Children (%d): %s\n" (length children)
                           (s-join ", " (mapcar (lambda (p) (format "%S" (concur-promise-id p))) children)))))
         (when-let (resources (concur-promise-meta-resources-held meta))
           (insert (format "  Resources (%d): %S\n" (length resources)
                           (mapcar (lambda (r) (type-of r)) resources))))
         (when-let (history (concur-promise-meta-status-history meta))
           (insert (format "  History (%d):\n" (length history)))
           (cl-loop for entry in (nreverse history) do
                    (insert (format "    - %S at %S\n" (cdr entry)
                                    (format-time-string "%H:%M:%S" (car entry))))))
         (when-let (tags (concur-promise-meta-tags meta))
           (insert (format "  Tags: %S\n" tags)))
         (insert "-----------------------------------\n"))
       concur--promise-registry)
      (buffer-string))))

;;;###autoload
(defun concur:registry-status ()
  "Return a snapshot of the global promise registry's current status.

  Returns:
  - (plist): A property list with registry metrics:
    `:enabled-p`: Whether the registry is currently enabled.
    `:total-promises`: Total number of promises tracked.
    `:pending-count`: Number of promises currently in `:pending` state.
    `:resolved-count`: Number of promises in `:resolved` state.
    `:rejected-count`: Number of promises in `:rejected` state.
    `:active-resources`: Number of unique resources currently held by promises."
  (interactive)
  (unless concur-enable-promise-registry
    (user-error "concur:registry-status: Promise registry is not enabled."))
  (concur:with-mutex! concur--promise-registry-lock
    (let ((total 0) (pending 0) (resolved 0) (rejected 0) (resources-set (make-hash-table)))
      (maphash
       (lambda (promise meta)
         (cl-incf total)
         (pcase (concur-promise-state promise)
           (:pending (cl-incf pending))
           (:resolved (cl-incf resolved))
           (:rejected (cl-incf rejected)))
         (dolist (resource (concur-promise-meta-resources-held meta))
           (puthash resource t resources-set)))
       concur--promise-registry)
      `(:enabled-p ,concur-enable-promise-registry
        :total-promises ,total
        :pending-count ,pending
        :resolved-count ,resolved
        :rejected-count ,rejected
        :active-resources ,(hash-table-count resources-set)))))

;; Add hook to reject pending promises on Emacs exit if configured.
(add-hook 'kill-emacs-hook
          (lambda ()
            (when concur-registry-shutdown-on-exit-p
              (concur:with-mutex! concur--promise-registry-lock
                (concur--log :info nil "Registry: Rejecting all pending promises on exit.")
                (cl-loop for promise being the hash-keys of concur--promise-registry
                         when (concur:pending-p promise) do
                         (concur:reject promise (concur:make-error :type :shutdown
                                                                   :message "Emacs is shutting down.")))))))


(provide 'concur-registry)
;;; concur-registry.el ends here