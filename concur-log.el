;;; concur-log.el --- Logging for the Concur async library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the core logging definitions for the Concur asynchronous
;; library. It offers a centralized and customizable mechanism for emitting
;; internal messages, useful for both debugging and understanding runtime
;; behavior.
;;
;; Key features:
;; - **Customizable Logging Hook**: `concur-log-hook` allows users to
;;   intercept and process all log messages.
;; - **Default Logging Behavior**: If no custom hook is set, messages are
;;   printed to the `*Messages*` buffer, controlled by `concur-log-default-level`.
;; - **Log Levels**: Supports standard log levels (`:trace`, `:debug`, `:info`, `:warn`, `:error`).

;;; Code:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customization

(defcustom concur-log-hook nil
  "Hook run for logging messages within the Concur library.
Functions added to this hook should accept a `LEVEL` symbol, a
format string `FMT`, and any additional `ARGS`.

Arguments:
- `LEVEL` (symbol): The log level, e.g., `:debug`, `:info`, `:warn`, `:error`.
- `FMT` (string): The format-control string.
- `ARGS` (rest): Arguments for the format string."
  :type 'hook
  :group 'concur)

(defcustom concur-log-default-level :info
  "Default minimum log level for messages printed to `*Messages*` buffer.
This applies when `concur-log-hook` is not set. Log levels are
`:trace`, `:debug`, `:info`, `:warn`, `:error` (ordered from least to most severe)."
  :type '(choice (const :tag "Trace" :trace)
                 (const :tag "Debug" :debug)
                 (const :tag "Info" :info)
                 (const :tag "Warning" :warn)
                 (const :tag "Error" :error))
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Default Logger

(defvar concur-log-level-values
  '((:trace . -1) (:debug . 0) (:info . 1) (:warn . 2) (:error . 3) (:fatal . 4) (:none . 100))
  "Alist mapping log level keywords to integer values for comparison.")

(defun concur--get-log-level-value (level)
  "Return the integer value for a given log LEVEL keyword.
Returns nil for unknown levels."
  (cdr (assoc level concur-log-level-values)))

(defun concur--default-log-function (level target-symbol fmt &rest args)
  "Default log function that prints messages to `*Messages*` buffer.
Messages are printed if `LEVEL` is equal to or more severe than
`concur-log-default-level`.

Arguments:
- `LEVEL` (symbol): The log level of the message.
- `TARGET-SYMBOL` (symbol|nil): The target symbol for context.
- `FMT` (string): The format-control string.
- `ARGS` (rest): Arguments for the format string."
  (let ((level-val (concur--get-log-level-value level))
        (min-level-val (concur--get-log-level-value concur-log-default-level)))
    ;; This check is now robust: it ensures level-val is not nil before comparing.
    (when (and level-val (>= level-val min-level-val))
      (let* ((prefix (pcase level
                       (:trace "[concur:trace] ")
                       (:debug "[concur:debug] ")
                       (:info "[concur:info] ")
                       (:warn "[concur:warn] ")
                       (:error "[concur:error] ")
                       (:fatal "[concur:fatal] ")
                       (_ (format "[concur:%S]" level))))
             (target-prefix (if target-symbol (format "[%s] " target-symbol) "")))
        (apply #'message (concat "Concur " prefix target-prefix fmt) args)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

(defun concur-log (level target-symbol fmt &rest args)
  "Run the `concur-log-hook` with LEVEL, TARGET-SYMBOL, FMT, and ARGS.
If `concur-log-hook` is empty, it falls back to `concur--default-log-function`.
This is the internal entry point for all of Concur's logging needs.

Arguments:
- `LEVEL` (symbol): The log level, e.g., `:debug`, `:info`, `:warn`, `:error`.
- `TARGET-SYMBOL` (symbol|nil): The target symbol this log pertains to.
- `FMT` (string): The format-control string for the message.
- `ARGS` (rest): Arguments for the format string."
  (interactive "sLog Level (trace/debug/info/warn/error): \nsFormat string: \n")
  (if concur-log-hook
      (apply #'run-hook-with-args 'concur-log-hook level target-symbol fmt args)
    (apply #'concur--default-log-function level target-symbol fmt args)))

(provide 'concur-log)
;;; concur-log.el ends here