;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur.el --- Composable concurrency primitives for Emacs -*- lexical-binding: t; -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1") (cl-lib "0.5") (s "1.12.0")
;;                    (dash "2.19.1") (coroutines "1.0"))
;; Homepage: https://github.com/ctwhite/concur.el
;; Keywords: concurrency, async, promises, futures, tasks, lisp, emacs

;;; Commentary:

;; `concur.el` provides a suite of composable concurrency primitives for
;; Emacs Lisp, inspired by asynchronous patterns found in modern programming
;; languages. The goal is to simplify reasoning about and managing
;; asynchronous workflows within the cooperative multitasking environment of
;; Emacs.
;;
;; The library is structured into modular components, each addressing a
;; specific aspect of concurrency:
;;
;; - `concur-core`: Defines the foundational `concur-promise` data structure
;;   and its core state machine, scheduling, and thread-safety primitives.
;; - `concur-chain`: Provides the primary API for composing and chaining
;;   promises (`concur:then`, `concur:catch`, `concur:chain`).
;; - `concur-combinators`: Offers functions to operate on collections of
;;   promises (`concur:all`, `concur:race`, `concur:any`).
;; - `concur-future`: Implements lazy, deferred computations (`concur:make-future`).
;; - `concur-cancel`: Defines primitives for cooperative task cancellation.
;; - `concur-lock`: Provides mutual exclusion locks (mutexes) for thread-safety.
;; - `concur-semaphore`: Implements counting semaphores for resource control.
;; - `concur-stream`: Offers asynchronous, buffered data streams.
;; - `concur-queue`: Provides a generic FIFO queue implementation.
;; - `concur-lisp`: Manages a persistent pool of background Lisp worker processes.
;; - `concur-shell`: Manages a persistent pool of background shell processes.
;; - `concur-graph`: Enables defining and executing asynchronous task dependency graphs.
;; - `concur-pipeline`: Provides a high-level macro for linear data-processing pipelines.
;; - `concur-flow`: Contains high-level async primitives for running tasks in
;;   various execution contexts (`concur:start!`, `concur:async!`, `concur:parallel!`).
;; - `concur-nursery`: Implements structured concurrency using "nurseries" to
;;   manage groups of related tasks.
;; - `concur-registry`: Provides a global registry for `concur-promise` objects
;;   for introspection and debugging.
;; - `concur-coroutine`: Bridges `concur` with Emacs's `coroutines.el` library,
;;   enabling the `concur:await!` and `concur:defasync!` syntax.
;;
;; The recommended way to write asynchronous code is with the
;; `concur:defasync!` and `concur:await!` macros, which provide a modern,
;; sequential-looking syntax.

;;; Code:

