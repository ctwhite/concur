;;; concur-var.el --- Concurrent programming primitives for Emacs ---

(defvar concur--debug t
  "Whether to enable debug logging for concur.")

(defmacro concur--log! (fmt &rest args)
  "Log FMT and ARGS when `concur--debug` is non-nil.

If the macro `log!` from the `scribe` package is available, it is used;
otherwise fallback to `message` prefixed with [concur]."
  (if (macrop 'log!)  ;; <- This must happen at macro-expansion time
      `(when concur--debug
         (log! ,fmt ,@args))  ;; expand log! directly
    `(when concur--debug
       (message (concat "[concur] " ,fmt) ,@args))))

(provide 'concur-var)