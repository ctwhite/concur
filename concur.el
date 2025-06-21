;;; concur.el --- Composable concurrency primitives for Emacs -*-
;;; lexical-binding: t; -*-
;;
;; Author: Christian White <christiantwhite@protonmail.com>
;; Maintainer: Christian White <christiantwhite@protonmail.com>
;; Created: June 7, 2025
;; Version: 1.1.0
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5") (s "1.12.0") (dash "2.19.1") (coroutines "1.0"))
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
;; The recommended way to write asynchronous code is with the `concur:defun-async`
;; and `concur:await` macros, which provide a modern, sequential-looking syntax.
;;
;; Core Components (loaded by `concur.el`):
;; - `concur-core`: Foundational promise definitions and state machine.
;; - `concur-chain`: `concur:then` and other chaining primitives.
;; - `concur-combinators`: `concur:all`, `concur:race`, etc.
;; - `concur-pool`: A background worker pool for running Lisp code.
;; - `concur-process`: For running external shell commands asynchronously.
;; - `concur-coroutine`: Bridge between `concur` and the `coroutines.el` library.

;;; Code:

;;;###autoload
(defconst concur-version "1.1.0"
  "The version number of the concur.el library.")

;; Load all constituent modules.
(require 'concur-core)
(require 'concur-chain)
(require 'concur-combinators)
(require 'concur-future)
(require 'concur-cancel)
(require 'concur-lock)
(require 'concur-semaphore)
(require 'concur-stream)
(require 'concur-queue)
(require 'concur-pool)
(require 'concur-shell)
(require 'concur-graph)
(require 'concur-pipeline)
(require 'concur-async)
(require 'concur-nursery)
(require 'concur-registry)

;; Load the coroutine bridge, which is essential for the async/await syntax.
(require 'coroutines)
(require 'concur-coroutine)

;; The key used by `await` to yield a promise to the underlying driver.
(declare-function yield--await-external-status-key "yield")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; High-Level Async/Await Syntax (Recommended API)

;;;###autoload
(defmacro concur:await! (promise-form)
  "Wait for a promise to settle inside a `concur:defun-async` block.
This macro is the asynchronous equivalent of a blocking function call,
but it yields control instead of freezing the UI. It can only be used
inside a function defined with `concur:defun-async`.

Arguments:
- `PROMISE-FORM` (form): An expression that evaluates to a `concur-promise`
  or another awaitable object (like a future or coroutine).

Returns:
  The resolved value of the promise. Signals an error if the promise rejects."
  ;; This macro expands to a `yield!` call with a special key that the
  ;; `concur:from-coroutine` driver knows how to handle.
  `(yield! (list yield--await-external-status-key ,promise-form)))

;;;###autoload
(defmacro concur:defasync! (name arglist &rest body)
  "Define an asynchronous function NAME with ARGLIST and BODY.
This creates a function that, when called, immediately returns a
`concur-promise`. The BODY of the function is executed as a coroutine.
Inside the body, you can use `(concur:await ...)` to wait for other
promises to complete, allowing you to write asynchronous code that reads
like standard, sequential code.

Arguments:
- `NAME` (symbol): The name for the asynchronous function.
- `ARGLIST` (list): The argument list for the function.
- `BODY` (form...): The forms that make up the function's logic.

Returns:
  The symbol `NAME`, now defined as an async function.

Example:
  (concur:defun-async my-fetch-data (url)
    \"Fetch and process data from a URL asynchronously.\"
    (let* ((response (concur:await! (http-get url)))
           (json (concur:await! (json-parse-promise response))))
      (plist-get json :data)))

  ;; Calling it returns a promise immediately:
  ;; (my-fetch-data \"https://api.example.com/data\")
  ;; => #<Promise ... pending>"
  (declare (indent defun))
  (let ((docstring (if (stringp (car body)) (pop body)
                     (format "Asynchronous function %s." name))))
    `(defun ,name (,@arglist)
       ,docstring
       ;; 1. The body of the user's function is wrapped in a coroutine.
       ;;    Calling `coroutine-create` returns a "runner" function.
       (let ((coroutine-runner (coroutine-create (lambda () ,@body))))
         ;; 2. The coroutine runner is then passed to `concur:from-coroutine`,
         ;;    which wraps it in a promise and drives its execution until completion.
         (concur:from-coroutine coroutine-runner)))))

(provide 'concur)
;;; concur.el ends here