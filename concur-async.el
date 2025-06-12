;;; concur-async.el --- High-level asynchronous primitives for Emacs -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides high-level asynchronous programming primitives, building
;; upon the `concur-promise` and `coroutines` libraries. It offers a simplified,
;; powerful interface for writing modern, readable asynchronous code.
;;
;; The central feature is `defasync!`, which allows writing asynchronous logic
;; in a direct, sequential style using `concur:await`.
;;
;; Key Features:
;;
;; -  `defasync!`: Defines a function that is internally a coroutine but
;;    externally returns a promise, providing a seamless async/await pattern.
;; -  `concur:await`: The universal "wait" operation. It non-blockingly
;;    suspends when used inside `defasync!` and blockingly (but cooperatively)
;;    waits when used in normal functions.
;; -  `concur:async!`: A versatile function to run code asynchronously
;;    with various execution modes (deferred, delayed, background process).
;; -  `concur:let-promise*` & `concur:let-promise`: Async-aware `let` macros
;;    for managing multiple concurrent or sequential bindings.
;; -  High-level concurrent iterators and composition functions like
;;    `concur:parallel!`, `concur:coroutine-all`, and `concur:map-pool`,
;;    now with optional semaphore support.

;;; Code:

(require 'cl-lib)
(require 'async)
(require 'backtrace)
(require 'concur-promise)
(require 'coroutines)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization, Hooks, & Errors

(defcustom concur-async-enable-tracing t
  "If non-nil, record and log async stack traces for `concur:async!` tasks."
  :type 'boolean
  :group 'concur)

(defvar concur-async-hooks nil
  "Hook run during `concur:async!` lifecycle events.
Each function receives `(EVENT LABEL PROMISE &optional ERROR)` where
EVENT is one of `:started`, `:succeeded`, `:failed`, `:cancelled`.")

(define-error 'concur-async-error "Concurrency async operation error.")
(define-error 'concur-timeout "Concurrency timeout error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State & Helpers

(defvar-local concur-async--stack '()
  "Buffer-local dynamic stack of async task labels for tracing.")

(defun concur-async--run-hooks (event label promise &optional err)
  "Run `concur-async-hooks` for a given lifecycle event."
  (run-hook-with-args 'concur-async-hooks event label promise err))

(defun concur-async--format-trace ()
  "Return a formatted string of the current async stack."
  (mapconcat (lambda (frame) (format "↳ %s" frame))
             (reverse concur-async--stack)
             "\n"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; High-Level Async Execution

;;;###autoload
(defun concur:async! (fn &optional mode name cancel-token)
  "Run FN asynchronously according to MODE and return a `concur-promise`.

FN should be a zero-argument function (thunk). The return value
of FN will be the result of the promise, or an error if FN throws.

Arguments:
- `FN` (function): The zero-argument function to execute.
- `MODE` (symbol or number, optional): The execution mode.
  - `nil` or `'deferred` or `t`: Schedule immediately via `run-at-time`.
  - A `(number)`: Delay execution by that many seconds.
  - `'async`: Run in a background Emacs process via `async-start`.
- `NAME` (string, optional): A human-readable name for the operation.
- `CANCEL-TOKEN` (`concur-cancel-token`): Optional token to interrupt execution.

Results:
  Returns a `concur-promise` that will resolve with the result of FN, or
  reject if FN fails or is cancelled."
  (let* ((label (or name (format "async-%S" (sxhash fn))))
         (task (lambda (resolve reject)
                 (let ((concur-async--stack (cons label concur-async--stack)))
                   (condition-case err
                       (funcall resolve (funcall fn))
                     (error
                      (funcall reject
                               `(:error-type async-execution-error
                                 :message ,(error-message-string err)
                                 :backtrace ,(backtrace-to-string (backtrace))
                                 :async-trace ,(concur-async--format-trace)
                                 :original-error ,err))))))))
    (pcase mode
      ((or 'nil 'deferred 't)
       (concur:with-executor
        (lambda (resolve reject)
          (run-at-time 0 nil (lambda () (funcall task resolve reject))))
        cancel-token))
      ((pred numberp)
       (concur:with-executor
        (lambda (resolve reject)
          (run-at-time mode nil (lambda () (funcall task resolve reject))))
        cancel-token))
      ('async
       (concur:with-executor
        (lambda (resolve reject)
          (async-start
           ;; The background process needs to load the library to understand promises.
           `(lambda () (require 'concur-promise) (funcall ,task #'identity #'identity))
           (lambda (result)
             (if (concur:rejected-p result)
                 (funcall reject (concur:error-value result))
               (funcall resolve (concur:value result))))))
        cancel-token))
      (_ (concur:rejected! (format "Unknown async mode: %S" mode))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Async/Await Style API

;;;###autoload
(defmacro defasync! (name args &rest body)
  "Define an async function NAME that returns a promise.

This is the primary macro for creating asynchronous operations using a
sequential, `await`-based style. It wraps `defcoroutine!` and
`concur:from-coroutine` into a single, convenient definition.

Example:
  (defasync! fetch-url-content (url)
    (let* ((response (concur:await (url-retrieve-synchronously url)))
           (buffer (with-current-buffer (url-retrieve-buffer response)
                     (current-buffer))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward \"\r\n\r\n\")
        (buffer-substring-no-properties (point) (point-max)))))

Arguments:
- `NAME` (symbol): The name of the async function.
- `ARGS` (list): The argument list. Can include a `:locals` specification.
- `BODY` (form...): The asynchronous logic for the function.

Results:
  Defines a function `NAME` that, when called, returns a `concur-promise`."
  (declare (indent defun))
  (let* ((docstring (if (stringp (car body)) (pop body)
                      (format "Asynchronous function %s." name)))
         (coro-name (intern (format "%s--coro" name)))
         (parsed-args (coroutines--parse-defcoroutine-args args))
         (fn-args (car parsed-args)))
    `(progn
       ;; 1. Define the underlying coroutine that contains the body logic.
       (defcoroutine! ,coro-name ,args ,@body)
       ;; 2. Define the user-facing async function.
       (defun ,name (,@fn-args &key cancel-token)
         ,docstring
         ;; 3. When called, it creates an instance of the coroutine
         ;;    and wraps it in a promise that will settle with the
         ;;    coroutine's final outcome.
         (concur:from-coroutine
          (apply #',coro-name (list ,@fn-args))
          cancel-token)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Async-aware `let` bindings

;;;###autoload
(defmacro concur:let-promise (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises in parallel.

This macro provides an async-aware version of `let`. It evaluates
all `form`s in `BINDINGS` concurrently, waits for all of them to
resolve, and then executes `BODY` with variables bound to the results.

Arguments:
- `BINDINGS`: A list of `(variable form)` bindings, like `let`.
- `BODY`: The forms to execute after all bindings are resolved.

Results:
  A promise that resolves with the value of the last form in BODY."
  (declare (indent 1))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let ((vars (--map #'car bindings))
          (forms (--map #'cadr bindings)))
      `(concur:then (concur:all ,forms)
                    (lambda (results)
                      (cl-destructuring-bind ,vars results
                        ,@body))))))

;;;###autoload
(defmacro concur:let-promise* (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises sequentially.

This macro provides an async-aware version of `let*`. Each form in
`BINDINGS` is evaluated, and if it returns a promise, the macro
waits for it to resolve before evaluating the next binding.

Arguments:
- `BINDINGS`: A list of `(variable form)` bindings, like `let*`.
- `BODY`: The forms to execute after all bindings are resolved.

Results:
  A promise that resolves with the value of the last form in BODY."
  (declare (indent 1))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      `(concur:then ,form
                    (lambda (,var)
                      (concur:let-promise* ,(cdr bindings) ,@body))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; High-Level Concurrent Operations

;; Internal helper to apply semaphore to a list of tasks
(defun concur-async--apply-semaphore-to-tasks (tasks semaphore)
  "Wrap each task in TASKS with semaphore acquisition/release logic.
  This is used by high-level concurrent operations that accept a `:semaphore`
  keyword argument."
  (--map (lambda (task-promise)
           (concur:chain
            (concur:semaphore-acquire semaphore)
            (:then (lambda (_sem-acquired)
                     task-promise)) ; Pass the original task promise through
            (:finally (lambda () (concur:semaphore-release semaphore)))))
         tasks))

;;;###autoload
(cl-defun concur:sequence! (items fn &key semaphore)
  "Process ITEMS sequentially with async FN.

Each item is processed only after the previous one's promise resolves.
Optionally, a SEMAPHORE can be provided to limit overall concurrency
if FN itself triggers concurrent sub-tasks, or if `concur:sequence!`
is used within a larger parallel context that needs throttling.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async fn `(lambda (item))` that returns a promise.
- `:semaphore` (`concur-semaphore`, optional): A semaphore to limit
  the execution of `FN` for each item.

Results:
  A promise that resolves with a list of results, or rejects on first failure."
  (let* ((tasks (--map (funcall fn it) items)))
    (if semaphore
        (concur:map-series (concur-async--apply-semaphore-to-tasks tasks semaphore)
                           #'identity) ; Identity function to just pass through
      (concur:map-series items fn))))

;;;###autoload
(cl-defun concur:parallel! (items fn &key semaphore)
  "Process ITEMS in parallel with async FN.

All async operations are started concurrently.
Optionally, a SEMAPHORE can be provided to limit overall concurrency.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async fn `(lambda (item))` that returns a promise.
- `:semaphore` (`concur-semaphore`, optional): A semaphore to limit
  the number of concurrently executing `FN` calls.

Results:
  A promise that resolves with a list of results, or rejects on first failure."
  (let* ((tasks (--map (funcall fn it) items)))
    (if semaphore
        (concur:all (concur-async--apply-semaphore-to-tasks tasks semaphore))
      (concur:all tasks))))

;;;###autoload
(cl-defmacro concur:race! (forms &key semaphore)
  "Race multiple async operations (promises).

Optionally, a SEMAPHORE can be provided to limit concurrency
if the individual forms trigger concurrent sub-tasks.

Arguments:
- `FORMS` (list): A list of forms, each evaluating to a promise.
- `:semaphore` (`concur-semaphore`, optional): A semaphore to limit
  the execution of `FORMS`.

Results:
  A promise that settles with the outcome of the first form to settle."
  (declare (indent 0))
  (let ((form-sym (gensym "form-")))
    `(let ((,form-sym (list ,@forms))) ; Evaluate forms into a list of promises
       (if ,semaphore
           (concur:race (concur-async--apply-semaphore-to-tasks ,form-sym ,semaphore))
         (concur:race ,form-sym)))))

;;;###autoload
(cl-defmacro concur:timeout! (form timeout-seconds &key semaphore)
  "Wrap async operation FORM with a TIMEOUT-SECONDS.

Optionally, a SEMAPHORE can be provided if FORM itself triggers
concurrent sub-tasks that need throttling. When a semaphore is used,
it's acquired before the form executes and released regardless of
timeout or resolution.

Arguments:
- `FORM`: An expression that evaluates to a promise.
- `TIMEOUT-SECONDS` (number): The timeout in seconds.
- `:semaphore` (`concur-semaphore`, optional): A semaphore to limit
  the execution of `FORM`.

Results:
  A promise that rejects on timeout or settles with FORM's outcome."
  (declare (indent 1))
  (let ((promise-sym (gensym "promise-")))
    `(let ((,promise-sym ,form))
       (if ,semaphore
           (concur:chain
            (concur:semaphore-acquire ,semaphore)
            (:then (lambda (_sem-acquired)
                     (concur:timeout ,promise-sym ,timeout-seconds)))
            (:finally (lambda () (concur:semaphore-release ,semaphore))))
         (concur:timeout ,promise-sym ,timeout-seconds)))))

;;;###autoload
(cl-defun concur:coroutine-all (runners &key semaphore)
  "Run a list of coroutine RUNNERS in parallel and wait for all to complete.

Optionally, a SEMAPHORE can be provided to limit overall concurrency.

Arguments:
- `RUNNERS` (list): A list of coroutine runner functions.
- `:semaphore` (`concur-semaphore`, optional): A semaphore to limit
  the number of concurrently executing coroutines.

Results:
  Returns a `concur-promise` that resolves with a list of all results. The
  promise will reject if any of the coroutines reject."
  (let* ((runner-promises (-map #'concur:from-coroutine runners)))
    (if semaphore
        (concur:all (concur-async--apply-semaphore-to-tasks runner-promises semaphore))
      (concur:all runner-promises))))

;;;###autoload
(cl-defun concur:coroutine-race (runners &key semaphore)
  "Race a list of coroutine RUNNERS in parallel.

The first coroutine to settle (resolve or reject) determines the outcome
of the returned promise.
Optionally, a SEMAPHORE can be provided to limit overall concurrency.

Arguments:
- `RUNNERS` (list): A list of coroutine runner functions.
- `:semaphore` (`concur-semaphore`, optional): A semaphore to limit
  the number of concurrently executing coroutines.

Results:
  Returns a `concur-promise` that settles with the first coroutine to settle."
  (let* ((runner-promises (-map #'concur:from-coroutine runners)))
    (if semaphore
        (concur:race (concur-async--apply-semaphore-to-tasks runner-promises semaphore))
      (concur:race runner-promises))))

;;;###autoload
(cl-defun concur:map-pool (items fn &key (size 4))
  "Process ITEMS using async FN, with a concurrency limit of SIZE.

This function creates a pool of coroutines to process items in parallel,
but limits the number of concurrently running coroutines.
Note: This function has its own internal concurrency limit (`:size`),
so an external semaphore is typically not needed or recommended.

Arguments:
- `ITEMS` (list): The list of items to process.
- `FN` (function): An async function `(lambda (item))` that returns a
  coroutine runner.
- `:size` (integer): The maximum number of coroutines to run at once.
  Defaults to 4.

Results:
  Returns a `concur-promise` that resolves with a list of all results in
  the original order of ITEMS."
  (concur:with-executor
   (lambda (resolve reject)
     (let* ((total (length items))
            (results (make-vector total nil))
            (item-queue (copy-sequence items))
            (in-flight 0)
            (completed 0))
       (cl-labels ((process-next ()
                     (while (and (< in-flight size) item-queue)
                       (let* ((item (pop item-queue))
                              (runner (funcall fn item))
                              (index (- total (length item-queue) 1)))
                         (cl-incf in-flight)
                         (concur:then (concur:from-coroutine runner)
                           (lambda (res)
                             (aset results index res)
                             (cl-decf in-flight)
                             (cl-incf completed)
                             (if (= completed total)
                                 (funcall resolve (cl-coerce results 'list))
                               (process-next)))
                           (lambda (err) (funcall reject err)))))))
         (process-next))))))

(provide 'concur-async)
;;; concur-async.el ends here