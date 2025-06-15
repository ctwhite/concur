;;; concur-async.el --- High-level asynchronous primitives for Emacs -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides high-level asynchronous programming primitives, building
;; upon the `concur-promise` library. It offers a simplified, powerful
;; interface for writing modern, readable asynchronous code.
;;
;; Key Features:
;;
;; - `concur:defasync!`: Defines a function that is internally a coroutine but
;;   externally returns a promise, providing a seamless async/await pattern.
;; - `concur:async!`: A versatile function to run code asynchronously
;;   with various execution modes (deferred, delayed, background process, thread).
;; - `concur:let-promise*` & `concur:let-promise`: Async-aware `let` macros
;;   for managing multiple concurrent or sequential bindings.
;; - High-level concurrent iterators and coroutine combinators like
;;   `concur:parallel!`, `concur:coroutine-all`, and `concur:map-pool`.

;;; Code:

(require 'cl-lib)
(require 'async)
(require 'backtrace)
(require 'concur-promise)
(require 'coroutines)

(eval-when-compile (require 'cl-lib))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization, Hooks, & Errors

(defcustom concur-async-enable-tracing t
  "If non-nil, record and log async stack traces for `concur:async!` tasks."
  :type 'boolean
  :group 'concur)

(defcustom concur-async-hooks nil
  "Hook run during `concur:async!` lifecycle events.
Each function receives `(EVENT LABEL PROMISE &optional ERROR)` where
EVENT is one of `:started`, `:succeeded`, `:failed`, `:cancelled`."
  :type 'hook
  :group 'concur-hooks)

(define-error 'concur-async-error "Concurrency async operation error.")
(define-error 'concur-timeout "Concurrency timeout error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State & Helpers

(defvar-local concur-async--stack '()
  "Buffer-local dynamic stack of async task labels for tracing.")

(defun concur-async--run-hooks (event label promise &optional err)
  "Run `concur-async-hooks` for a given lifecycle event.

Arguments:
- EVENT (keyword): The lifecycle event, e.g., `:started`.
- LABEL (string): The name or label of the async task.
- PROMISE (`concur-promise`): The promise associated with the task.
- ERR (any, optional): The error object, if the event is `:failed`."
  (run-hook-with-args 'concur-async-hooks event label promise err))

(defun concur-async--format-trace ()
  "Return a formatted string of the current async stack.

Returns:
A string representing the call stack, suitable for logging."
  (mapconcat (lambda (frame) (format "↳ %s" frame))
             (reverse concur-async--stack)
             "\n"))

(defun concur-async--apply-semaphore-to-tasks (tasks semaphore)
  "Wrap each task promise in TASKS with semaphore acquisition/release logic.

Arguments:
- TASKS (list): A list of promises (representing tasks).
- SEMAPHORE (`concur-semaphore`): The semaphore to use.

Returns:
A new list of wrapped promises."
  (--map (lambda (task-promise)
           (concur:chain
            ;; 1. Wait to acquire a slot in the semaphore.
            (concur:promise-semaphore-acquire semaphore)
            ;; 2. Once acquired, wait for the original task to complete.
            (:then (lambda (_sem-acquired) (concur:then task-promise)))
            ;; 3. No matter what, release the semaphore when the task is done.
            (:finally (lambda () (concur:semaphore-release semaphore)))))
         tasks))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur:async! (fn &optional mode name cancel-token)
  "Run FN asynchronously according to MODE and return a `concur-promise`.
The return value of FN will be the result of the promise.

Arguments:
- FN (function): The zero-argument function (thunk) to execute.
- MODE (symbol or number, optional): The execution mode.
  - `nil`, `t`, or `'deferred`: Schedule via `run-at-time` for next idle cycle.
  - A `(number)`: Delay execution by that many seconds.
  - `'async`: Run in a background Emacs process via `async-start`.
  - `'thread`: Run in a native Emacs thread (for CPU-bound tasks).
- NAME (string, optional): A human-readable name for the operation.
- CANCEL-TOKEN (`concur-cancel-token`): Optional token to interrupt execution.

Returns:
A `concur-promise` that will resolve with the result of FN, or reject if FN
fails or is cancelled."
  (let* ((label (or name (format "async-%S" (sxhash fn))))
         (concur--current-async-stack (cons label concur--current-async-stack)))
    (let ((task-wrapper
           (lambda (resolve-fn reject-fn)
             (concur-async--run-hooks :started label (concur:make-promise))
             (condition-case err
                 (let ((result (funcall fn)))
                   (concur-async--run-hooks :succeeded label (concur:resolved! result))
                   (funcall resolve-fn result))
               (error
                (let ((err-cond `(concur-async-error :original-error ,err)))
                  (concur-async--run-hooks :failed label (concur:rejected! err-cond) err-cond)
                  (funcall reject-fn err-cond)))))))

      ;; CORRECTION: Restructure pcase to robustly handle the 'nil' case.
      (pcase mode
        ;; Case 1: Deferred execution (the default).
        ((or 'deferred 't (pred null))
         (concur:with-executor
             (lambda (resolve reject)
               (run-at-time 0 nil (lambda () (funcall task-wrapper resolve reject))))
           cancel-token))

        ;; Case 2: Delayed execution.
        ((pred numberp)
         (concur:with-executor
             (lambda (resolve reject)
               (run-at-time mode nil (lambda () (funcall task-wrapper resolve reject))))
           cancel-token))

        ;; Case 3: OS-level Process Execution.
        ('async
         (concur:from-callback
          (lambda (cb)
            (async-start `(lambda () (funcall ,task-wrapper #'identity #'identity)) cb))))

        ;; Case 4: Native Emacs Thread Execution.
        ('thread
         (concur:with-executor
             (lambda (resolve reject)
               (let ((mailbox (list nil)) timer)
                 (make-thread
                  (lambda ()
                    (condition-case err
                        (setcar mailbox (cons :success (funcall fn)))
                      (error (setcar mailbox (cons :failure err)))))
                  (format "concur-thread-%s" label))
                 (setq timer
                       (run-with-timer 0.01 0.01
                        (lambda ()
                          (when-let ((result (car mailbox)))
                            (cancel-timer timer)
                            (pcase result
                              (`(:success . ,val) (funcall resolve val))
                              (`(:failure . ,err)
                               (funcall reject `(concur-async-error :original-error ,err))))))))))
           cancel-token))

        ;; Case 5: Unknown mode.
        (_ (concur:rejected! `(concur-async-error "Unknown async mode" ,mode)))))))
                
;;;###autoload
(defun concur:deferred! (fn &optional name cancel-token)
  "Run FN asynchronously in a deferred manner and return a `concur-promise`.
This is a convenience wrapper for `(concur:async! fn 'deferred ...)`.

Arguments:
- FN (function): The zero-argument function (thunk) to execute.
- NAME (string, optional): A human-readable name for the operation.
- CANCEL-TOKEN (`concur-cancel-token`): Optional token to interrupt execution.

Returns:
A `concur-promise` that resolves with the result of FN."
  (concur:async! fn 'deferred name cancel-token))

;;;###autoload
(defmacro concur:defasync! (name args &rest body)
  "Define an async function NAME that returns a promise, with an await-based body.
This is the primary macro for creating asynchronous operations. It wraps
`defcoroutine!` and `concur:from-coroutine` into a single definition.

Arguments:
- NAME (symbol): The name of the async function.
- ARGS (list): The argument list for the function.
- BODY (forms): The asynchronous logic for the function.

Returns:
`nil`. Defines a function `NAME` as a side effect."
  (declare (indent defun) (debug t))
  (let* ((docstring (if (stringp (car body)) (pop body)
                      (format "Asynchronous function %s." name)))
         (coro-name (intern (format "%s--coro" name)))
         (parsed-args (coroutines--parse-defcoroutine-args args))
         (fn-args (car parsed-args)))
    `(progn
       (defcoroutine! ,coro-name ,args ,@body)
       (defun ,name (,@fn-args &key cancel-token)
         ,docstring
         (concur:from-coroutine
          (apply #',coro-name (list ,@fn-args))
          cancel-token)))))

;;;###autoload
(defmacro concur:let-promise (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises in parallel.
An async-aware version of `let`. All initialization forms in `BINDINGS` run
concurrently. The `BODY` is executed only after all have resolved.

Arguments:
- BINDINGS (list): A list of `(variable form)` bindings, like `let`.
- BODY (forms): The forms to execute after all bindings resolve.

Returns:
A promise that resolves with the value of the last form in BODY."
  (declare (indent 1) (debug t))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let ((vars (--map #'car bindings))
          (forms (--map #'cadr bindings)))
      `(concur:then (concur:all (list ,@forms))
                    (lambda (results)
                      (cl-destructuring-bind ,vars results
                        ,@body))))))

;;;###autoload
(defmacro concur:let-promise* (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises sequentially.
An async-aware version of `let*`. Each initialization form in `BINDINGS` is
awaited before evaluating the next.

Arguments:
- BINDINGS (list): A list of `(variable form)` bindings, like `let*`.
- BODY (forms): The forms to execute after all bindings resolve.

Returns:
A promise that resolves with the value of the last form in BODY."
  (declare (indent 1) (debug t))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let* ((binding (car bindings))
           (var (car binding))
           (form (cadr binding)))
      `(concur:then ,form
                    (lambda (,var)
                      (concur:let-promise* ,(cdr bindings) ,@body))))))

;;;###autoload
(cl-defun concur:sequence! (items fn &key semaphore)
  "Process ITEMS sequentially with async function FN.
Each item is processed only after the previous one's promise resolves.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): An async fn `(lambda (item))` that returns a promise.
- :SEMAPHORE (`concur-semaphore`): A semaphore to acquire before each step.

Returns:
A promise that resolves with a list of results, or rejects on first failure."
  (let ((tasks (--map (funcall fn it) items)))
    (if semaphore
        (concur:map-series
         (concur-async--apply-semaphore-to-tasks tasks semaphore)
         #'identity)
      (concur:map-series items fn))))

;;;###autoload
(cl-defun concur:parallel! (items fn &key semaphore)
  "Process ITEMS in parallel with async function FN, with optional throttling.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): An async fn `(lambda (item))` that returns a promise.
- :SEMAPHORE (`concur-semaphore`): A semaphore to limit concurrency.

Returns:
A promise that resolves with a list of results, or rejects on first failure."
  (let ((tasks (--map (funcall fn it) items)))
    (if semaphore
        (concur:all (concur-async--apply-semaphore-to-tasks tasks semaphore))
      (concur:all tasks))))

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple asynchronous operations and settle with the first to finish.

Arguments:
- FORMS: A sequence of forms, each evaluating to a `concur-promise` or
  `concur-future`.
- :SEMAPHORE (`concur-semaphore`, optional): A keyword argument specifying
  a semaphore to apply to each operation for throttling purposes.

Returns:
A `concur-promise` that settles with the value or error of the first
form to complete."
  (declare (indent 0) (debug t))
  ;; --- Manually parse keyword arguments from the &rest list ---
  (let* ((semaphore-keyword-pos (cl-position :semaphore forms))
         (task-forms (if semaphore-keyword-pos
                         (cl-subseq forms 0 semaphore-keyword-pos)
                       forms))
         (semaphore-form (if semaphore-keyword-pos
                             (nth (1+ semaphore-keyword-pos) forms)
                           nil)))

    ;; --- Generate the simplified runtime code ---
    `(let* ((awaitables-list (list ,@task-forms))
            (semaphore ,semaphore-form))
       ;; The low-level `concur:race` will handle normalizing any futures
       ;; in the list into promises automatically.
       (if semaphore
           (concur:race
            (concur-async--apply-semaphore-to-tasks awaitables-list semaphore))
         (concur:race awaitables-list)))))

;;;###autoload
(defun concur:coroutine-all (runners &key semaphore)
  "Run a list of coroutine RUNNERS in parallel and wait for all to complete.

Arguments:
- RUNNERS (list): A list of coroutine runner functions.
- :SEMAPHORE (`concur-semaphore`): A semaphore to limit concurrency.

Returns:
A promise that resolves with a list of all results, or rejects if any
of the coroutines reject."
  (let* ((promises (-map #'concur:from-coroutine runners)))
    (if semaphore
        (concur:all (concur-async--apply-semaphore-to-tasks promises semaphore))
      (concur:all promises))))

;;;###autoload
(defun concur:coroutine-race (runners &key semaphore)
  "Race a list of coroutine RUNNERS in parallel.

Arguments:
- RUNNERS (list): A list of coroutine runner functions.
- :SEMAPHORE (`concur-semaphore`): A semaphore to limit concurrency.

Returns:
A promise that settles with the first coroutine to settle."
  (let* ((promises (-map #'concur:from-coroutine runners)))
    (if semaphore
        (concur:race (concur-async--apply-semaphore-to-tasks promises semaphore))
      (concur:race promises))))

;;;###autoload
(cl-defun concur:map-pool (items fn &key (size 4))
  "Process ITEMS using async FN, with a concurrency limit of SIZE.
This function creates a pool of coroutines to process items in parallel,
but limits the number of concurrently running coroutines to SIZE.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): An async fn `(lambda (item))` that returns a coroutine runner.
- :SIZE (integer): The maximum number of coroutines to run at once.

Returns:
A promise that resolves with a list of all results in the original
order of ITEMS."
  (concur:with-executor
      (lambda (resolve-executor reject-executor)
        (let* ((total (length items))
               (results (make-vector total nil))
               (item-queue (copy-sequence items))
               (in-flight 0)
               (completed 0))
          (cl-labels
              ((process-next ()
                 (while (and (< in-flight size) item-queue)
                   (let* ((item (pop item-queue))
                          (runner (funcall fn item))
                          ;; Calculate index before item-queue is modified.
                          (index (- total (length item-queue) 1)))
                     (cl-incf in-flight)
                     (concur:then
                      (concur:from-coroutine runner)
                      (lambda (res)
                        (aset results index res)
                        (cl-decf in-flight)
                        (cl-incf completed)
                        (if (= completed total)
                            (funcall resolve-executor (cl-coerce results 'list))
                          (process-next)))
                      (lambda (err)
                        (funcall reject-executor err)))))))
            (process-next))))))

(provide 'concur-async)
;;; concur-async.el ends here