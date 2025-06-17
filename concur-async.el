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
;;
;; - `concur:async!`: A versatile function to run code asynchronously
;;   with various execution modes (deferred, delayed, background process,
;;   thread).
;;
;; - `concur:let-promise*` & `concur:let-promise`: Async-aware `let` macros
;;   for managing multiple concurrent or sequential bindings.
;;
;; - High-level concurrent iterators and coroutine combinators like
;;   `concur:parallel!`, `concur:coroutine-all`, and `concur:map-pool`.
;;
;; New additions include a promise inspector for debugging, `concur:unwind-protect!`
;; for robust resource management, `concur:while!` for async loops, and
;; `concur:any!` for finding the first resolved promise in a set.

;;; Code:

(require 'cl-lib)
(require 'async)
(require 'backtrace)
(require 'concur-promise)
(require 'coroutines)
(require 'tabulated-list)

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
;;; NEW: Promise Registry & Inspector (for Debugging)

(defcustom concur-enable-promise-registry t
  "If non-nil, register all created promises for inspection.
This is a powerful debugging tool but adds a small overhead.
Use `concur:inspect-promises` to view the registry."
  :type 'boolean
  :group 'concur)

(defvar concur--promise-registry (make-hash-table :test 'eq)
  "A global registry of promises for introspection.
The keys are promise objects and values are `concur--promise-info` structs.")

(defvar concur--promise-id-counter 0
  "A counter to assign unique IDs to promises for the registry.")

(cl-defstruct (concur--promise-info (:type vector))
  "A struct to hold debugging information about a promise.

Fields:
- id (integer): A unique identifier for the promise.
- state (keyword): The current state (:pending, :resolved, :rejected).
- name (string): The user-provided name or label for the promise.
- created (time): The timestamp when the promise was created.
- settled (time): The timestamp when the promise was settled.
- value (any): The resolution value or rejection error.
- backtrace (string): The stack trace at the point of creation."
  (id 0 :type integer)
  (state :pending :type keyword)
  name
  (created (current-time) :type (or null cons))
  settled
  value
  (backtrace (backtrace-to-string (backtrace)) :type string))

(defun concur--register-promise (promise name)
  "Register a new PROMISE with NAME in the global registry.
This function attaches a `tap` to the promise to automatically update
its state upon settlement.

Arguments:
- PROMISE (`concur-promise`): The promise to register.
- NAME (string): The name or label for this promise."
  (when concur-enable-promise-registry
    (let* ((id (cl-incf concur--promise-id-counter))
           (info (make-concur--promise-info :id id :state :pending :name name)))
      (puthash promise info concur--promise-registry)
      ;; Use `concur:tap` to update the state upon settlement without
      ;; affecting the promise chain.
      (concur:tap promise
                  (lambda (val err)
                    (concur--update-promise-state promise val err))))))

(defun concur--update-promise-state (promise val err)
  "Update the state of a registered PROMISE when it settles.

Arguments:
- PROMISE (`concur-promise`): The promise that has settled.
- VAL (any): The resolved value (if `err` is nil).
- ERR (any): The rejected error (if non-nil)."
  (when-let ((info (gethash promise concur--promise-registry)))
    (setf (concur--promise-info-settled info) (current-time))
    (if err
        (setf (concur--promise-info-state info) :rejected
              (concur--promise-info-value info) err)
      (setf (concur--promise-info-state info) :resolved
            (concur--promise-info-value info) val))))

(defun concur--format-time-ago (start-time)
  "Format the duration since START-TIME as a human-readable string.

Arguments:
- START-TIME (time): A time value, e.g., from `current-time`.

Returns:
A string like \"1.23s ago\"."
  (if (null start-time)
      "N/A"
    (cl-destructuring-bind (_s _ms microsec . _tz) (time-since start-time)
      (format "%.2fs ago" (+ (float _s) (/ (float microsec) 1000000.0))))))

;;;###autoload
(defun concur:inspect-promises ()
  "Display a live, interactive list of all registered promises.
This command opens a `tabulated-list-mode` buffer showing the ID,
name, state, and age of all promises tracked by the registry.

Commands in the inspector buffer:
- `g`: Refresh the list.
- `d`: Display detailed info for the promise on the current line.
- `q`: Quit the inspector."
  (interactive)
  (let ((entries
         (sort (--map-values
                (lambda (info)
                  (let* ((id (concur--promise-info-id info))
                         (state (symbol-name (concur--promise-info-state info)))
                         (name (format "%s" (concur--promise-info-name info)))
                         (created (concur--promise-info-created info))
                         (age (concur--format-time-ago created)))
                    ;; The entry is the ID and a vector of displayable data.
                    (list id (vector (format "%s" id) name state age info))))
                concur--promise-registry)
               ;; Sort entries by ID.
               (lambda (a b) (< (car a) (car b))))))
    (with-current-buffer (get-buffer-create "*Concur Inspector*")
      (let ((inhibit-read-only nil))
        (erase-buffer)
        (concur-inspector-mode)
        (setq tabulated-list-entries entries)
        (tabulated-list-init-header)
        (tabulated-list-print t)
        (goto-char (point-min))
        (setq-local inhibit-read-only t))
      (display-buffer (current-buffer)))))

(define-derived-mode concur-inspector-mode tabulated-list-mode "Concur Inspector"
  "A mode for inspecting concurrent promises."
  :group 'concur
  (setq tabulated-list-format
        [("ID" 4 t)
         ("Name" 30 t)
         ("State" 10 t)
         ("Age" 15 t)])
  (setq tabulated-list-sort-key (cons "ID" nil))
  (define-key tabulated-list-mode-map (kbd "d")
    (lambda ()
      (interactive)
      (when-let* ((line (tabulated-list-get-entry))
                  (info (aref line 4)))
        (with-help-window (help-buffer)
          (with-current-buffer (help-buffer)
            (princ "Promise Details:\n")
            (pp info (current-buffer)))))))
  (define-key tabulated-list-mode-map (kbd "g")
    (lambda () (interactive) (revert-buffer)))
  (define-key tabulated-list-mode-map (kbd "q")
    (lambda () (interactive) (quit-window))))

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
            (:then (lambda (_sem-acquired) task-promise))
            ;; 3. No matter what, release the semaphore when the task is done.
            (:finally (lambda (_v _e)
                        (concur:semaphore-release semaphore)))))
         tasks))

(eval-when-compile
  ;; Helper function to parse keyword arguments from a list of forms for macros.
  (defun concur--parse-macro-keywords (forms keywords)
    "Parse KEYWORDS from FORMS list and return a property list.
This is a macro-expansion-time helper. It assumes the first element
of FORMS is the primary, non-keyword argument.

Example: (concur--parse-macro-keywords '(my-items :fn #'foo) '(:fn))
         => (:primary-form my-items :fn #'foo)"
    (let ((primary-form (car forms))
          (plist nil)
          (remaining-args (cdr forms)))
      (while remaining-args
        (let ((key (pop remaining-args)))
          (if (memq key keywords)
              (progn
                (unless remaining-args (error "Keyword %S lacks a value" key))
                (setq plist (plist-put plist key (pop remaining-args))))
            (error "Invalid keyword in macro form: %S" key))))
      (plist-put plist :primary-form primary-form))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

(cl-defun concur:async! (fn mode &key name cancel-token require form)
  "Run FN asynchronously according to MODE and return a `concur-promise`.

Arguments:
- FN (function): The zero-argument function (thunk) to execute. This is
  ignored if the `:form` keyword is used with `'async` mode.
- MODE (symbol or number): The execution mode.
  - `nil`, `t`, or `'deferred`: Schedule for the next idle cycle.
  - A `number`: Delay execution by that many seconds.
  - `'async`: Run in a background Emacs process. See `:require` and `:form`.
  - `'thread`: Run in a native Emacs thread (for CPU-bound tasks).

Keywords:
- :NAME (string, optional): A human-readable name for the operation.
- :CANCEL-TOKEN (`concur-cancel-token`): Token to interrupt execution.
- :REQUIRE (list, optional): For `'async` mode only. A list of library
  symbols to `require` in the background process before execution.
- :FORM (sexp, optional): For `'async` mode only. The Lisp form to
  evaluate. Using this is more robust than passing a closure `fn`.

Returns:
A `concur-promise` that will resolve with the result of FN or :FORM, or
reject if the operation fails or is cancelled."
  (let* ((label (or name (format "async-%S" (or form fn))))
         ;; Dynamically bind the stack to trace nested async calls.
         (concur-async--stack (cons label concur-async--stack)))
    (let ((promise
           (let ((task-wrapper
                  ;; This wrapper handles execution, error handling, and hooks.
                  (lambda (resolve-fn reject-fn)
                    (concur-async--run-hooks :started label (concur:make-promise))
                    (condition-case err
                        (let ((result (funcall fn)))
                          (concur-async--run-hooks
                           :succeeded label (concur:resolved! result))
                          (funcall resolve-fn result))
                      (error
                       (let ((err-cond `(concur-async-error
                                        :original-error ,err)))
                         (concur-async--run-hooks
                          :failed label (concur:rejected! err-cond) err-cond)
                         (funcall reject-fn err-cond)))))))
             (pcase mode
               ;; Deferred: Run on the next idle cycle.
               ((or 'deferred 't (pred null))
                (concur:with-executor
                    (lambda (resolve reject)
                      (run-at-time
                       0 nil (lambda () (funcall task-wrapper resolve reject))))
                  :cancel-token cancel-token))

               ;; Delayed: Run after a specific delay.
               ((pred numberp)
                (concur:with-executor
                    (lambda (resolve reject)
                      (run-at-time
                       mode nil (lambda () (funcall task-wrapper resolve reject))))
                  :cancel-token cancel-token))

               ;; Background Process: Run in a separate Emacs process.
               ('async
                (let* ((require-forms
                        (mapcar (lambda (lib) `(require ',lib)) require))
                       (eval-form (or form `(funcall ,fn)))
                       (lisp-form `(progn ,@require-forms ,eval-form)))
                  (concur:from-callback
                   (lambda (cb)
                     ;; Wrap the lisp-form to inject the load-path
                     ;; from the parent process into the child.
                     (async-start ; `async-start` evaluates the form in a new Emacs.
                      (async-inject-variables `((load-path . ,load-path))
                                              lisp-form)
                      cb)))))

               ;; Native Thread: Run in a separate Lisp thread.
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
                              (run-with-timer
                               0.01 0.01
                               (lambda ()
                                 (when-let ((result (car mailbox)))
                                   (cancel-timer timer)
                                   (pcase result
                                     (`(:success . ,val) (funcall resolve val))
                                     (`(:failure . ,err)
                                      (funcall reject
                                               `(concur-async-error
                                                 :original-error ,err))))))))))
                  :cancel-token cancel-token))

               ;; Unknown mode: Reject immediately.
               (_ (concur:rejected! `(concur-async-error
                                      "Unknown async mode" ,mode)))))))
      (concur--register-promise promise label)
      promise)))

;;;###autoload
(defun concur:deferred! (fn &key name cancel-token)
  "Run FN asynchronously in a deferred manner and return a `concur-promise`.
This is a convenience wrapper for `(concur:async! fn 'deferred ...)`.

Arguments:
- FN (function): The zero-argument function (thunk) to execute.
- NAME (string, optional): A human-readable name for the operation.
- CANCEL-TOKEN (`concur-cancel-token`): Token to interrupt execution.

Returns:
A `concur-promise` that resolves with the result of FN."
  (concur:async! fn 'deferred :name name :cancel-token cancel-token))

;;;###autoload
(defmacro concur:sequence! (&rest forms)
  "Process ITEMS sequentially with async function FN.
Each item is processed only after the previous one's promise resolves.

Example:
  (concur:sequence! (get-list-of-urls) :fn #'fetch-sequentially)

Arguments:
- forms: An `items-form` that evaluates to a list, followed by keywords.

Keywords:
- :fn (function): An async fn `(lambda (item))` that returns a promise.
- :semaphore (`concur-semaphore`): Semaphore to acquire before each step."
  (declare (indent 1) (debug t))
  (let* ((parsed-args (concur--parse-macro-keywords forms '(:fn :semaphore)))
         (items-form (plist-get parsed-args :primary-form))
         (fn-form (plist-get parsed-args :fn))
         (semaphore-form (plist-get parsed-args :semaphore)))
    (unless fn-form (error "concur:sequence! requires the :fn keyword"))
    `(let ((items ,items-form)
           (fn ,fn-form)
           (semaphore ,semaphore-form))
       (if semaphore
           ;; If there's a semaphore, wrap the original function `fn` with
           ;; semaphore acquisition and release logic for each item.
           (let ((sem-fn (lambda (item)
                           (concur:chain
                            (concur:promise-semaphore-acquire semaphore)
                            (:then (lambda (_) (funcall fn item)))
                            (:finally (lambda (_v _e)
                                        (concur:semaphore-release semaphore)))))))
             (concur:map-series items sem-fn))
         ;; Otherwise, just use the original function directly.
         (concur:map-series items fn)))))

;;;###autoload
(defmacro concur:parallel! (&rest forms)
  "Process ITEMS in parallel with async function FN, with optional throttling.

Example:
  (concur:parallel! (get-list-of-files)
                    :fn #'process-file-async
                    :semaphore (concur:make-semaphore 4))

Arguments:
- forms: An `items-form` that evaluates to a list, followed by keywords.

Keywords:
- :fn (function): An async fn `(lambda (item))` that returns a promise.
- :semaphore (`concur-semaphore`): A semaphore to limit concurrency."
  (declare (indent 1) (debug t))
  (let* ((parsed-args (concur--parse-macro-keywords forms '(:fn :semaphore)))
         (items-form (plist-get parsed-args :primary-form))
         (fn-form (plist-get parsed-args :fn))
         (semaphore-form (plist-get parsed-args :semaphore)))
    (unless fn-form (error "concur:parallel! requires the :fn keyword"))
    `(let* ((items ,items-form)
            (fn ,fn-form)
            (semaphore ,semaphore-form)
            ;; Eagerly create all promises.
            (tasks (--map (funcall fn it) items)))
       (if semaphore
           ;; Let the semaphore wrapper control execution flow.
           (concur:all (concur-async--apply-semaphore-to-tasks tasks semaphore))
         (concur:all tasks)))))

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple asynchronous operations and settle with the first to finish.

Arguments:
- FORMS: A sequence of forms, each evaluating to a `concur-promise`.

Keywords:
- :SEMAPHORE (`concur-semaphore`, optional): A semaphore to apply to each
  operation for throttling purposes.

Returns:
A `concur-promise` that settles with the value or error of the first
form to complete."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let* ((awaitables (list ,@task-forms))
            (semaphore ,sem-form))
       (if semaphore
           (concur:race
            (concur-async--apply-semaphore-to-tasks awaitables semaphore))
         (concur:race awaitables)))))

;;;###autoload
(defmacro concur:any! (&rest forms)
  "Return a promise resolving with the first of FORMS to resolve successfully.
If all FORMS reject, the returned promise rejects with an aggregate error.

Example:
  (concur:any!
    (http-get \"mirror1\")
    (http-get \"mirror2\"))

Arguments:
- FORMS: A sequence of forms, each evaluating to a `concur-promise`.

Keywords:
- :SEMAPHORE (`concur-semaphore`, optional): A semaphore for throttling.

Returns:
A `concur-promise` that resolves with the first successful result."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let* ((awaitables (list ,@task-forms))
            (semaphore ,sem-form))
       (if semaphore
           (concur:any
            (concur-async--apply-semaphore-to-tasks awaitables semaphore))
         (concur:any awaitables)))))

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
(defmacro concur:unwind-protect! (body-form &rest cleanup-forms)
  "Execute BODY-FORM and guarantee CLEANUP-FORMS run afterward.
This is the asynchronous equivalent of `unwind-protect`.

The BODY-FORM should evaluate to a promise. The returned promise will adopt
the settlement (resolution or rejection) of the BODY-FORM's promise, but
only after the promise generated by the CLEANUP-FORMS has completed.

Arguments:
- BODY-FORM: The main asynchronous operation; a single form that
  evaluates to a promise.
- CLEANUP-FORMS: One or more forms to execute for cleanup. These are
  wrapped in a `(lambda () ...)` and executed by `concur:finally`."
  (declare (indent 1) (debug t))
  `(concur:finally ,body-form
                   (lambda (_v _e) ,@cleanup-forms)))

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
         (let ((promise (concur:from-coroutine
                         (apply #',coro-name (list ,@fn-args))
                         cancel-token)))
           (concur--register-promise promise ',name)
           promise)))))

;;;###autoload
(defmacro concur:while! (condition-form &rest body)
  "Execute BODY asynchronously while CONDITION-FORM resolves to non-nil.
Both CONDITION-FORM and BODY are forms that should evaluate to a promise.
The loop waits for the condition promise to resolve. If its value is
non-nil, it waits for the body promise to resolve, then repeats.

Arguments:
- CONDITION-FORM: A form that returns a promise. The loop continues
  as long as this promise resolves to a non-nil value.
- BODY: One or more forms that return a promise, executed on each
  iteration.

Returns:
A promise that resolves to `nil` when the loop terminates."
  (declare (indent 1) (debug t))
  (let ((coro-name (gensym "while-coro-")))
    `(let ((promise
            (concur:from-coroutine
             (defcoroutine! ,coro-name ()
               "Internal coroutine for `concur:while!`."
               (while (yield ,condition-form)
                 (yield (progn ,@body)))
               nil)))) ; while loop resolves to nil
       (concur--register-promise promise 'while!)
       promise)))

;;;###autoload
(cl-defun concur:map-pool (items fn &key (size 4) (cancel-token nil))
  "Process ITEMS using async FN, with a concurrency limit of SIZE.
This function creates a pool of coroutines to process items in parallel,
but limits the number of concurrently running coroutines to SIZE.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): An async fn `(lambda (item))` that returns a coroutine runner.

Keywords:
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
               (completed 0)
               (error-occured nil))
          (cl-labels
              ((process-next ()
                 (when (not error-occured)
                   (while (and (< in-flight size) item-queue)
                     (let* ((item (pop item-queue))
                            ;; `runner` must be a coroutine.
                            (runner (funcall fn item))
                            (index (- total (length item-queue) 1)))
                       (cl-incf in-flight)
                       (concur:then
                        (concur:from-coroutine runner)
                        (lambda (res)
                          (aset results index res)
                          (cl-decf in-flight)
                          (cl-incf completed)
                          (if (= completed total)
                              (funcall resolve-executor
                                       (cl-coerce results 'list))
                            (process-next)))
                        (lambda (err)
                          (unless error-occured
                            (setq error-occured t)
                            (funcall reject-executor err)))))))))
            (if (null items)
                (funcall resolve-executor nil)
              (process-next))))) 
        :cancel-token cancel-token))

;;;###autoload
(defun concur:coroutine-all (runners &key semaphore)
  "Run a list of coroutine RUNNERS in parallel and wait for all to complete.

Arguments:
- RUNNERS (list): A list of coroutine runner functions.

Keywords:
- :SEMAPHORE (`concur-semaphore`): A semaphore to limit concurrency.

Returns:
A promise that resolves with a list of all results, or rejects if any
of the coroutines reject."
  (let* ((promises (--map (concur:from-coroutine it) runners)))
    (if semaphore
        (concur:all (concur-async--apply-semaphore-to-tasks promises semaphore))
      (concur:all promises))))

;;;###autoload
(defun concur:coroutine-race (runners &key semaphore)
  "Race a list of coroutine RUNNERS in parallel.

Arguments:
- RUNNERS (list): A list of coroutine runner functions.

Keywords:
- :SEMAPHORE (`concur-semaphore`): A semaphore to limit concurrency.

Returns:
A promise that settles with the first coroutine to settle."
  (let* ((promises (--map (concur:from-coroutine it) runners)))
    (if semaphore
        (concur:race (concur-async--apply-semaphore-to-tasks promises semaphore))
      (concur:race promises))))

(provide 'concur-async)
;;; concur-async.el ends here




