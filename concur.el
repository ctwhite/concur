;;; concur.el --- Concurrent programming primitives for Emacs -*- lexical-binding: t; -*-
;;
;; Author: Christian White
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (dash "2.19.1") (ht "2.3"))
;; Homepage: https://github.com/ctwhite/concur.el
;; Keywords: concurrency, async, tools, lisp
;;
;;; Commentary:
;;
;; This package provides composable concurrency primitives for Emacs Lisp,
;; inspired by asynchronous patterns found in modern languages.
;;
;; Included components:
;; - concur-future: lazy evaluated async results
;; - concur-promise: one-time settable values with chained continuations
;; - concur-lock: mutual exclusion for cooperative coroutines
;; - concur-proc: simple cooperative multitasking
;; - concur-slot: thread-safe shared mutable values
;; - concur-task: structured background tasks
;;
;; These primitives are intended to simplify reasoning about async workflows
;; in a synchronous environment like Emacs Lisp.
;;
;;; Code:

(require 'concur-future)
(require 'concur-lock)
(require 'concur-proc)
(require 'concur-promise)
(require 'concur-slot)
(require 'concur-task)

(provide 'concur)

;;; concur.el ends here