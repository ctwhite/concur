;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs
;;; lexical-binding: t; -*-

;;; Commentary:
;; This library provides a lightweight Promise implementation for Emacs Lisp.
;; It is a composite of several sub-modules that provide the core logic,
;; chaining capabilities, combinators, and utilities. Requiring this one
;; file will make the entire promise library available.

;;; Code:

(require 'concur-promise-core)
(require 'concur-promise-chain)
(require 'concur-promise-combinators)
(require 'concur-promise-utils)

(provide 'concur-promise)
;;; concur-promise.el ends here
