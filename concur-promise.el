;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs
;;; lexical-binding: t; -*-

;;; Commentary:
;; This library provides a lightweight Promise implementation for Emacs Lisp.
;; It is a composite of several sub-modules that provide the core logic,
;; chaining capabilities, combinators, and utilities. Requiring this one
;; file will make the entire promise library available.

;;; Code:

(require 'concur-core)
(require 'concur-chain)
(require 'concur-combinators)

(provide 'concur-promise)
;;; concur-promise.el ends here
