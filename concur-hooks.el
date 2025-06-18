;;; concur-hooks.el --- HOoks for the Concur async library -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides the core hook definitions for the Concur asynchronous
;; library,
;;

;;; Code:

(defgroup concur-hooks nil
  "Hooks for Concur promise library events."
  :group 'concur)

(defcustom concur-resolve-callbacks-begin-hook nil
  "Hook run when a batch of promise callbacks begins execution.

Arguments:
- PROMISE (`concur-promise`): The promise that settled.
- CALLBACKS (list of `concur-callback`): The callbacks being processed."
  :type 'hook
  :group 'concur-hooks)

(defcustom concur-resolve-callbacks-end-hook nil
  "Hook run when a batch of promise callbacks finishes execution.

Arguments:
- PROMISE (`concur-promise`): The promise that settled.
- CALLBACKS (list of `concur-callback`): The callbacks that were processed."
  :type 'hook
  :group 'concur-hooks)

(defcustom concur-unhandled-rejection-hook nil
  "Hook run when a promise is rejected and no rejection handler is attached.
This hook runs *before* `concur-throw-on-promise-rejection` takes effect.

Arguments:
- PROMISE (`concur-promise`): The promise that was rejected.
- ERROR (any): The error object itself."
  :type 'hook
  :group 'concur-hooks)

(defcustom concur-normalize-awaitable-hook nil
  "Hook run to normalize arbitrary awaitable objects into `concur-promise`s.
Functions added to this hook should accept one argument (the awaitable object)
and return a `concur-promise` if they can normalize it, or `nil` otherwise.
Handlers are run in order until one succeeds.
Example: `(add-hook 'concur-normalize-awaitable-hook #'concur-future-normalize-future)`."
  :type 'hook
  :group 'concur-hooks)

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

(provide 'concur-hooks)
;;; concur-hooks.el ends here
