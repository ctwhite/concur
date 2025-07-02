;;; concur-ui.el --- Interactive UI for Concur Promise Introspection -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides an interactive UI for inspecting the `concur` promise
;; registry. It allows developers to get a real-time, filterable overview of
;; all active and settled promises, debug complex asynchronous workflows, and
;; interactively manage tasks.
;;
;; To use, run the command `concur:inspect-registry`.

;;; Code:

(require 'tabulated-list)
(require 'concur-registry)
(require 'concur-core)
(require 'concur-cancel)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Mode Definition & Customization

(defconst concur-ui-buffer-name "*Concur Registry*"
  "The name of the buffer used for the promise registry UI.")

(defcustom concur-ui-auto-refresh-interval 2
  "The interval in seconds for auto-refreshing the UI."
  :type 'integer
  :group 'concur)

(defvar-local concur-ui--current-filter nil
  "Buffer-local variable holding the current filter plist for the UI.")
(defvar-local concur-ui--auto-refresh-timer nil
  "Buffer-local variable holding the auto-refresh timer object.")

(define-keymap concur-ui-mode-map
  :parent tabulated-list-mode-map
  "r" #'concur-ui-refresh
  "g" #'concur-ui-refresh             ; Alias for `revert-buffer` convention
  "i" #'concur-ui-inspect-promise
  "RET" #'concur-ui-inspect-promise
  "c" #'concur-ui-cancel-promise
  "k" #'concur-ui-kill-process        ; New: Kill associated process
  "a" #'concur-ui-toggle-auto-refresh ; New: Toggle auto-refresh
  "f" (let ((map (make-sparse-keymap)))
        (define-key map "s" #'concur-ui-filter-by-status)
        (define-key map "n" #'concur-ui-filter-by-name)
        (define-key map "t" #'concur-ui-filter-by-tag)
        (define-key map "c" #'concur-ui-clear-filters)
        map)
  "q" #'quit-window)

(define-derived-mode concur-ui-mode tabulated-list-mode "ConcurUI"
  "A major mode for inspecting the Concur promise registry.

Keybindings:
  r, g: Refresh the list of promises.
  i, RET: Inspect the promise at point in a separate buffer.
  c: Cancel the pending promise at point.
  k: Kill the OS process associated with the promise at point.
  a: Toggle auto-refresh mode.
  q: Quit the window.

Filtering (prefix `f`):
  f s: Filter by status (`pending`, `resolved`, `rejected`).
  f n: Filter by a substring in the promise name.
  f t: Filter by a tag.
  f c: Clear all active filters."
  (setq tabulated-list-format
        [("Status", 10, :left)
         ("Name", 35, :left)
         ("ID", 18, :left)
         ("Age (s)", 10, :right)
         ("Parent ID", 18, :left)])
  (setq tabulated-list-sort-key ("Age (s)" . t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal UI Helpers

(defun concur-ui--get-promise-at-point ()
  "Get the promise object corresponding to the current line.
Uses the idiomatic `tabulated-list-get-id`."
  (let ((promise (tabulated-list-get-id)))
    (when (concur-promise-p promise) promise)))

(defun concur-ui--format-promise-entry (promise)
  "Format a `PROMISE` into an entry for `tabulated-list-mode`.

Arguments:
- `PROMISE` (concur-promise): The promise to format.

Returns:
- (vector): A vector suitable for `tabulated-list-entries`."
  (let* ((meta (gethash promise concur--promise-registry))
         (status (concur:status promise))
         (age (format "%.2f" (- (float-time)
                                (concur-promise-meta-creation-time meta))))
         (parent-id (when-let ((p (concur-promise-meta-parent-promise meta)))
                      (format "%S" (concur-promise-id p)))))
    (vector
     ;; The ID for tabulated-list is the promise object itself.
     promise
     ;; The list of strings to display in the columns.
     (list (propertize (format "%S" status) 'face
                       (pcase status
                         (:pending 'font-lock-warning-face)
                         (:resolved 'font-lock-function-name-face)
                         (:rejected 'error)))
           (format "%s" (or (concur-promise-meta-name meta) "--"))
           (format "%S" (concur-promise-id promise))
           age
           (or parent-id "--")))))

(defun concur-ui--update-mode-line ()
  "Update the mode-line with current filter and refresh status."
  (let* ((filter-str
          (when concur-ui--current-filter
            (s-join ", "
                    (cl-loop for (k v) on concur-ui--current-filter by #'cddr
                             collect (format "%s: %s" (s-chop-prefix ":" k) v)))))
         (refresh-str (if concur-ui--auto-refresh-timer "[Auto]" "[Manual]"))
         (status-str (if filter-str
                         (format "Filter: %s" filter-str)
                       "Filter: None")))
    (setq mode-line-process (format " %s %s" refresh-str status-str))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Interactive Commands

(defun concur-ui-refresh (&optional _arg)
  "Refresh the list of promises in the UI buffer, applying current filters."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (let ((promises (apply #'concur:list-promises concur-ui--current-filter)))
      (setq tabulated-list-entries
            (mapcar #'concur-ui--format-promise-entry promises)))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (goto-char (point-min)))
  (concur-ui--update-mode-line)
  (message "Registry refreshed at %s" (format-time-string "%T")))

(defun concur-ui-inspect-promise ()
  "Show detailed, formatted metadata for the promise at point."
  (interactive)
  (when-let ((promise (concur-ui--get-promise-at-point)))
    (with-current-buffer (get-buffer-create "*Concur Promise Details*")
      (let ((inhibit-read-only t)
            (meta (gethash promise concur--promise-registry)))
        (erase-buffer)
        (insert (format "--- Details for Promise: %S ---\n\n"
                        (concur-promise-id promise)))
        (insert (format "** Name:**\t%s\n" (or (concur-promise-meta-name meta) "N/A")))
        (insert (format "** Status:**\t%S\n" (concur:status promise)))
        (insert (format "** Mode:**\t%S\n" (concur-promise-mode promise)))
        (when-let ((val (concur:value promise)))
          (insert (format "** Value:**\t%S\n" val)))
        (when-let ((err (concur:error-value promise)))
          (insert (format "** Error:**\t%S\n" err)))
        (insert "\n** Timeline **\n")
        (insert (format "- Created: \t%s\n"
                        (format-time-string "%T" (concur-promise-meta-creation-time meta))))
        (when-let (settle-time (concur-promise-meta-settlement-time meta))
          (insert (format "- Settled: \t%s\n" (format-time-string "%T" settle-time))))
        (insert "\n** Relationships **\n")
        (when-let (parent (concur-promise-meta-parent-promise meta))
          (insert (format "- Parent:\t%S\n" (concur-promise-id parent))))
        (when-let (children (concur-promise-meta-children-promises meta))
          (insert "- Children:\n")
          (dolist (child children) (insert (format "  - %S\n" (concur-promise-id child)))))
        (display-buffer (current-buffer))))))

(defun concur-ui-cancel-promise ()
  "Cancel the pending promise at point."
  (interactive)
  (when-let ((promise (concur-ui--get-promise-at-point)))
    (if (concur:pending-p promise)
        (progn
          (concur:cancel promise "Cancelled via UI")
          (message "Cancelled promise: %s" (concur-promise-id promise))
          (run-with-timer 0.1 nil #'concur-ui-refresh)) ; Refresh after a moment
      (message "Cannot cancel a promise that is not pending."))))

(defun concur-ui-kill-process ()
  "Kill the OS process associated with the promise at point, if any."
  (interactive)
  (when-let* ((promise (concur-ui--get-promise-at-point))
              (proc (concur-promise-proc promise)))
    (if (and proc (process-live-p proc))
        (progn
          (delete-process proc)
          (message "Killed process for promise: %s" (concur-promise-id promise))
          (run-with-timer 0.1 nil #'concur-ui-refresh))
      (message "No live process associated with this promise."))))

(defun concur-ui-toggle-auto-refresh ()
  "Toggle periodic refreshing of the promise registry view."
  (interactive)
  (if concur-ui--auto-refresh-timer
      (progn
        (cancel-timer concur-ui--auto-refresh-timer)
        (setq concur-ui--auto-refresh-timer nil)
        (message "Auto-refresh disabled."))
    (setq concur-ui--auto-refresh-timer
          (run-with-timer 0 concur-ui-auto-refresh-interval #'concur-ui-refresh))
    (message "Auto-refresh enabled (every %d seconds)."
             concur-ui-auto-refresh-interval))
  (concur-ui--update-mode-line))

(defun concur-ui-filter-by-status ()
  "Interactively filter the promise list by status."
  (interactive)
  (let ((status (completing-read "Filter by status: "
                                 '("pending" "resolved" "rejected"))))
    (setf (plist-put concur-ui--current-filter :status (intern (concat ":" status))))
    (concur-ui-refresh)))

(defun concur-ui-filter-by-name ()
  "Interactively filter the promise list by name substring."
  (interactive)
  (let ((name (read-string "Filter by name contains: ")))
    (if (s-blank? name)
        (setq concur-ui--current-filter
              (plist-remq concur-ui--current-filter :name))
      (setf (plist-put concur-ui--current-filter :name name)))
    (concur-ui-refresh)))

(defun concur-ui-filter-by-tag ()
  "Interactively filter the promise list by tag."
  (interactive)
  (let ((tag (intern-soft (concat ":" (read-string "Filter by tag: ")))))
    (if (null tag)
        (setq concur-ui--current-filter (plist-remq concur-ui--current-filter :tags))
      (setf (plist-put concur-ui--current-filter :tags tag)))
    (concur-ui-refresh)))

(defun concur-ui-clear-filters ()
  "Clear all active filters and refresh the view."
  (interactive)
  (setq concur-ui--current-filter nil)
  (concur-ui-refresh)
  (message "All filters cleared."))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public Entry Point

;;;###autoload
(defun concur:inspect-registry ()
  "Open an interactive buffer to inspect the promise registry."
  (interactive)
  (unless concur-enable-promise-registry
    (error "Promise registry is not enabled (`concur-enable-promise-registry`)"))
  (let ((buf (get-buffer-create concur-ui-buffer-name)))
    (with-current-buffer buf
      (concur-ui-mode)
      (setq concur-ui--current-filter nil) ; Reset filter on open
      (when-let (timer concur-ui--auto-refresh-timer) (cancel-timer timer))
      (setq concur-ui--auto-refresh-timer nil)
      (concur-ui-refresh))
    (display-buffer buf)))

(provide 'concur-ui)
;;; concur-ui.el ends here