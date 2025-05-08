;;; concur.el --- Concurrent programming primitives for Emacs ---

(require 'concur-proc)
(require 'concur-future)
(require 'concur-promise)
(require 'concur-slot)
(require 'concur-task)

(defvar concur--debug t
  "Whether to enable debug logging for concur.")

(defmacro concur--log! (fmt &rest args)
  "Log FMT and ARGS when `concur--debug` is non-nil.

If `log!` from the `scribe` package is bound, it is used;
otherwise fallback to `message` prefixed with [concur]."
  `(when concur--debug
     (if (fboundp 'log!)
         (log! ,fmt ,@args)
       (message (concat "[concur] " ,fmt) ,@args))))

(provide 'concur)