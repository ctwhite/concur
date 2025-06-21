;;; concur-registry.el --- Concur Promise Registry for Introspection -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This module provides a global registry for `concur-promise` objects.
;; When enabled, it tracks all promises created and their state changes,
;; offering powerful introspection and debugging capabilities.
;;
;; Architectural Highlights:
;; - Global Hash Table: `concur--promise-registry` stores promises by ID.
;; - State Metadata: `concur-promise-meta` captures rich context like parent/child
;;   relationships, status history, and resources held.
;; - Lifecycle Hooks: Integrates with `concur-core.el` for seamless updates.
;; - Debugging Aids: Provides functions to list, filter, and inspect promises.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 's)
(require 'concur-core)
(require 'concur-lock)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization and Global State

(defcustom concur-enable-promise-registry t
  "If non-nil, enable the global promise registry.
When enabled, all promises created will be tracked, allowing for
introspection and debugging via functions like `concur:dump-registry`.
Disabling this saves memory and minor processing overhead."
  :type 'boolean
  :group 'concur)

(defvar concur--promise-registry (make-hash-table :test 'eq)
  "Global hash table mapping promise objects to `concur-promise-meta` data.")

(defvar concur--promise-registry-lock
  (concur:make-lock "promise-registry-lock")
  "Mutex protecting `concur--promise-registry` for thread-safety.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definitions

(eval-and-compile
  (cl-defstruct (concur-promise-meta (:constructor %%make-promise-meta))
    "Metadata for a promise in the global registry.
This struct stores additional, non-core information about a promise
that is useful for debugging, without bloating the `concur-promise` struct.

Fields:
- `promise` (concur-promise): The promise object this metadata describes.
- `name` (string): A human-readable name for the promise, if provided.
- `status-history` (list): A list of status changes `(timestamp . status)`.
- `creation-time` (float): The time the promise was created.
- `settlement-time` (float or nil): The time the promise settled.
- `parent-promise` (concur-promise or nil): The promise that created this one.
- `children-promises` (list): Promises created by this promise (e.g. in a chain).
- `resources-held` (list): External resources held by this promise
  (e.g., locks, semaphores)."
    (promise nil :type (or null (satisfies concur-promise-p)))
    (name nil :type (or string null))
    (status-history '() :type list)
    (creation-time (float-time) :type float)
    (settlement-time nil :type (or float null))
    (parent-promise nil :type (or null (satisfies concur-promise-p)))
    (children-promises '() :type list)
    (resources-held '() :type list)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Registry Management (Called from concur-core)

(defun concur-registry-register-promise (promise name &key parent-promise)
  "Register a new `PROMISE` in the global registry.
Creates metadata for the promise and handles parent-child links.

Arguments:
- `PROMISE` (concur-promise): The promise to register.
- `NAME` (string): A human-readable name for the promise.
- `:PARENT-PROMISE` (concur-promise, optional): The promise that
  caused the creation of this `PROMISE`."
  (when concur-enable-promise-registry
    (concur:with-mutex! concur--promise-registry-lock
      (let ((meta (%%make-promise-meta :promise promise :name name
                                       :parent-promise parent-promise)))
        (puthash promise meta concur--promise-registry)
        (push (cons (float-time) (concur-promise-state promise))
              (concur-promise-meta-status-history meta))
        (when (and parent-promise (concur-promise-p parent-promise))
          (when-let ((parent-meta (gethash parent-promise concur--promise-registry)))
            (push promise (concur-promise-meta-children-promises parent-meta))))))))

(defun concur-registry-update-promise-state (promise)
  "Update the state of `PROMISE` in the global registry when it settles.
This function is called by `concur--settle-promise` in `concur-core.el`.

Arguments:
- `PROMISE` (concur-promise): The promise whose state has changed."
  (when concur-enable-promise-registry
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (let ((current-time (float-time)))
          (setf (concur-promise-meta-settlement-time meta) current-time)
          (push (cons current-time (concur-promise-state promise))
                (concur-promise-meta-status-history meta)))))))

(defun concur-registry-register-resource-hold (promise resource)
  "Record that `PROMISE` has acquired `RESOURCE`.
Called by primitives like `concur:lock-acquire`.

Arguments:
- `PROMISE` (concur-promise): The promise holding the resource.
- `RESOURCE` (any): The resource object (e.g., `concur-lock`)."
  (when concur-enable-promise-registry
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (pushnew resource (concur-promise-meta-resources-held meta))))))

(defun concur-registry-release-resource-hold (promise resource)
  "Record that `PROMISE` has released `RESOURCE`.

Arguments:
- `PROMISE` (concur-promise): The promise that released the resource.
- `RESOURCE` (any): The resource object."
  (when concur-enable-promise-registry
    (concur:with-mutex! concur--promise-registry-lock
      (when-let ((meta (gethash promise concur--promise-registry)))
        (setf (concur-promise-meta-resources-held meta)
              (delq resource (concur-promise-meta-resources-held meta)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public Registry Inspection API

;;;###autoload
(defun concur-registry-get-promise-name (promise &optional default)
  "Return the registered name for PROMISE, or DEFAULT if not found.
This function is thread-safe and respects `concur-enable-promise-registry`.

Arguments:
- `PROMISE` (concur-promise): The promise to look up.
- `DEFAULT` (any, optional): The value to return if the promise or its
  name is not found in the registry."
  (if (not concur-enable-promise-registry)
      default
    (concur:with-mutex! concur--promise-registry-lock
      (let* ((meta (gethash promise concur--promise-registry))
             (name (and meta (concur-promise-meta-name meta))))
        (or name default)))))

;;;###autoload
(defun concur:list-promises (&optional status-filter name-filter)
  "Return a list of promises currently in the global registry.
Allows filtering by status or by a partial name match.

Arguments:
- `STATUS-FILTER` (symbol, optional): `:pending`, `:resolved`, or `:rejected`.
- `NAME-FILTER` (string, optional): A substring to search for in promise names.

Returns:
  (list) A list of `concur-promise` objects."
  (concur:with-mutex! concur--promise-registry-lock
    (cl-loop for promise being the hash-keys of concur--promise-registry
             for meta being the hash-values of concur--promise-registry
             when (and (or (null status-filter)
                           (eq (concur-promise-state promise) status-filter))
                       (or (null name-filter)
                           (and (concur-promise-meta-name meta)
                                (s-contains? name-filter (concur-promise-meta-name meta)))))
             collect promise)))

;;;###autoload
(defun concur:find-promise (id-or-name)
  "Find a promise in the registry by its ID (gensym) or name.

Arguments:
- `ID-OR-NAME` (symbol or string): The promise's gensym ID or registered name.

Returns:
  (concur-promise or nil) The matching promise, or `nil`."
  (concur:with-mutex! concur--promise-registry-lock
    (cl-loop for promise being the hash-keys of concur--promise-registry
             for meta being the hash-values of concur--promise-registry
             when (or (eq (concur-promise-id promise) id-or-name)
                      (and (stringp id-or-name)
                           (string= id-or-name (concur-promise-meta-name meta))))
             return promise)))

;;;###autoload
(defun concur:clear-registry ()
  "Clear all promises from the global registry.
Primarily for testing or debugging. Use with caution."
  (concur:with-mutex! concur--promise-registry-lock
    (clrhash concur--promise-registry)))

;;;###autoload
(defun concur:dump-registry ()
  "Dump a formatted string of all promises in the registry.
Provides a comprehensive overview of promises and their states.

Returns:
  (string) A multi-line string representation of the registry."
  (concur:with-mutex! concur--promise-registry-lock
    (with-temp-buffer
      (insert "--- Concur Promise Registry Dump ---\n")
      (insert (format "Total Promises: %d\n" (hash-table-count concur--promise-registry)))
      (insert "-----------------------------------\n")
      (maphash
       (lambda (promise meta)
         (insert (format "%s\n" (concur:format-promise promise)))
         (when-let (parent (concur-promise-meta-parent-promise meta))
           (insert (format "  Parent: %s\n" (concur:format-promise parent))))
         (when-let (children (concur-promise-meta-children-promises meta))
           (insert (format "  Children: %s\n"
                           (mapcar #'concur:format-promise children))))
         (when-let (resources (concur-promise-meta-resources-held meta))
           (insert (format "  Resources: %S\n" resources)))
         (insert "-----------------------------------\n"))
       concur--promise-registry)
      (buffer-string))))

(provide 'concur-registry)
;;; concur-registry.el ends here
