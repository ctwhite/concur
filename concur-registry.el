;;; concur-registry.el --- Concur Promise Registry for Introspection -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a global registry for `concur-promise` objects.
;; When enabled, it tracks all promises created and their state changes,
;; offering powerful introspection and debugging capabilities for Concur-based
;; applications, particularly via the `concur-ui.el` library.
;;
;; Architectural Highlights:
;; - Capped Size: To prevent memory leaks, the registry is capped by
;;   `concur-registry-max-size`. It automatically evicts the oldest
;;   *settled* promises when full.
;; - O(1) ID Lookup: Uses a secondary index to allow for instantaneous
;;   retrieval of promises by their unique ID, critical for performance.
;; - State Metadata: `concur-promise-meta` captures rich context like
;;   parent/child relationships, status history, and resources held.

;;; Code:

(require 'cl-lib)
(require 'concur-lock)
(require 'concur-log)
(require 'concur-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur-promise-p "concur-core")
(declare-function concur-promise-id "concur-core")
(declare-function concur-promise-state "concur-core")
(declare-function concur:status "concur-core")
(declare-function concur:pending-p "concur-core")
(declare-function concur:format-promise "concur-core")
(declare-function concur:reject "concur-core")
(declare-function concur:make-error "concur-core")
(declare-function concur-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-registry-error
  "A generic error related to the promise registry."
  'concur-error)

(defcustom concur-enable-promise-registry t
  "If non-nil, enable the global promise registry for introspection."
  :type 'boolean
  :group 'concur)

(defcustom concur-registry-shutdown-on-exit-p t
  "If non-nil, automatically reject all pending promises on Emacs exit."
  :type 'boolean
  :group 'concur)

(defcustom concur-registry-max-size 2048
  "Maximum number of *settled* promises to keep in the registry.
This prevents the registry from growing indefinitely. When the number of
settled promises exceeds this limit, the oldest ones are evicted."
  :type 'integer
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures & Internal State

(defvar concur-resource-tracking-function nil
  "A function called by primitives when a resource is acquired or released.
The function should accept two arguments: `ACTION` (a keyword like
`:acquire` or `:release`) and `RESOURCE` (the primitive object itself).
This is intended to be dynamically bound by a higher-level library
(e.g., a promise executor) to associate resource management with a
specific task.")

(cl-defstruct (concur-promise-meta (:constructor %%make-promise-meta))
  "Metadata for a promise in the global registry.

Fields:
- `promise` (concur-promise): The promise object this metadata describes.
- `name` (string): A human-readable name for the promise.
- `status-history` (list): A list of status changes `(timestamp . status)`.
- `creation-time` (float): The time the promise was created.
- `settlement-time` (float): The time the promise settled.
- `parent-promise` (concur-promise): The promise that created this one.
- `children-promises` (list): Promises created by this promise.
- `resources-held` (list): External resources currently held by this promise.
- `tags` (list): A list of keyword tags for filtering."
  (promise nil :type (or null concur-promise-p))
  (name nil :type (or null string))
  (status-history nil :type list)
  (creation-time (float-time) :type float)
  (settlement-time nil :type (or null float))
  (parent-promise nil :type (or null concur-promise-p))
  (children-promises nil :type list)
  (resources-held nil :type list)
  (tags nil :type list))

(defvar concur--promise-registry (make-hash-table :test 'eq)
  "Global hash table mapping promise objects to `concur-promise-meta` data.")

(defvar concur--promise-id-to-promise-map (make-hash-table :test 'eq)
  "Secondary index mapping a promise's unique ID to the promise object.
This provides O(1) lookup performance for `get-promise-by-id`.")

(defvar concur--promise-registry-lock
  (concur:make-lock "promise-registry-lock")
  "Mutex protecting all registry data structures for thread-safety.")

(defvar concur--promise-registry-fifo-queue (concur-queue-create)
  "A FIFO queue of settled promise objects, used for efficient eviction.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Registry Management

(defun concur--registry-evict-oldest-settled ()
  "Evict the oldest settled promise if the registry exceeds its max size.
This must be called from within the `concur--promise-registry-lock`."
  (while (> (concur:queue-length concur--promise-registry-fifo-queue)
            concur-registry-max-size)
    (let ((oldest-promise (concur:queue-dequeue
                           concur--promise-registry-fifo-queue)))
      (when oldest-promise
        (concur--log :debug nil "Registry full. Evicting oldest promise: %S"
                     (concur-promise-id oldest-promise))
        (remhash (concur-promise-id oldest-promise)
                 concur--promise-id-to-promise-map)
        (remhash oldest-promise concur--promise-registry)))))

(cl-defun concur-registry-register-promise (promise name &key parent-promise tags)
  "Register a new `PROMISE` in the global registry.

Arguments:
- `PROMISE` (concur-promise): The promise object to register.
- `NAME` (string): A human-readable name for the promise.
- `:PARENT-PROMISE` (concur-promise, optional): The promise that created this one.
- `:TAGS` (list, optional): A list of keyword tags for filtering."
  (when concur-enable-promise-registry
    (unless (concur-promise-p promise)
      (error "Argument to register must be a promise: %S" promise))
    (concur:with-mutex! concur--promise-registry-lock
      (let ((meta (%%make-promise-meta :promise promise :name name
                                       :parent-promise parent-promise
                                       :tags (cl-delete-duplicates tags))))
        (puthash promise meta concur--promise-registry)
        (puthash (concur-promise-id promise) promise
                 concur--promise-id-to-promise-map)
        (push (cons (float-time) (concur-promise-state promise))
              (concur-promise-meta-status-history meta))
        (concur--log :debug (concur-promise-id promise) "Registered promise '%s'."
                     (or name "--unnamed--"))
        (when (and parent-promise (concur-promise-p parent-promise))
          (when-let ((parent-meta (gethash parent-promise concur--promise-registry)))
            (push promise (concur-promise-meta-children-promises parent-meta))))))))

(defun concur-registry-update-promise-state (promise)
  "Update the state of `PROMISE` in the registry when it settles.

Arguments:
- `PROMISE` (concur-promise): The promise that has just settled."
  (when concur-enable-promise-registry
    (unless (concur-promise-p promise)
      (error "Argument must be a promise: %S" promise))
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (let ((current-time (float-time)))
          (setf (concur-promise-meta-settlement-time meta) current-time)
          (push (cons current-time (concur-promise-state promise))
                (concur-promise-meta-status-history meta))
          (concur:queue-enqueue concur--promise-registry-fifo-queue promise)
          (concur--registry-evict-oldest-settled)
          (concur--log :debug (concur-promise-id promise)
                       "Updated promise '%s' to state %S."
                       (or (concur-promise-meta-name meta) "--unnamed--")
                       (concur-promise-state promise)))))))

(defun concur-registry-register-resource-hold (promise resource)
  "Record that `PROMISE` has acquired `RESOURCE`.

Arguments:
- `PROMISE` (concur-promise): The promise acquiring the resource.
- `RESOURCE` (any): The resource being held (e.g., a lock)."
  (when concur-enable-promise-registry
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (cl-pushnew resource (concur-promise-meta-resources-held meta))
        (concur--log :debug (concur-promise-id promise)
                     "Promise acquired resource %S." (type-of resource))))))

(defun concur-registry-release-resource-hold (promise resource)
  "Record that `PROMISE` has released `RESOURCE`.

Arguments:
- `PROMISE` (concur-promise): The promise releasing the resource.
- `RESOURCE` (any): The resource being released."
  (when concur-enable-promise-registry
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (setf (concur-promise-meta-resources-held meta)
              (cl-delete resource (concur-promise-meta-resources-held meta)))
        (concur--log :debug (concur-promise-id promise)
                     "Promise released resource %S." (type-of resource))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun concur-registry-get-promise-by-id (promise-id)
  "Return the promise object associated with `PROMISE-ID`. O(1) complexity.

Arguments:
- `PROMISE-ID` (symbol): The unique `gensym` ID of the promise.

Returns:
- `(concur-promise or nil)`: The promise object, or `nil` if not found."
  (when (and concur-enable-promise-registry promise-id)
    (concur:with-mutex! concur--promise-registry-lock
      (gethash promise-id concur--promise-id-to-promise-map))))

;;;###autoload
(defun concur-registry-get-promise-name (promise &optional default)
  "Return the registered name for `PROMISE`, or `DEFAULT` if not found.

Arguments:
- `PROMISE` (concur-promise): The promise to inspect.
- `DEFAULT` (any): The value to return if the promise is not in the registry.

Returns:
- (string or any): The promise's name, or the `DEFAULT` value."
  (unless (concur-promise-p promise) (error "Invalid promise: %S" promise))
  (if-let ((meta (and concur-enable-promise-registry
                       (gethash promise concur--promise-registry))))
      (or (concur-promise-meta-name meta) default)
    default))

;;;###autoload
(cl-defun concur:list-promises (&key status name tags)
  "Return a list of promises from the registry, with optional filters.

Arguments:
- `:STATUS` (symbol): Filter by status: `:pending`, `:resolved`, or `:rejected`.
- `:NAME` (string): Filter by a substring in the promise name.
- `:TAGS` (list or symbol): Filter by a tag or list of tags.

Returns:
- (list): A list of `concur-promise` objects."
  (unless concur-enable-promise-registry (error "Promise registry is disabled"))
  (let (matching)
    (concur:with-mutex! concur--promise-registry-lock
      (maphash
       (lambda (promise meta)
         (when (and (or (null status) (eq (concur:status promise) status))
                    (or (null name)
                        (and (concur-promise-meta-name meta)
                             (string-match-p (regexp-quote name)
                                             (concur-promise-meta-name meta))))
                    (or (null tags)
                        (let ((tag-list (if (listp tags) tags (list tags))))
                          (cl-some (lambda (tag) (memq tag (concur-promise-meta-tags meta)))
                                   tag-list))))
           (push promise matching)))
       concur--promise-registry))
    (nreverse matching)))

;;;###autoload
(defun concur:find-promise (id-or-name)
  "Find a promise in the registry by its ID (symbol) or name (string).

Arguments:
- `ID-OR-NAME` (symbol or string): The promise's `gensym` ID or registered name.

Returns:
- `(concur-promise or nil)`: The matching promise, or `nil`."
  (unless concur-enable-promise-registry (error "Promise registry is disabled"))
  (if (symbolp id-or-name)
      (concur-registry-get-promise-by-id id-or-name)
    (concur:with-mutex! concur--promise-registry-lock
      (cl-block find-by-name
        (maphash (lambda (promise meta)
                   (when (and (stringp id-or-name)
                              (string= id-or-name (concur-promise-meta-name meta)))
                     (cl-return-from find-by-name promise)))
                 concur--promise-registry)))))

;;;###autoload
(defun concur:clear-registry ()
  "Clear all promises from the global registry.
This is primarily for testing or debugging. Use with caution.

Returns:
- `nil`."
  (interactive)
  (unless concur-enable-promise-registry (error "Promise registry is disabled"))
  (concur:with-mutex! concur--promise-registry-lock
    (clrhash concur--promise-registry)
    (clrhash concur--promise-id-to-promise-map)
    (setq concur--promise-registry-fifo-queue (concur-queue-create)))
  (concur--log :info nil "Concur promise registry cleared."))

;;;###autoload
(defun concur:dump-registry ()
  "Dump a formatted string of all promises in the registry.

Returns:
- (string): A multi-line string representation of the registry."
  (unless concur-enable-promise-registry (error "Promise registry is disabled"))
  (concur:with-mutex! concur--promise-registry-lock
    (with-temp-buffer
      (insert "--- Concur Promise Registry Dump ---\n")
      (insert (format "Total Promises: %d\n" (hash-table-count concur--promise-registry)))
      (insert "-----------------------------------\n")
      (maphash
       (lambda (promise meta)
         (insert (format "Promise: %s\n" (concur:format-promise promise)))
         (insert (format "  Name: %S\n" (concur-promise-meta-name meta)))
         (when-let (parent (concur-promise-meta-parent-promise meta))
           (insert (format "  Parent: %s\n" (concur:format-promise parent))))
         (when-let (tags (concur-promise-meta-tags meta))
           (insert (format "  Tags: %S\n" tags)))
         (insert "-----------------------------------\n"))
       concur--promise-registry)
      (buffer-string))))

;;;###autoload
(defun concur:registry-status ()
  "Return a snapshot of the global promise registry's current status.

Returns:
- (plist): A property list with registry metrics."
  (interactive)
  (unless concur-enable-promise-registry (error "Promise registry is disabled"))
  (concur:with-mutex! concur--promise-registry-lock
    (let ((total 0) (pending 0) (resolved 0) (rejected 0))
      (maphash
       (lambda (_promise meta)
         (cl-incf total)
         (pcase (concur-promise-state (concur-promise-meta-promise meta))
           (:pending (cl-incf pending))
           (:resolved (cl-incf resolved))
           (:rejected (cl-incf rejected))))
       concur--promise-registry)
      `(:enabled-p ,concur-enable-promise-registry
        :total-promises ,total
        :pending-count ,pending
        :resolved-count ,resolved
        :rejected-count ,rejected))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Emacs Exit Hook

(add-hook 'kill-emacs-hook
          (lambda ()
            (when (and concur-enable-promise-registry
                       concur-registry-shutdown-on-exit-p)
              (concur:with-mutex! concur--promise-registry-lock
                (concur--log :info nil "Registry: Rejecting pending promises on exit.")
                (cl-loop for p being the hash-keys of concur--promise-registry
                         when (concur:pending-p p) do
                         (concur:reject
                          p (concur:make-error :type 'concur-pool-shutdown
                                               :message "Emacs is shutting down.")))))))

(provide 'concur-registry)
;;; concur-registry.el ends here