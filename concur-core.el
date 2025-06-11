;;; concur-core.el --- Core functionalities for the Concur async library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the core definitions for the Concur asynchronous
;; library, including its customization group, logging hook, and internal
;; logging utility. It serves as the foundational file required by all
;; other `concur-` modules.

;;; Code:

;;;###autoload
(defgroup concur nil
  "Asynchronous programming library for Emacs."
  :group 'lisp)

(defcustom concur-log-hook nil
  "Hook run for logging messages within the Concur library.

Functions added to this hook should accept a LEVEL symbol, a
format string FMT, and any additional ARGS.

Arguments:
- `LEVEL` (symbol): The log level, e.g., `:debug`, `:info`, `:warn`, `:error`.
- `FMT` (string): The format-control string for the message.
- `ARGS` (rest): Arguments for the format string."
  :type 'hook
  :group 'concur)

(defun concur--log (level fmt &rest args)
  "Run the `concur-log-hook` with LEVEL, FMT, and ARGS.
This is an internal function for all of Concur's logging needs."
  (apply #'run-hook-with-args 'concur-log-hook level fmt args))

(provide 'concur-core)
;;; concur-core.el ends here
