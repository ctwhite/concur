;;; concur.el --- Concurrent programming primitives for Emacs -*- lexical-binding: t; -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Maintainer: Christian White <christiantwhite@protonmail.com>
;; Created: June 7, 2025
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5") (s "1.12.0") (dash "2.19.1") (ts "0.3") (ht "2.3") (async "1.9.7"))
;; Homepage: https://github.com/ctwhite/concur.el
;; Keywords: concurrency, async, promises, futures, tasks, processes, lisp
;;
;;; Commentary:
;;
;; `concur.el` provides a suite of composable concurrency primitives for Emacs Lisp,
;; inspired by asynchronous patterns found in modern programming languages.
;; The goal is to simplify reasoning about and managing asynchronous workflows
;; within the cooperative multitasking environment of Emacs.
;;
;; This package is the main entry point and loads the various components
;; of the concur library.
;;
;; Core Components (loaded by `concur.el`):
;; - `concur-core`: Foundational definitions and the logging hook.
;; - `concur-promise`: Implements Promises/A+ for managing async results.
;; - `concur-future`: Provides lazily-evaluated asynchronous computations.
;; - `concur-cancel`: Defines cancellation tokens for cooperative cancellation.
;; - `concur-primitives`: Offers locks, semaphores, and other low-level utilities.
;; - `concur-exec`: Provides functions for running external commands asynchronously.
;; - `concur-async`: High-level API (`async!`, `await!`, `let-promise*`, etc.)
;;   for running and managing asynchronous tasks.
;;
;; These primitives are designed to be used together to build robust and
;; manageable asynchronous applications and features within Emacs.
;;
;;; Code:

;;;###autoload
(defconst concur-version "1.0.0"
  "The version number of the concur.el library.")

;;;###autoload
(defgroup concur nil
  "Asynchronous programming library for Emacs."
  :group 'lisp)

(require 'concur-hooks)

;; Load the main building blocks of the library.
(require 'concur-promise)
(require 'concur-future)
(require 'concur-cancel)

;; Load lower-level and higher-level utilities.
(require 'concur-primitives)
(require 'concur-exec)
(require 'concur-async)

(provide 'concur)
;;; concur.el ends here