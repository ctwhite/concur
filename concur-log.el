;;; concur-log.el --- Logging for the Concur async library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the core logging definitions for the Concur asynchronous
;; library,
;;

;;; Code:

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

(provide 'concur-log)
;;; concur-log.el ends here