;;;###autoload
(defconst concur-version "2.0.0"
  "The version number of the concur.el library.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Concur Modules Loading

;; Core components, ordered to satisfy dependencies.
(require 'concur-log)      ; First, for logging throughout
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-async)
(require 'concur-microtask)
(require 'concur-registry)
(require 'concur-core)
(require 'concur-cancel)
(require 'concur-scheduler)
(require 'concur-semaphore)
(require 'concur-stream)
(require 'concur-chain)
(require 'concur-combinators)
(require 'concur-abstract-pool)
(require 'concur-lisp)     ; Lisp worker pool
(require 'concur-shell)    ; Shell worker pool
(require 'concur-graph)
(require 'concur-pipeline)
(require 'concur-flow)
(require 'concur-nursery)

;; Load the coroutine bridge, which is essential for the async/await syntax.
(require 'coroutines)        ; Core Emacs library for coroutines
(require 'concur-coroutine)  ; Bridge between `concur` and `coroutines.el`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; High-Level Async/Await Syntax (Recommended API)

;; The key used by `await` to yield a promise to the underlying driver.
(declare-function yield--await-external-status-key "yield")

;;;###autoload
(defmacro concur:await! (promise-form)
  "Wait for a promise to settle inside a `concur:defasync!` block.
This macro is the asynchronous equivalent of a blocking function call,
but it yields control instead of freezing the UI. It can only be used
inside a function defined with `concur:defasync!`.

  Arguments:
  - `PROMISE-FORM` (form): An expression that evaluates to a `concur-promise`
    or another awaitable object (like a future or coroutine).

  Returns:
  - (any): The resolved value of the promise. Signals an error if the
    promise rejects."
  (declare (indent 1) (debug t))
  (concur--log :debug nil "Expanding concur:await! for promise: %S."
               promise-form)
  `(yield! (list yield--await-external-status-key ,promise-form)))

;;;###autoload
(defmacro concur:defasync! (name arglist &rest body)
  "Define an asynchronous function `NAME` with `ARGLIST` and `BODY`.
This creates a function that, when called, immediately returns a
`concur-promise`. The `BODY` of the function is executed as a coroutine.
Inside the `BODY`, you can use `(concur:await! ...)` to wait for other
promises to complete, allowing you to write asynchronous code that reads
like standard, sequential code.

  Arguments:
  - `NAME` (symbol): The name for the new asynchronous function.
  - `ARGLIST` (list): The argument list for the function.
  - `BODY` (forms): The forms that make up the function's logic.

  Returns:
  - (symbol): The symbol `NAME`, now defined as an async function."
  (declare (indent defun))
  (let ((docstring (if (stringp (car body)) (pop body)
                     (format "Asynchronous function %S." name))))
    (concur--log :info nil "Defining async function: %S." name)
    `(defun ,name (,@arglist)
       ,docstring
       (let ((coroutine-runner (coroutine-create (lambda () ,@body))))
         (concur:from-coroutine coroutine-runner)))))

;;;###autoload
(defmacro concur:await-with-timeout! (promise-form timeout-seconds)
  "Awaits a `PROMISE-FORM` and applies a timeout.
This macro combines `concur:await!` with `concur:timeout` in a single,
convenient async/await syntax. If the promise does not settle within
`TIMEOUT-SECONDS`, it signals a `concur-timeout-error`.

  Arguments:
  - `PROMISE-FORM` (form): An expression evaluating to a `concur-promise`.
  - `TIMEOUT-SECONDS` (number): The duration in seconds for the timeout.

  Returns:
  - (any): The resolved value of the promise.

  Signals:
  - `concur-timeout-error`: If the operation times out."
  (declare (indent 1) (debug t))
  `(concur:await (concur:timeout ,promise-form ,timeout-seconds)))

;;;###autoload
(defmacro concur:await-with-cancel-token! (promise-form cancel-token)
  "Awaits a `PROMISE-FORM` linked to a `CANCEL-TOKEN`.
If the `CANCEL-TOKEN` is cancelled while `PROMISE-FORM` is pending,
the awaited operation will signal a `concur-cancel-error`.

  Arguments:
  - `PROMISE-FORM` (form): An expression evaluating to a `concur-promise`.
  - `CANCEL-TOKEN` (concur-cancel-token): The cancellation token to link.

  Returns:
  - (any): The resolved value of the promise.

  Signals:
  - `concur-cancel-error`: If the linked token is cancelled."
  (declare (indent 1) (debug t))
  `(concur:await (concur:cancel-token-link-promise ,cancel-token ,promise-form)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Global Pool Management Commands

;;;###autoload
(defun concur:start-default-pools! ()
  "Explicitly start the global `concur-lisp` and `concur-shell` pools.
These pools are normally lazy-initialized on their first use. This command
allows pre-emptive initialization, e.g., during Emacs startup.

  Returns:
  - `nil` (side-effect: initializes pools)."
  (interactive)
  (concur--log :info nil "Explicitly starting default Concur pools...")
  (when (fboundp 'concur--lisp-pool-get-default)
    (concur--lisp-pool-get-default)) ; Accessing it initializes it.
  (when (fboundp 'concur--shell-pool-get-default)
    (concur--shell-pool-get-default)) ; Accessing it initializes it.
  (concur--log :info nil "Default Concur pools initialized."))

;;;###autoload
(defun concur:stop-default-pools! ()
  "Explicitly shut down the global `concur-lisp` and `concur-shell` pools.
This gracefully terminates all worker processes and rejects any pending
tasks within these pools. They will restart on next use.

  Returns:
  - `nil` (side-effect: shuts down pools)."
  (interactive)
  (concur--log :info nil "Explicitly stopping default Concur pools...")
  (when (fboundp 'concur:lisp-pool-shutdown!)
    (concur:lisp-pool-shutdown!))
  (when (fboundp 'concur:shell-pool-shutdown!)
    (concur:shell-pool-shutdown!))
  (concur--log :info nil "Default Concur pools shut down."))

(provide 'concur)
;; concur.el ends here