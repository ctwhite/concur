;;; concur-async.el --- High-level async primitives for Emacs -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This library provides a suite of high-level asynchronous primitives that
;; build upon the foundational `concur-promise` system. It aims to make
;; complex asynchronous workflows easy to write and reason about.
;;
;; Core Features:
;;
;; - `concur:async!`: A unified entry point for running tasks in different
;;   execution contexts: deferred (on a timer), delayed, in a background
;;   Emacs process (`async.el`), or in a native thread.
;;
;; - Async Iteration: `concur:sequence!` and `concur:parallel!` provide
;;   powerful macro-based iteration over collections with asynchronous
;;   functions, with support for concurrency limiting via semaphores.
;;
;; - Promise Composition: `concur:let-promise` and `concur:let-promise*`
;;   offer `let`-like bindings for managing parallel and sequential promise
;;   workflows, respectively. `concur:race!` and `concur:any!` handle
;;   scenarios where only the first settled or first successful promise matters.
;;
;; - Python `multiprocessing.Pool` Equivalents: Functions like
;;   `concur:map-async!`, `concur:apply-async!`, and `concur:imap!` mirror
;;   the powerful API of Python's multiprocessing library, making it easy
;;   to offload work to a pool of background Emacs processes.
;;
;; - Debugging and Introspection: An integrated promise inspector
;;   (`concur:inspect-promises`) provides a live view of all active and
-;;   settled promises, an invaluable tool for debugging concurrent systems.
;;
;; - Advanced Features: Includes automatic dependency derivation for
;;   background processes, task batching (`concur:batch!`), and adaptive
;;   concurrency pools.

;;; Code:

