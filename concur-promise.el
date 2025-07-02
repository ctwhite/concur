;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs -*- lexical-binding: t; -*-
;;
;; Author: Christian White <christian.white.dev@gmail.com>
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1") (cl-lib "0.5") (s "1.12.0")
;;                    (dash "2.19.1"))
;; Homepage: https://github.com/your-github-username/concur.el
;; Keywords: concurrency, async, promises, chaining, combinators, core

;;; Commentary:

;; This library provides a lightweight Promise implementation for Emacs Lisp.
;; It is a composite of several core `concur` sub-modules that together provide
;; the essential Promise/A+ compliant logic, chaining capabilities, and common
;; combinator functions.
;;
;; Requiring this file (`concur-promise.el`) will make the core promise
;; library functionality available. This includes:
;; - `concur-core.el`: Foundational `concur-promise` definitions.
;; - `concur-chain.el`: Promise chaining primitives (`concur:then`, `concur:catch`).
;; - `concur-combinators.el`: Functions operating on collections of promises
;;   (`concur:all`, `concur:race`, `concur:any`).
;;
;; This file offers a more lightweight alternative to requiring the entire
;; `concur.el` library, which includes heavier components like worker pools
;; (`concur-lisp.el`, `concur-shell.el`) and high-level async utilities
;; (`concur-async.el`).

;;; Code:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Modules for Promises

(require 'concur-core)
(require 'concur-chain)
(require 'concur-combinators)

(provide 'concur-promise)
;; concur-promise.el ends here