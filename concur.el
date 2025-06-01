;;; concur.el --- Concurrent programming primitives for Emacs -*- lexical-binding: t; -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Maintainer: Christian White <christiantwhite@protonmail.com>
;; Created: June 1, 2025
;; Version: 0.3.2 
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
;; - `concur-promise.el`: Implements Promises/A+ like one-time settable values
;;   with support for chained continuations (`then`), error handling (`catch`),
;;   and composition (`all`, `race`).
;; - `concur-exec.el`: Provides functions for running external commands
;;   asynchronously, returning promises that resolve with process output or
;;   rejection details. Includes `concur:command` and `concur:pipe!`.
;; - `concur-cancel.el`: Defines cancellation tokens for cooperative
;;   cancellation of asynchronous operations.
;; - `concur-future.el`: Provides lazily-evaluated asynchronous results,
;;   representing values that will be available in the future.
;; - `concur-primitives.el`: Offers lower-level concurrency primitives such as
;;   locks (mutexes), semaphores, and once-execution macros.
;; - `concur-async.el`: Provides high-level asynchronous programming utilities,
;;   including `concur:async!` for running functions with various execution
;;   modes (deferred, threaded, async process) and `concur:await!` for
;;   synchronously-looking await patterns.
;;
;; These primitives are designed to be used together to build robust and
;; manageable asynchronous applications and features within Emacs.
;;
;;; Code:

(require 'cl-lib)

;; Load the core components
(require 'concur-promise)
(require 'concur-exec)
(require 'concur-cancel)
(require 'concur-future)
(require 'concur-primitives)
(require 'concur-async)

(provide 'concur)
;;; concur.el ends here