(require 'cl-lib)
(require 'async)
(require 'backtrace)
(require 'coroutines)
(require 'tabulated-list)
(require 'yield)

;; Core Concur modules
(require 'concur-promise)
(require 'concur-primitives)
(require 'concur-future)

(eval-when-compile (require 'cl-lib))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Customization, Hooks, & Errors

(defcustom concur-async-enable-tracing t
  "If non-nil, record and log async stack traces for `concur:async!` tasks."
  :type 'boolean :group 'concur)

(defcustom concur-async-hooks nil
  "Hook run during `concur:async!` lifecycle events.
Each function receives `(EVENT LABEL PROMISE &optional ERROR)` where
EVENT is one of `:started`, `:succeeded`, `:failed`, `:cancelled`."
  :type 'hook :group 'concur-hooks)

(define-error 'concur-async-error "Concurrency async operation error.")
(define-error 'concur-timeout "Concurrency timeout error.")
(define-error 'concur-async-process-error "Error in background async proc.")

(defcustom concur-async-default-chunksize 10
  "Default chunk size for `concur:map-async!` and `concur:imap-await!`."
  :type 'integer :group 'concur-async)

(defcustom concur-async-default-batch-size 10
  "Default batch size for `concur:batch!` operations."
  :type 'integer :group 'concur-async)

(defcustom concur-async-default-batch-timeout-ms 50
  "Default batch timeout (in milliseconds) for `concur:batch!`."
  :type 'number :group 'concur-async)

(defvar concur--async-derivation-map nil
  "A mapping from missing function symbols to features that provide them.")

(defcustom concur-async-adaptive-pool-min-size 1
  "Minimum concurrency for adaptive pools used by `concur:parallel!`."
  :type 'integer :group 'concur)

(defcustom concur-async-adaptive-pool-max-size 100
  "Maximum concurrency for adaptive pools used by `concur:parallel!`."
  :type 'integer :group 'concur)

(defcustom concur-async-adaptive-pool-interval 0.5
  "Interval (in seconds) for adaptive pool adjustments."
  :type 'float :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Promise Registry & Inspector (Debugging)

(defcustom concur-enable-promise-registry t
  "If non-nil, register all created promises for inspection."
  :type 'boolean :group 'concur)

(defvar concur--promise-registry (make-hash-table :test 'eq)
  "A global registry of promises for introspection.")

(defvar concur--promise-id-counter 0
  "A counter to assign unique IDs to promises for the registry.")

(cl-defstruct (concur--promise-info (:type vector))
  "A struct to hold debugging information about a promise."
  (id 0 :type integer)
  (state :pending :type keyword)
  name
  (created (current-time) :type (or null cons))
  settled
  value
  (backtrace (backtrace-to-string (backtrace)) :type string))

(cl-defun concur--register-promise (promise name)
  "Register a new PROMISE with NAME in the global registry.

This function assigns a unique ID to the promise and attaches a
callback to update its state in the registry upon settlement.

Arguments:
- PROMISE (`concur-promise`): The promise to register.
- NAME (any): A descriptive name for the promise's task.

Returns:
- nil."
  (when concur-enable-promise-registry
    (let* ((id (cl-incf concur--promise-id-counter))
           (info (make-concur--promise-info :id id :state :pending :name name)))
      (puthash promise info concur--promise-registry)
      ;; Attach a callback to the promise that will update its entry in the
      ;; registry once it settles. `concur:finally` is used here as a "tap",
      ;; allowing us to observe the result without affecting the promise chain.
      (concur:finally promise
                      (lambda (val err)
                        (concur--update-promise-state promise val err))))))

(cl-defun concur--update-promise-state (promise val err)
  "Update the state of a registered PROMISE when it settles.

This is the callback function used by `concur--register-promise`.

Arguments:
- PROMISE (`concur-promise`): The promise that has settled.
- VAL (any): The resolved value of the promise, or nil if rejected.
- ERR (any): The rejection error of the promise, or nil if resolved.

Returns:
- nil."
  (when-let ((info (gethash promise concur--promise-registry)))
    (setf (concur--promise-info-settled info) (current-time))
    (if err
        (setf (concur--promise-info-state info) :rejected
              (concur--promise-info-value info) err)
      (setf (concur--promise-info-state info) :resolved
            (concur--promise-info-value info) val))))

(cl-defun concur--format-time-ago (start-time)
  "Format the duration since START-TIME as a human-readable string."
  (if (null start-time)
      "N/A"
    (cl-destructuring-bind (s _ms us . _tz) (time-since start-time)
      (format "%.2fs ago" (+ (float s) (/ (float us) 1000000.0))))))

;;;###autoload
(cl-defun concur:inspect-promises ()
  "Display a live, interactive list of all registered promises.

The inspector opens in a new buffer (`*Concur Inspector*`) and provides
a tabulated list of all promises created while the registry is enabled.
Keybindings allow for viewing detailed promise information (`d`),
refreshing the list (`g`), and quitting (`q`).

Arguments:
- None.

Returns:
- nil."
  (interactive)
  (let ((entries
         (sort (--map-values
                (lambda (info)
                  (let* ((id (concur--promise-info-id info))
                         (state (symbol-name (concur--promise-info-state info)))
                         (name (format "%s" (concur--promise-info-name info)))
                         (created (concur--promise-info-created info))
                         (age (concur--format-time-ago created)))
                    (list id (vector (format "%s" id) name state age info))))
                concur--promise-registry)
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
        [("ID" 4 t) ("Name" 30 t) ("State" 10 t) ("Age" 15 t)])
  (setq tabulated-list-sort-key (cons "ID" nil))
  (define-key tabulated-list-mode-map (kbd "d")
    (lambda ()
      (interactive)
      (when-let* ((line (tabulated-list-get-entry)) (info (aref line 4)))
        (with-help-window (help-buffer)
          (with-current-buffer (help-buffer)
            (princ "Promise Details:\n") (pp info (current-buffer)))))))
  (define-key tabulated-list-mode-map (kbd "g")
    (lambda () (interactive) (revert-buffer)))
  (define-key tabulated-list-mode-map (kbd "q")
    (lambda () (interactive) (quit-window))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal State & Helpers

(defvar-local concur-async--stack '()
  "Buffer-local dynamic stack of async task labels for tracing.")

(cl-defun concur-async--run-hooks (event label promise &optional error)
  "Run `concur-async-hooks` for a given lifecycle event."
  (run-hook-with-args 'concur-async-hooks event label promise error))

(cl-defun concur-async--format-trace ()
  "Return a formatted string of the current async stack."
  (mapconcat (lambda (frame) (format "↳ %s" frame))
             (reverse concur-async--stack) "\n"))

(cl-defun concur-async--apply-semaphore-to-tasks (tasks semaphore)
  "Wrap each task promise in TASKS with semaphore acquisition/release logic.

This is a helper for `concur:race!` and `concur:any!` to ensure that
each task acquires the semaphore before it runs and releases it upon
completion, regardless of success or failure.

Arguments:
- TASKS (list of `concur-promise`): The promises representing the tasks.
- SEMAPHORE (`concur-semaphore`): The semaphore to use for throttling.

Returns:
- (list of `concur-promise`): A new list of promises, each wrapped
  in semaphore logic."
  (--map (lambda (task-promise)
           (concur:finally
            (concur:then (concur:promise-semaphore-acquire semaphore)
                         ;; Once the semaphore is acquired, chain to the original task.
                         (lambda (_) task-promise))
            ;; No matter how the task promise settles, release the semaphore.
            (lambda (_v _e) (concur:semaphore-release semaphore))))
         tasks))

(eval-and-compile
  (cl-defun concur--parse-macro-keywords (forms keywords)
    "Parse KEYWORDS from FORMS list and return a property list.

This is a macro-writing helper to easily support keyword arguments
in custom macros like `concur:sequence!`.

Arguments:
- FORMS (list): The body of the macro call.
- KEYWORDS (list of symbol): The keywords to look for.

Returns:
- (plist): A property list with parsed keys and values, and a special
  `:primary-form` key for the main non-keyword argument."
    (let ((primary-form (car forms)) (plist nil) (remaining-args (cdr forms)))
      (while remaining-args
        (let ((key (pop remaining-args)))
          (if (memq key keywords)
              (progn
                (unless remaining-args (error "Keyword %S lacks a value" key))
                (setq plist (plist-put plist key (pop remaining-args))))
            (error "Invalid keyword in macro form: %S" key))))
      (plist-put plist :primary-form primary-form))))

(cl-defun concur--async-child-proc-eval (exec-future features-to-require
                                         current-load-path)
  "Constructs the Lisp form to be evaluated in the `async` child process."
  `(let ((default-directory "~/") (load-path ,current-load-path))
     ;; Ensure the child process has the necessary libraries loaded.
     (dolist (feature ',features-to-require)
       (condition-case err (require feature)
         (error (message "Async process failed to require %s: %S" feature err))))
     ;; Execute the future's code and wrap it in condition-case to
     ;; reliably capture and serialize errors back to the parent process.
     (condition-case err
         (concur:force ',exec-future)
       (void-function
        (list :error 'void-function (cadr err) (error-message-string err)
              (with-output-to-string (print-backtrace))))
       (error
        (list :error 'general-error (error-message-string err)
              (with-output-to-string (print-backtrace)))))))

(cl-defun concur--handle-async-proc-result
    (result retries max-retries derive-mapping resolve-cb reject-cb
            run-job-fn features-ref)
  "Helper to handle the result from an `async-start` process.

This function implements the automatic dependency derivation logic. If the
child process fails with a `void-function` error, it attempts to find a
matching feature in `derive-mapping`, add it to the list of required
features, and retry the job.

Arguments:
- See `concur--async-run-with-derivation` for argument descriptions.

Returns:
- nil. Calls `resolve-cb` or `reject-cb`."
  (pcase result
    ;; Case 1: A function was not defined in the child process.
    (`(:error 'void-function ,missing-func ,msg ,trace)
     (if (< retries max-retries)
         (progn
           (cl-incf retries)
           (message "Concur: Async void-func '%s'. Deriving & retrying..."
                    missing-func)
           ;; Try to find the feature that provides the missing function.
           (let ((found-feature (cdr (assoc missing-func derive-mapping))))
             (if found-feature
                 (progn
                   (pushnew found-feature (car features-ref))
                   (funcall run-job-fn)) ; Retry the job with the new feature.
               ;; If no feature is found, fail permanently.
               (funcall reject-cb
                        `(concur-async-process-error
                          :unresolved-void-function ,missing-func
                          :original-error-message ,msg :backtrace ,trace)))))
       ;; Case 2: Max retries exceeded for a void-function error.
       (funcall reject-cb
                `(concur-async-process-error
                  :max-retries-void-function ,missing-func
                  :original-error-message ,msg :backtrace ,trace))))
    ;; Case 3: A general error occurred in the child process.
    (`(:error ,type ,msg ,trace)
     (funcall reject-cb
              `(concur-async-process-error
                :async-process-error ,type
                :original-error-message ,msg :backtrace ,trace)))
    ;; Case 4: The child process completed successfully.
    (_ (funcall resolve-cb result))))

(cl-defun concur--async-run-with-derivation (exec-future init-features
                                             derive-mapping resolve-cb reject-cb
                                             timeout max-retries cancel-token)
  "Orchestrates async execution with dependency derivation and retries.

Arguments:
- EXEC-FUTURE (`concur-future`): The task to execute.
- INIT-FEATURES (list of symbol): Initial libraries to `require`.
- DERIVE-MAPPING (alist): Map of function symbols to feature symbols.
- RESOLVE-CB (function): The function to call on success.
- REJECT-CB (function): The function to call on failure.
- TIMEOUT (number): Timeout for the process.
- MAX-RETRIES (integer): Max retries for derivation.
- CANCEL-TOKEN (`concur-cancel-token`): Token for cancellation.

Returns:
- nil."
  (let ((retries 0)
        (features-ref (list (copy-sequence init-features))))
    (cl-flet ((run-job ()
                (async-start
                 (concur--async-child-proc-eval
                  exec-future (car features-ref) load-path)
                 (lambda (result)
                   (concur--handle-async-proc-result
                    result retries max-retries derive-mapping
                    resolve-cb reject-cb #'run-job features-ref))
                 :process-timeout timeout
                 :cancel-token cancel-token)))
      (run-job))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Mode-specific Helpers for concur:async!)

(cl-defun concur--async-run-deferred-task (task-wrapper cancel-token)
  "Executes a task in 'deferred mode (run-at-time 0)."
  (concur:with-executor
      (lambda (resolve reject)
        (run-at-time 0 nil (lambda () (funcall task-wrapper resolve reject))))
    :cancel-token cancel-token))

(cl-defun concur--async-run-delayed-task (task-wrapper delay-seconds cancel-token)
  "Executes a task in 'delayed mode (run-at-time N)."
  (concur:with-executor
      (lambda (resolve reject)
        (run-at-time delay-seconds nil
                     (lambda () (funcall task-wrapper resolve reject))))
    :cancel-token cancel-token))

(cl-defun concur--async-run-async-process-task (fn form label cancel-token
                                                 require derive-mapping
                                                 timeout max-retries)
  "Executes a task in 'async mode (background Emacs process)."
  (let* ((exec-future
          (cond (fn (concur:make-future (lambda () (funcall fn))))
                (form (concur:make-future (lambda () form)))
                (t (error "Either :fn or :form required for 'async mode"))))
         (initial-requires (or require nil)))
    (concur:from-callback
     (lambda (resolve reject)
       (concur--async-run-with-derivation
        exec-future initial-requires derive-mapping
        resolve reject timeout max-retries cancel-token)))))

(cl-defun concur--async-run-thread-task (fn label cancel-token)
  "Executes a task in 'thread mode (native Emacs thread)."
  (concur:with-executor
      (lambda (resolve reject)
        (let ((mailbox (list nil)) timer)
          ;; Create a native thread to run the task.
          (make-thread
           (lambda ()
             (condition-case err
                 (setcar mailbox (cons :success (funcall fn)))
               (error (setcar mailbox (cons :failure err)))))
           (format "concur-thread-%s" label))
          ;; Poll the mailbox with a timer to get the result back to the main thread.
          (setq timer
                (run-at-time
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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API (Main Functions)

(cl-defun concur:async! (fn mode &key name cancel-token require form
                         (derive-mapping concur--async-derivation-map)
                         timeout (max-derivation-retries 2))
  "Run FN asynchronously according to MODE and return a `concur-promise`.

This is the main entry point for running asynchronous tasks. It
dispatches to different execution strategies based on `MODE`.

Arguments:
- FN (function or nil): The nullary function to execute asynchronously.
  Can be nil if `:form` is provided for the 'async mode.
- MODE (symbol or number): The execution mode.
  - `deferred` or `t`: Execute on an idle timer (non-blocking).
  - (number): Execute after a delay of MODE seconds.
  - `async`: Execute in a background Emacs process via `async.el`.
  - `thread`: Execute in a native Emacs thread via `make-thread`.
- :name (string, optional): A descriptive name for the task, used for logging
  and the inspector.
- :cancel-token (`concur-cancel-token`, optional): A token for cancellation.
- :require (list of symbol, optional): For 'async' mode, a list of features
  to `require` in the child process before execution.
- :form (any, optional): For 'async' mode, a Lisp form to evaluate
  instead of calling `FN`.
- :derive-mapping (alist, optional): For 'async' mode, an alist mapping
  function symbols to feature symbols for automatic dependency loading.
- :timeout (number, optional): For 'async' mode, a timeout in seconds.
- :max-derivation-retries (integer, optional): For 'async' mode, the
  maximum number of times to retry on a `void-function` error.

Returns:
- (`concur-promise`): A promise that will settle with the result of `FN`."
  (let* ((label (or name (format "async-%S" (or form fn))))
         (concur-async--stack (cons label concur-async--stack)))
    (let ((promise
           ;; This wrapper function is the core task logic. It's passed to the
           ;; various execution mode helpers. It calls the original function `fn`,
           ;; runs lifecycle hooks, and handles errors.
           (let ((task-wrapper
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
                         (funcall reject-fn err-cond)))))))))
      (pcase mode
        ((or 'deferred 't (pred null))
         (concur--async-run-deferred-task task-wrapper cancel-token))
        ((pred numberp)
         (concur--async-run-delayed-task task-wrapper mode cancel-token))
        ('async
         (concur--async-run-async-process-task
          fn form label cancel-token require derive-mapping timeout max-retries))
        ('thread (concur--async-run-thread-task fn label cancel-token))
        (_ (concur:rejected! `(concur-async-error "Unknown mode" ,mode))))))
      (concur--register-promise promise label) promise))

;;;###autoload
(cl-defun concur:deferred! (fn &key name cancel-token)
  "Run FN asynchronously in a deferred manner and return a `concur-promise`.
This is a convenient shorthand for `(concur:async! fn 'deferred ...)`.

Arguments:
- FN (function): The nullary function to execute.
- :name (string, optional): A descriptive name for the task.
- :cancel-token (`concur-cancel-token`, optional): A token for cancellation.

Returns:
- (`concur-promise`): A promise for the result of `FN`."
  (concur:async! fn 'deferred :name name :cancel-token cancel-token))

;;;###autoload
(defmacro concur:sequence! (&rest forms)
  "Process ITEMS sequentially with async function FN.

This macro iterates over `ITEMS`, calling `FN` for each item. Each
call to `FN` is expected to return a promise. The next iteration
will not begin until the promise from the previous iteration has
resolved.

Macro Arguments:
- FORMS (list): The macro body, consisting of the items to process
  followed by keyword arguments.
  - (primary form): An expression that evaluates to the list of items.
  - `:fn` (function): A function that takes one item and returns a promise.
  - `:semaphore` (`concur-semaphore`, optional): A semaphore to acquire
    before processing each item.

Returns:
- (`concur-promise`): A promise that resolves with a list of all results
  when the entire sequence is complete."
  (declare (indent 1) (debug t))
  (let* ((parsed-args (concur--parse-macro-keywords forms '(:fn :semaphore)))
         (items-form (plist-get parsed-args :primary-form))
         (fn-form (plist-get parsed-args :fn))
         (semaphore-form (plist-get parsed-args :semaphore)))
    (unless fn-form (error "concur:sequence! requires the :fn keyword"))
    `(let ((items ,items-form) (fn ,fn-form) (semaphore ,semaphore-form))
       (if semaphore
           (let ((sem-fn
                  (lambda (item)
                    (concur:finally
                     (concur:then (concur:promise-semaphore-acquire semaphore)
                                  (lambda (_) (funcall fn item)))
                     (lambda (_v _e)
                       (concur:semaphore-release semaphore))))))
             (concur:map-series items sem-fn))
         (concur:map-series items fn)))))

;;;###autoload
(defmacro concur:parallel! (&rest forms)
  "Process ITEMS in parallel with async function FN, with optional throttling.

This macro applies `FN` to all `ITEMS` concurrently.

Macro Arguments:
- FORMS (list): The macro body.
  - (primary form): An expression evaluating to the list of items.
  - `:fn` (function): An async function that takes one item and returns a promise.
  - `:semaphore` (`concur-semaphore`, optional): If provided, uses a
    concurrency pool (`concur:map-pool`) limited by the semaphore's size.
  - `:adaptive-sizing` (boolean, optional): If t and using a semaphore,
    enables adaptive sizing for the pool (currently a placeholder).

Returns:
- (`concur-promise`): A promise that resolves with a list of all results
  when all parallel tasks are complete."
  (declare (indent 1) (debug t))
  (let* ((parsed-args (concur--parse-macro-keywords
                       forms '(:fn :semaphore :adaptive-sizing)))
         (items-form (plist-get parsed-args :primary-form))
         (fn-form (plist-get parsed-args :fn))
         (semaphore-form (plist-get parsed-args :semaphore))
         (adaptive-sizing-p (plist-get parsed-args :adaptive-sizing)))
    (unless fn-form (error "concur:parallel! requires the :fn keyword"))
    `(let* ((items ,items-form) (fn ,fn-form) (semaphore ,semaphore-form))
       (if semaphore
           (concur:map-pool items fn
                            :size (concur-semaphore-max-count semaphore)
                            :adaptive-sizing ,adaptive-sizing-p)
         ;; If no semaphore, run all tasks at once.
         (let ((tasks (--map (funcall fn it) items)))
           (concur:all tasks))))))

;;;###autoload
(defmacro concur:race! (&rest forms)
  "Race multiple asynchronous operations and settle with the first to finish.

The returned promise will resolve or reject as soon as the first of
the input `FORMS` resolves or rejects.

Macro Arguments:
- FORMS (list): A list of forms, each evaluating to a promise.
- `:semaphore` (`concur-semaphore`, optional): If provided, each task
  must acquire the semaphore before it can be considered in the race.

Returns:
- (`concur-promise`): A new promise that mirrors the settlement of the
  first promise in `FORMS` to finish."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let* ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (if semaphore
           (concur:race
            (concur-async--apply-semaphore-to-tasks awaitables semaphore))
         (concur:race awaitables)))))

;;;###autoload
(defmacro concur:any! (&rest forms)
  "Return promise resolving with first of FORMS to resolve successfully.

The returned promise will resolve as soon as the first of the input
`FORMS` resolves. If all input forms reject, the returned promise
will reject with an aggregate error.

Macro Arguments:
- FORMS (list): A list of forms, each evaluating to a promise.
- `:semaphore` (`concur-semaphore`, optional): If provided, each task
  must acquire the semaphore before it can be considered.

Returns:
- (`concur-promise`): A promise that resolves with the value of the
  first successfully resolved promise in `FORMS`."
  (declare (indent 1) (debug t))
  (let* ((sem-key-pos (cl-position :semaphore forms))
         (task-forms (if sem-key-pos (cl-subseq forms 0 sem-key-pos) forms))
         (sem-form (when sem-key-pos (nth (1+ sem-key-pos) forms))))
    `(let* ((awaitables (list ,@task-forms)) (semaphore ,sem-form))
       (if semaphore
           (concur:any
            (concur-async--apply-semaphore-to-tasks awaitables semaphore))
         (concur:any awaitables)))))

;;;###autoload
(defmacro concur:let-promise (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises in parallel.

This is analogous to `let`, but for promises. All promise forms in
`BINDINGS` are executed concurrently. The `BODY` is executed only
after all of them have successfully resolved. The variables are bound
to the resolved values.

Macro Arguments:
- BINDINGS (list): A list of `(variable promise-form)` pairs.
- BODY (forms): The Lisp forms to execute after all promises resolve.

Returns:
- (`concur-promise`): A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let ((vars (--map #'car bindings)) (forms (--map #'cadr bindings)))
      `(concur:then (concur:all (list ,@forms))
                    (lambda (results)
                      (cl-destructuring-bind ,vars results ,@body))))))

;;;###autoload
(defmacro concur:let-promise* (bindings &rest body)
  "Execute BODY with BINDINGS resolved from promises sequentially.

This is analogous to `let*`. Each promise-form in `BINDINGS` is
awaited before the next one begins. The resolved value of one
promise can be used in the form of a subsequent promise.

Macro Arguments:
- BINDINGS (list): A list of `(variable promise-form)` pairs.
- BODY (forms): The Lisp forms to execute after all promises resolve.

Returns:
- (`concur-promise`): A promise that resolves with the result of `BODY`."
  (declare (indent 1) (debug t))
  (if (null bindings)
      `(concur:resolved! (progn ,@body))
    (let* ((binding (car bindings)) (var (car binding)) (form (cadr binding)))
      `(concur:then ,form
                    (lambda (,var)
                      (concur:let-promise* ,(cdr bindings) ,@body))))))

;;;###autoload
(defmacro concur:unwind-protect! (body-form &rest cleanup-forms)
  "Execute BODY-FORM and guarantee CLEANUP-FORMS run afterward.

This is the asynchronous equivalent of `unwind-protect`. The `BODY-FORM`
should evaluate to a promise. The `CLEANUP-FORMS` are executed after
the promise settles, regardless of whether it resolved or rejected.

Macro Arguments:
- BODY-FORM (form): A form that evaluates to a promise.
- CLEANUP-FORMS (forms): The forms to execute upon settlement.

Returns:
- (`concur-promise`): A new promise that settles with the same outcome
  as `BODY-FORM`'s promise, but only after `CLEANUP-FORMS` have run."
  (declare (indent 1) (debug t))
  `(concur:finally ,body-form (lambda (_v _e) ,@cleanup-forms)))

;;;###autoload
(defmacro concur:defasync! (name args &rest body)
  "Define an async function NAME that returns a promise.

This macro simplifies the creation of functions that perform
asynchronous work using coroutines (`yield!`). The body of the
function can use `yield!` to await other promises.

Macro Arguments:
- NAME (symbol): The name of the async function to define.
- ARGS (list): The argument list for the function.
- BODY (forms): The body of the coroutine.

Returns:
- (symbol): The function name, `NAME`."
  (declare (indent defun) (debug t))
  (let* ((doc (if (stringp (car body)) (pop body) (format "Async fn %s." name)))
         (coro-name (intern (format "%s--coro" name)))
         (parsed-args (coroutines--parse-defcoroutine-args args))
         (fn-args (car parsed-args)))
    `(progn
       (defcoroutine! ,coro-name ,args ,@body)
       (cl-defun ,name (,@fn-args &key cancel-token)
         ,doc
         (let ((promise (concur:from-coroutine
                         (apply #',coro-name (list ,@fn-args))
                         cancel-token)))
           (concur--register-promise promise ',name) promise)))))

;;;###autoload
(defmacro concur:while! (condition-form &rest body)
  "Execute BODY asynchronously while CONDITION-FORM resolves to non-nil.

This creates an asynchronous loop. `CONDITION-FORM` is awaited, and if
its result is non-nil, the `BODY` is executed (and awaited if it
returns a promise). The loop continues until `CONDITION-FORM`
resolves to nil.

Macro Arguments:
- CONDITION-FORM (form): A form that returns a promise or a value.
- BODY (forms): The loop body to execute.

Returns:
- (`concur-promise`): A promise that resolves to nil when the loop
  terminates."
  (declare (indent 1) (debug t))
  (let ((coro-name (gensym "while-coro-")))
    `(let ((promise
            (concur:from-coroutine
             (defcoroutine! ,coro-name ()
               (while (yield! ,condition-form) (yield (progn ,@body))) nil))))
       (concur--register-promise promise 'while!) promise)))

;;;###autoload
(cl-defun concur:map-pool (items fn &key (size 4) (cancel-token nil)
                           (adaptive-sizing nil))
  "Process ITEMS using async FN, with a concurrency limit of SIZE.

This function creates a pool of workers (limited to `SIZE` concurrent
tasks) to process the `ITEMS` list. It's a powerful tool for
throttling parallel operations to avoid overwhelming system resources.

Arguments:
- ITEMS (list): The list of items to process.
- FN (function): An async function that takes one item and returns a promise.
- :size (integer, optional): The maximum number of concurrent tasks. Default is 4.
- :cancel-token (`concur-cancel-token`, optional): A token to cancel
  the entire pool operation.
- :adaptive-sizing (boolean, optional): Placeholder for future adaptive
  pool sizing logic.

Returns:
- (`concur-promise`): A promise that resolves with a list of all results
  when all items have been processed."
  (concur:with-executor
      (lambda (resolve-executor reject-executor)
        ;; Internal state for the pool manager.
        (let* ((total (length items)) (results (make-vector total nil))
               (item-queue (copy-sequence items)) (in-flight 0) (completed 0)
               (error-occured nil)
               (pool-controller
                (when adaptive-sizing
                  (concur--log :debug "[async:map-pool] Adaptive sizing (placeholder).")
                  t)))
          (cl-labels (;; The main worker function that processes the next item.
                       (process-next ()
                        (when (not error-occured)
                          (when pool-controller
                            (concur--log :debug "[async:map-pool] Adaptive size: %S" size))

                          ;; Launch new workers as long as there are items and we are under the concurrency limit.
                          (while (and (< in-flight size) item-queue)
                            (let* ((item (pop item-queue))
                                   (awaitable (funcall fn item))
                                   ;; Ensure the result of `fn` is a promise.
                                   (promise
                                    (if (typep awaitable 'concur-promise) awaitable
                                      (or (run-hook-with-args-until-success
                                           'concur-normalize-awaitable-hook
                                           awaitable)
                                          (concur:resolved! awaitable))))
                                   ;; Store results in the correct order.
                                   (index (- total (length item-queue) 1)))
                              (unless (typep promise 'concur-promise)
                                (setq promise (concur:rejected!
                                               (error "Failed to normalize item"))))
                              (cl-incf in-flight)
                              ;; Attach handlers to the promise for this item.
                              (concur:then
                               promise
                               (lambda (res) ; On Success
                                 (aset results index res)
                                 (cl-decf in-flight)
                                 (cl-incf completed)
                                 ;; If all items are done, resolve the main promise.
                                 (if (= completed total)
                                     (funcall resolve-executor (cl-coerce results 'list))
                                   ;; Otherwise, try to process the next item.
                                   (process-next)))
                               (lambda (err) ; On Failure
                                 (unless error-occured
                                   (setq error-occured t)
                                   ;; Reject the main promise immediately on the first error.
                                   (funcall reject-executor err)))))))))
            (if (null items) (funcall resolve-executor nil) (process-next))))
    :cancel-token cancel-token)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Optimization Enhancements

;;;###autoload
(defmacro concur:batch! (batch-handler-form
                         &key (size 'concur-async-default-batch-size)
                         (timeout-ms 'concur-async-default-batch-timeout-ms))
  "Define a batchable async function from a BATCH-HANDLER-FORM.

This macro is a function factory. It returns a new function that you can
call multiple times. It will queue up the arguments from each call and
fire a single, batched request using `BATCH-HANDLER-FORM` either when
the queue size reaches `SIZE` or when `TIMEOUT-MS` has passed since
the last item was added.

This is highly effective for reducing the number of I/O operations (e.g.,
database queries, API calls).

Macro Arguments:
- BATCH-HANDLER-FORM (form): A form that evaluates to a function. This
  handler function must accept a single argument (a list of all items in
  the batch) and return a promise that resolves to a list of results,
  one for each item.
- :size (integer): The maximum number of items to collect before flushing.
- :timeout-ms (number): The time in milliseconds to wait before flushing
  an incomplete batch.

Returns:
- (function): A new function that takes a single item and returns a
  promise for that item's individual result."
  (declare (indent 1) (debug t))
  (let ((queue (gensym "batch-queue-"))
        (timer (gensym "batch-timer-"))
        (handler (gensym "batch-handler-")))
    `(let ((,queue nil) (,timer nil) (,handler ,batch-handler-form))
       (flet ((flush-batch ()
                (when ,queue
                  (let* ((batch (nreverse ,queue))
                         (items (mapcar #'car batch))
                         ;; Each queued item has its own resolve/reject pair.
                         (callbacks (mapcar #'cdr batch)))
                    (setq ,queue nil)
                    (when ,timer (cancel-timer ,timer) (setq ,timer nil))
                    ;; Call the user-provided batch handler with the collected items.
                    (concur:then (funcall ,handler items)
                                 (lambda (results) ; On success, resolve each individual promise.
                                   (cl-loop for res in results
                                            for (res-cb _rej-cb) in callbacks
                                            do (funcall res-cb res)))
                                 (lambda (err) ; On failure, reject all promises in the batch.
                                   (cl-loop for (_res-cb rej-cb) in callbacks
                                            do (funcall rej-cb err))))))))
         ;; This is the function that the macro returns.
         (lambda (item)
           (concur:with-executor
               (lambda (resolve reject)
                 (push (cons item (list resolve reject)) ,queue)
                 ;; Reset the flush timer whenever a new item is added.
                 (when ,timer (cancel-timer ,timer) (setq ,timer nil))
                 (unless (>= (length ,queue) ,size)
                   (setq ,timer (run-at-time (/ (float ,timeout-ms) 1000.0)
                                             nil #'flush-batch)))
                 ;; Flush immediately if the batch is full.
                 (when (>= (length ,queue) ,size) (flush-batch)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Multiprocessing Async Equivalents (Python's multiprocessing.Pool-like)

;;;###autoload
(cl-defun concur:apply-async! (func args &key callback error-callback name
                               cancel-token require derive-mapping timeout
                               max-derivation-retries)
  "Call FUNC with ARGS in a background Emacs process asynchronously.
This is analogous to Python's `multiprocessing.Pool.apply_async`.

Arguments:
- FUNC (symbol): The function to call in the background process.
- ARGS (list): A list of arguments to apply to `FUNC`.
- :callback (function, optional): A function to call with the result on success.
- :error-callback (function, optional): A function to call with the error on failure.
- (Other keywords are passed to `concur:async!`)

Returns:
- (`concur-promise`): A promise for the result of `(apply FUNC ARGS)`."
  (interactive)
  (let* ((call-form `(apply ',func ',args))
         (promise (concur:async!
                   nil 'async :form call-form
                   :name (or name (format "apply-async-%S" func))
                   :cancel-token cancel-token :require require
                   :derive-mapping derive-mapping :timeout timeout
                   :max-derivation-retries max-derivation-retries)))
    (when callback (concur:then promise callback))
    (when error-callback (concur:then promise nil error-callback))
    promise))

;;;###autoload
(cl-defun concur:map-async! (func iterable &key mode chunksize callback
                              error-callback name cancel-token require
                              derive-mapping timeout max-derivation-retries)
  "Parallel equivalent of `map`, running operations in background processes.
Analogous to Python's `multiprocessing.Pool.map_async`. It splits
`ITERABLE` into chunks and processes each chunk in a separate
background Emacs process.

Arguments:
- FUNC (symbol): The function to apply to each item of `ITERABLE`.
- ITERABLE (list): The list of items to process.
- :mode (symbol): The execution mode, defaults to 'async.
- :chunksize (integer): The number of items to process in each background task.
- :callback (function, optional): A function called with the list of all results.
- :error-callback (function, optional): A function called on the first error.
- (Other keywords are passed to `concur:async!`)

Returns:
- (`concur-promise`): A promise that resolves to a list of all results."
  (interactive)
  (let* ((mode (or mode 'async))
         (chunksize (or chunksize concur-async-default-chunksize))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          collect (cl-subseq iterable i end)
                          while (< end (length iterable))))
         (promises
          (cl-loop for chunk in chunks for id from 0
                   collect (concur:async!
                            nil :mode mode
                            :form `(--map (funcall ',func it) ',chunk)
                            :name (or name (format "map-async-chunk-%d" id))
                            :cancel-token cancel-token :require require
                            :derive-mapping derive-mapping :timeout timeout
                            :max-derivation-retries max-retries))))
    (let ((all-promise (concur:all promises)))
      (when callback (concur:then all-promise
                                  (lambda (res) (funcall callback (apply #'append res)))))
      (when error-callback (concur:then all-promise nil error-callback))
      all-promise)))

;;;###autoload
(cl-defun concur:imap! (func iterable &key mode chunksize name cancel-token
                         require derive-mapping timeout max-derivation-retries)
  "A lazier, ordered version of `concur:map-async!`.
Analogous to Python's `multiprocessing.Pool.imap`.

This function immediately returns a generator. The generator yields
results as they become available from the background processes,
while still maintaining the original order of `ITERABLE`.

Arguments:
- See `concur:map-async!`.

Returns:
- (generator): A generator that can be consumed to get results."
  (interactive)
  (let* ((mode (or mode 'async))
         (chunksize (or chunksize concur-async-default-chunksize))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          collect (cl-subseq iterable i end)
                          while (< end (length iterable))))
         (promises
          (cl-loop for chunk in chunks for id from 0
                   collect (concur:async!
                            nil :mode mode
                            :form `(--map (funcall ',func it) ',chunk)
                            :name (or name (format "imap-chunk-%d" id))
                            :cancel-token cancel-token :require require
                            :derive-mapping derive-mapping :timeout timeout
                            :max-derivation-retries max-retries))))
    (defgenerator! imap-generator ()
      "Internal generator for `concur:imap!`."
      (dolist (p promises)
        (dolist (res (yield! p))
          (yield! res))))))

;;;###autoload
(cl-defun concur:imap-unordered! (func iterable &key mode chunksize name
                                   cancel-token require derive-mapping
                                   timeout max-derivation-retries)
  "A lazier, unordered version of `concur:map-async!`.
Analogous to Python's `multiprocessing.Pool.imap_unordered`.

This function returns a generator that yields results as soon as they
are completed by any background process, without preserving the
original order. This can be more efficient if the order of results
does not matter.

Arguments:
- See `concur:map-async!`.

Returns:
- (generator): A generator that yields results in completion order."
  (interactive)
  (let* ((mode (or mode 'async))
         (chunksize (or chunksize concur-async-default-chunksize))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          collect (cl-subseq iterable i end)
                          while (< end (length iterable))))
         (promises
          (cl-loop for chunk in chunks for id from 0
                   collect (concur:async!
                            nil :mode mode
                            :form `(--map (funcall ',func it) ',chunk)
                            :name (or name (format "imap-unordered-%d" id))
                            :cancel-token cancel-token :require require
                            :derive-mapping derive-mapping :timeout timeout
                            :max-derivation-retries max-retries))))
    (defgenerator! imap-unordered-generator ()
      "Internal generator for `concur:imap-unordered!`."
      (let ((pending (copy-list promises)))
        (while pending
          ;; Wait for any of the pending promises to settle.
          (yield! (concur:race pending))
          ;; Now, find which one(s) settled and process them.
          (let (still-pending settled)
            (dolist (p pending)
              (if (concur-promise-resolved-p p) (push p settled) (push p still-pending)))
            (setq pending (nreverse still-pending))
            ;; Yield all results from promises that just finished.
            (dolist (p-ready settled)
              (if (concur:resolved-p p-ready)
                  (dolist (res (concur:value p-ready)) (yield res))
                ;; On error, yield the error object itself.
                (yield! (concur:error-value p-ready))))))))))

;;;###autoload
(cl-defun concur:starmap-async!
    (func iterable &key mode chunksize callback error-callback name
          cancel-token require derive-mapping timeout max-derivation-retries)
  "Like `concur:map-async!` but unpacks iterable elements as arguments.
Analogous to Python's `multiprocessing.Pool.starmap_async`. Each
element in `ITERABLE` must be a list of arguments.

Arguments:
- FUNC (symbol): The function to call.
- ITERABLE (list of lists): Each inner list is a set of arguments for `FUNC`.
- (Other arguments are the same as `concur:map-async!`)

Returns:
- (`concur-promise`): A promise that resolves to a list of all results."
  (interactive)
  (let* ((mode (or mode 'async))
         (chunksize (or chunksize concur-async-default-chunksize))
         (chunks (cl-loop for i from 0 by chunksize
                          for end = (min (+ i chunksize) (length iterable))
                          collect (cl-subseq iterable i end)
                          while (< end (length iterable))))
         (promises
          (cl-loop for chunk in chunks for id from 0
                   collect (concur:async!
                            nil :mode mode
                            :form `(mapcar (lambda (args) (apply ',func args))
                                           ',chunk)
                            :name (or name (format "starmap-async-%d" id))
                            :cancel-token cancel-token :require require
                            :derive-mapping derive-mapping :timeout timeout
                            :max-derivation-retries max-retries))))
    (let ((all-promise (concur:all promises)))
      (when callback
        (concur:then all-promise (lambda (res) (funcall callback (apply #'append res)))))
      (when error-callback (concur:then all-promise nil error-callback))
      all-promise)))

;;;###autoload
(cl-defun concur:starmap-await!
    (func iterable &key mode chunksize name require
          derive-mapping timeout max-derivation-retries)
  "Blocking version of `starmap-async!`; unpacks arguments and awaits result.

Arguments:
- See `concur:starmap-async!`.

Returns:
- (list): A list of all results."
  (interactive)
  (concur:await (concur:starmap-async!
                 func iterable :mode mode :chunksize chunksize :name name
                 :require require :derive-mapping derive-mapping
                 :timeout timeout :max-derivation-retries max-derries)))

;;;###autoload
(cl-defun concur:map-await!
    (func iterable &key mode chunksize name require
          derive-mapping timeout max-derivation-retries)
  "Blocking version of `map-async!`; runs operations and awaits all results.

Arguments:
- See `concur:map-async!`.

Returns:
- (list): A list of all results."
  (interactive)
  (concur:await (concur:map-async!
                 func iterable :mode mode :chunksize chunksize :name name
                 :require require :derive-mapping derive-mapping
                 :timeout timeout :max-derivation-retries max-retries)))

;;;###autoload
(defun concur:async-pool-close ()
  "Close the background Emacs process pool, terminating idle processes.

Arguments:
- None.

Returns:
- nil."
  (interactive)
  (message "Concur-async: Attempting to close idle background procs...")
  (async-stop-all-processes)
  (message "Concur-async: All background procs terminated."))

(provide 'concur-async)
;;; concur-async.el ends here