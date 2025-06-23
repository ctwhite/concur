;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-core.el --- Core functionality for Concur Promises -*- lexical-binding: t; -*-

;;; Commentary:

;; This file defines the fundamental `concur-promise` data structure and
;; the core operations for creating, resolving, and rejecting promises. It
;; lies at the heart of the Concur library, implementing the state machine,
;; callback scheduling, and thread-safety primitives.
;;
;; Architectural Highlights:
;; - Promise/A+ Compliant Scheduling: Separates macrotasks (idle timer) and
;;   microtasks (immediate) for predictable execution order.
;; - AST-based Lexical Context Capture: To ensure callbacks work reliably
;;   when byte-compiled, handler functions are analyzed to capture their
;;   lexical environment. This context is then restored before execution.
;; - Thread-Safety and Concurrency Modes: `concur-lock` protects state;
;;   `mode` (`:deferred`, `:thread`) determines lock type. `await` behavior
;;   is adapted based on the execution context (thread vs. main).
;; - True Thread-Safe Signaling: For promises operating in `:thread` mode, a
;;   dedicated pipe and process sentinel are used. This allows background
;;   threads to safely and efficiently schedule callbacks on the main Emacs
;;   thread without polling, ensuring that UI-bound operations execute in the
;;   correct context.
;; - Extensibility: `concur-normalize-awaitable-hook` integrates external
;;   awaitable objects.

;;; Code:

(require 'cl-lib)          ; For cl-loop, cl-destructuring-bind, etc.
(require 'dash)            ; For --each, -filter, -flatten, -some
(require 's)               ; For s-split, s-truncate

(require 'concur-log)      ; For `concur--log`
(require 'concur-lock)     ; For mutexes
(require 'concur-ast)      ; For lexical context capture
(require 'concur-scheduler) ; For macrotask scheduling
(require 'concur-microtask) ; For microtask scheduling
(require 'concur-registry)  ; For promise registry 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward Declarations & Global Context

;; Forward declarations for types/functions defined in other Concur modules
;; to break dependency cycles and ensure proper byte-compilation.
(declare-function concur-cancel-token-p "concur-cancel")
(declare-function concur-cancel-token-add-callback "concur-cancel")
(declare-function concur:cancel "concur-cancel")
(declare-function concur-semaphore-p "concur-semaphore") ; Needed if using `satisfies` with semaphore objects
(declare-function concur-stream-p "concur-stream") ; Needed if using `satisfies` with stream objects
(declare-function concur-pool-task-p "concur-pool") ; Needed if using `satisfies` with pool task objects
(declare-function concur-worker-p "concur-pool") ; Needed if using `satisfies` with pool worker objects
(declare-function concur-shell-task-p "concur-shell") ; Needed if using `satisfies` with shell task objects
(declare-function concur-shell-worker-p "concur-shell") ; Needed if using `satisfies` with shell worker objects
(declare-function concur-queue-p "concur-queue") ; Needed if using `satisfies` with queue objects
(declare-function concur-priority-queue-p "concur-priority-queue") ; Needed if using `satisfies` with priority queue objects
(declare-function concur-registry-get-promise-by-id "concur-registry")

(defvar concur--coroutine-yield-throw-tag nil
  "Internal variable for `coroutine.el` integration with `concur:await`.
  This is used by `concur:await` to yield control within a coroutine
  via a `throw` to a known tag.")

(defvar concur--current-promise-context nil
  "Dynamically bound to the promise currently being processed by an
  executor or callback handler. Useful for resource tracking and
  contextual debugging.")

(defvar concur--current-async-stack nil
  "A dynamically-scoped list of labels for the current async call stack.
  Used to build richer debugging information on promise rejection,
  providing context for `concur-error` objects.")

(defvar concur--unhandled-rejections-queue '()
  "A list (acting as a queue) of unhandled promise rejections that occurred.
  These `concur-error` objects are stored for later inspection, allowing
  monitoring without necessarily halting Emacs for every unhandled error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Constants, Customization, and Errors

(defgroup concur nil "Asynchronous programming primitives for Emacs."
  :group 'emacs)

(defcustom concur-log-value-max-length 100
  "Maximum length of a value/error string in log messages before truncation."
  :type 'integer
  :group 'concur)

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, signal a `concur-unhandled-rejection` error.
  When a promise is rejected and has no rejection handlers attached,
  this controls whether to ignore it or signal an error. Set to `nil`
  to suppress automatic errors for unhandled rejections."
  :type 'boolean
  :group 'concur)

(defcustom concur-await-poll-interval 0.01
  "The polling interval (in seconds) for cooperative `concur:await`
  blocking. Used when `concur:await` is called outside a coroutine
  in `:deferred` mode."
  :type 'float
  :group 'concur)

(defcustom concur-await-default-timeout 10.0
  "Default timeout (in seconds) for `concur:await` if not specified.
  If `nil`, `concur:await` will wait indefinitely by default. Only
  applies when `concur:await` is called outside a coroutine."
  :type '(choice (float :min 0.0) (const :tag "Indefinite" nil))
  :group 'concur)

(defcustom concur-resolve-callbacks-begin-hook nil
  "Hook run when a batch of promise callbacks begins execution.

  Arguments:
  - `PROMISE` (concur-promise): The promise that settled.
  - `CALLBACKS` (list of `concur-callback`): The callbacks being processed."
  :type 'hook
  :group 'concur)

(defcustom concur-resolve-callbacks-end-hook nil
  "Hook run when a batch of promise callbacks finishes execution.

  Arguments:
  - `PROMISE` (concur-promise): The promise that settled.
  - `CALLBACKS` (list of `concur-callback`): The callbacks that were processed."
  :type 'hook
  :group 'concur)

(defcustom concur-unhandled-rejection-hook nil
  "Hook run when a promise is rejected and no rejection handler is attached.
  This hook runs *before* `concur-throw-on-promise-rejection` takes effect.

  Arguments:
  - `PROMISE` (concur-promise): The promise that was rejected.
  - `ERROR` (concur-error): The `concur-error` object itself."
  :type 'hook
  :group 'concur)

(defcustom concur-normalize-awaitable-hook nil
  "Hook run to normalize arbitrary awaitable objects into `concur-promise`s.
  Functions added to this hook should accept one argument (the awaitable
  object) and return a `concur-promise` if they can normalize it, or `nil`
  otherwise. Handlers are run in order until one succeeds.
  Example: `(add-hook 'concur-normalize-awaitable-hook #'concur-future-normalize-future)`."
  :type 'hook
  :group 'concur)

;; Define standard error types used by the Concur library.
(define-error 'concur-error
  "A generic error in the Concur library.")
(define-error 'concur-unhandled-rejection
  "A promise was rejected with no handler."
  'concur-error)
(define-error 'concur-await-error
  "An error occurred while awaiting a promise."
  'concur-error)
(define-error 'concur-cancel-error
  "A promise was cancelled."
  'concur-error)
(define-error 'concur-timeout-error
  "An operation timed out."
  'concur-error)
(define-error 'concur-type-error
  "An invalid type was encountered."
  'concur-error)
(define-error 'concur-executor-error
  "An error occurred within a promise executor function."
  'concur-error)
(define-error 'concur-callback-error
  "An error occurred within a promise callback handler (then/catch/finally)."
  'concur-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct Definitions

(cl-defstruct (concur-promise (:constructor %%make-promise))
  "Represents an asynchronous operation that can resolve or reject.
  This is the central data structure of the library. Do not
  manipulate its fields directly; use the `concur:*` functions.

  Arguments:
  - `id` (symbol): A unique identifier (`gensym`) for logging and debugging.
  - `result` (any): The value the promise resolved with. Defaults to `nil`.
  - `error` (concur-error or nil): The reason the promise was rejected
    (typically a `concur-error` struct). Defaults to `nil`.
  - `state` (symbol): The current state: `:pending`, `:resolved`, or
    `:rejected`. Defaults to `:pending`.
  - `callbacks` (list): List of `concur-callback-link` structs waiting
    to run when the promise settles. Defaults to `nil`.
  - `cancel-token` (concur-cancel-token or nil): Optional token for
    cancellation. If a cancel token is associated, and it is cancelled,
    the promise will be rejected. Defaults to `nil`.
  - `cancelled-p` (boolean): `t` if rejection was due to cancellation.
    Defaults to `nil`.
  - `proc` (process or nil): Optional external process object associated
    with the promise. If the promise is cancelled, this process will be
    killed. Defaults to `nil`.
  - `lock` (concur-lock): A mutex protecting all fields from concurrent
    access. This is crucial for thread-safety. Defaults to `nil` (initialized
    by `concur:make-promise`).
  - `mode` (symbol): Concurrency mode of the promise:
    - `:deferred` (default): Callbacks scheduled via idle timer.
    - `:thread`: Callbacks scheduled safely to main thread from background.
    - `:async`: Reserved for `concur-async` integration.
    Defaults to `:deferred`."
  (id nil :type symbol)
  (result nil)
  (error nil :type (or null (satisfies concur-error-p)))
  (state :pending :type (member :pending :resolved :rejected))
  (callbacks nil :type list)
  (cancel-token nil :type (or null (satisfies concur-cancel-token-p)))
  (cancelled-p nil :type boolean)
  (proc nil :type (or process null))
  (lock nil :type (or null (satisfies concur-lock-p)))
  (mode :deferred :type (member :deferred :thread :async)))

(cl-defstruct (concur-await-latch (:constructor %%make-await-latch))
  "Internal latch for the `concur:await` mechanism.
  This acts as a shared flag between a waiting `await` call and the
  promise callback that signals completion.

  Arguments:
  - `signaled-p` (boolean or `timeout`): The flag indicating completion.
    `t` means resolved, `timeout` means it timed out. Defaults to `nil`.
  - `cond-var` (condition-variable or nil): Condition variable used for
    blocking and notifying in `:thread` mode waits. Defaults to `nil`."
  (signaled-p nil :type (or boolean (eql timeout)))
  (cond-var nil :type (or null (satisfies condition-variable-p))))

(cl-defstruct (concur-callback (:constructor %%make-callback))
  "An internal struct that wraps a callback function and its context.

  Arguments:
  - `type` (symbol): The handler type, e.g., `:resolved`, `:rejected`,
    `:finally`, `:await-latch`.
  - `fn` (function): The actual user-defined callback function.
  - `promise` (concur-promise or nil): The next promise in a chain to be
    settled by this callback's result. `nil` for `:await-latch` type.
  - `context` (any): A representation of the captured lexical context
    needed for the callback to execute correctly when byte-compiled.
    Often a hash-table or a form that evaluates to it.
  - `priority` (integer): Scheduling priority for macrotasks. Lower values
    mean higher priority. Defaults to 50."
  (type nil :type symbol)
  (fn nil :type function)
  (promise nil :type (or null (satisfies concur-promise-p)))
  (context nil)
  (priority 50 :type integer))

(cl-defstruct (concur-callback-link (:constructor %%make-callback-link))
  "Represents one link in a promise chain, grouping callbacks.
  A single call to `concur:then` can attach both a resolve and a
  reject handler. This struct groups them for coherent processing.

  Arguments:
  - `id` (symbol): A unique ID for debugging this link. Defaults to `nil`.
  - `callbacks` (list): A list of `concur-callback` structs associated
    with this link. Defaults to `nil`."
  (id nil :type symbol)
  (callbacks nil :type list))

(cl-defstruct (concur-error (:constructor %%make-concur-error))
  "A standardized error object for promise rejections.
  Provides a consistent structure for error handling and introspection.

  Arguments:
  - `type` (keyword): Keyword identifying the error (`:cancel`, `:timeout`,
    `:callback-error`, etc.). Defaults to `:generic`.
  - `message` (string): A human-readable error message.
  - `cause` (any): The original error or reason that caused this error
    (e.g., an Emacs Lisp error object). Defaults to `nil`.
  - `promise` (concur-promise or nil): The promise instance that rejected
    (optional, for debugging context). Defaults to `nil`.
  - `async-stack-trace` (string or nil): The async call stack at the time
    of rejection. Defaults to `nil`.
  - `cmd` (string or nil): If process-related, the command. Defaults to `nil`.
  - `args` (list or nil): If process-related, command args. Defaults to `nil`.
  - `cwd` (string or nil): If process-related, the cwd. Defaults to `nil`.
  - `exit-code` (integer or nil): If process-related, the exit code.
    Defaults to `nil`.
  - `signal` (string or nil): If process-related, signal name. Defaults to `nil`.
  - `process-status` (symbol or nil): If process-related, the process status.
    Defaults to `nil`.
  - `stdout` (string or nil): If process-related, collected stdout.
    Defaults to `nil`.
  - `stderr` (string or nil): If process-related, collected stderr.
    Defaults to `nil`."
  (type :generic :type keyword)
  (message "An unspecific Concur error occurred." :type string)
  (cause nil)
  (promise nil :type (or null (satisfies concur-promise-p)))
  (async-stack-trace nil :type (or null string))
  (cmd nil :type (or string null))
  (args nil :type (or list null))
  (cwd nil :type (or string null))
  (exit-code nil :type (or integer null))
  (signal nil :type (or string null))
  (process-status nil :type (or symbol null))
  (stdout nil :type (or string null))
  (stderr nil :type (or string null)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; True Thread-Safe Signaling Mechanism

(defvar concur--thread-callback-pipe nil
  "A pipe used by background threads to send callbacks to the main thread.
This pipe facilitates safe scheduling of functions on the main Emacs thread.")

(defvar concur--thread-callback-sentinel-process nil
  "A dummy process whose sentinel listens to `concur--thread-callback-pipe`
  for thread callbacks. This sentinel is crucial for executing background
  thread-scheduled tasks safely on the main Emacs thread.")

(defun concur--thread-callback-dispatcher (promise-id)
  "Send a promise ID to be executed on the main Emacs thread via a pipe.
This is the core of the thread-safe signaling. A background thread calls
this function, which serializes the `PROMISE-ID` and sends it through
the pipe. The sentinel on the main thread reads the ID and processes
the promise safely.

  Arguments:
  - `promise-id` (symbol): The ID of the promise that has settled.

  Returns:
  - `nil` (side-effect: sends data to pipe)."
  (when (and concur--thread-callback-pipe
             (process-live-p concur--thread-callback-sentinel-process))
    (let ((write-end (process-contact
                      concur--thread-callback-sentinel-process)))
      ;; Send a form to be read and eval'd on the main thread.
      (send-string-to-process
       (prin1-to-string `(concur--process-settled-on-main ',promise-id))
       write-end)
      (send-string-to-process "\n" write-end))))

(defun concur--process-settled-on-main (promise-id)
  "Look up a promise by ID and trigger its callbacks.
This function is always executed on the main thread, having been
called by the thread sentinel.

  Arguments:
  - `promise-id` (symbol): The ID of the settled promise."
  (if-let ((promise (concur-registry-get-promise-by-id promise-id)))
      (let ((callbacks-to-run (concur-promise-callbacks promise))
            (is-cancellation (concur-promise-cancelled-p promise)))
        (setf (concur-promise-callbacks promise) nil) ; Clear before processing.
        (concur--trigger-callbacks-after-settle promise callbacks-to-run)
        (when is-cancellation
          (concur--kill-associated-process promise)))
    (concur--log :warn nil "Could not find promise with ID %S for main-thread callback." promise-id)))

(defun concur--thread-callback-sentinel (process event)
  "The sentinel that reads and executes callbacks from background threads.
This function is attached to `concur--thread-callback-sentinel-process`
and runs on the main Emacs thread when new output is available from the pipe.

  Arguments:
  - `process` (process): The process object (the dummy sentinel process).
  - `event` (string): The event string (e.g., \"output\").

  Returns:
  - `nil` (side-effect: reads and evaluates forms)."
  (when (string-match-p "output" event)
    (let ((output-buffer (process-buffer process)))
      (with-current-buffer output-buffer
        (dolist (line (s-split "\n" (buffer-string) t))
          (when-let (callback-form (ignore-errors (read line)))
            ;; The form is now running on the main Emacs thread.
            (eval callback-form)))
        (erase-buffer)))))

(defun concur--init-thread-signaling ()
  "Initialize the pipe and sentinel for cross-thread communication.
This function creates a dedicated pipe and a dummy Emacs process.
Its sentinel listens to the pipe, allowing background threads to
schedule tasks on the main thread. This function should only be called once."
  (when (and (fboundp 'make-thread) (not concur--thread-callback-pipe))
    (concur--log :debug nil "Initializing thread signaling mechanism.")
    (setq concur--thread-callback-pipe
          (make-pipe-process :name "concur-thread-pipe"))
    (setq concur--thread-callback-sentinel-process
          (make-process :name "concur-thread-sentinel"
                        :command (list (executable-find "emacs")
                                       "--batch" "-l" "-"
                                       "--eval" "(while t (sleep-for 300))")
                        :connection-type 'pipe
                        :noquery t
                        :coding 'utf-8
                        ;; Connect stdout/stderr to the pipe to trigger sentinel
                        :stderr (process-contact concur--thread-callback-pipe
                                                 :stderr)
                        :stdout (process-contact concur--thread-callback-pipe
                                                 :stdin)))
    (set-process-sentinel concur--thread-callback-sentinel-process
                          #'concur--thread-callback-sentinel)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal State and Schedulers

(defvar concur--macrotask-scheduler nil
  "The global scheduler instance for macrotasks.
This is an instance of `concur-scheduler`, responsible for
processing deferred promise callbacks via an idle timer.")

(defun concur--init-macrotask-queue ()
  "Initialize the global macrotask scheduler if it doesn't exist.
This function ensures `concur--macrotask-scheduler` is a valid instance
of `concur-scheduler`."
  (unless concur--macrotask-scheduler
    (concur--log :debug nil "Initializing macrotask scheduler.")
    (setq concur--macrotask-scheduler
          (concur-scheduler-create
           :name "concur--macrotask-scheduler"
           :comparator (lambda (cb1 cb2)
                         (< (concur-callback-priority cb1)
                            (concur-callback-priority cb2)))
           :process-fn #'concur--process-macrotask-batch-internal))))

(defun concur--schedule-macrotasks (callbacks-list)
  "Add a list of callbacks to the macrotask scheduler.
Ensures callbacks run asynchronously, preventing the 'Zalgo problem'.
Promises/A+ Spec 2.2.4: `onFulfilled` or `onRejected` must not be
called until the execution context stack contains only platform code.

  Arguments:
  - `callbacks-list` (list): A list of `concur-callback` objects to schedule.

  Returns:
  - `nil` (side-effect: enqueues callbacks)."
  (dolist (cb callbacks-list)
    (concur-scheduler-enqueue concur--macrotask-scheduler cb)))

(defun concur--process-macrotask-batch-internal (scheduler)
  "Execute a batch of callbacks from the macrotask scheduler.
This function is the `process-fn` for `concur--macrotask-scheduler`.

  Arguments:
  - `scheduler` (concur-scheduler): The scheduler instance.

  Returns:
  - `nil` (side-effect: executes callbacks, drains microtask queue)."
  (let ((batch (concur-scheduler-pop-batch scheduler)))
    (when batch
      (run-hook-with-args 'concur-resolve-callbacks-begin-hook
                          (concur-callback-promise (car (car batch))) ; First promise in first link
                          batch)
      (--each batch #'concur-execute-callback)
      (run-hook-with-args 'concur-resolve-callbacks-end-hook
                          (concur-callback-promise (car (car batch)))
                          batch)
      (concur-microtask-queue-drain))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Core Promise Lifecycle

(defun concur--settle-promise (promise result error is-cancellation)
  "The core internal function to settle a promise (resolve or reject).
This function is idempotent and thread-safe.
Promises/A+ Spec 2.1: A promise must be in one of three states:
pending, fulfilled, or rejected.
Promises/A+ Spec 2.1.2 & 2.1.3: When fulfilled or rejected, a promise
must not transition to any other state.

  Arguments:
  - `promise` (concur-promise): The promise to settle.
  - `result` (any): The value to resolve the promise with.
  - `error` (concur-error or nil): The error to reject the promise with.
  - `is-cancellation` (boolean): `t` if the settlement is due to cancellation.

  Returns:
  - (concur-promise): The original promise."
  (let ((settled-now nil) (callbacks-to-run '()))
    (concur:with-mutex! (concur-promise-lock promise)
      ;; The core idempotency check: only proceed if still pending.
      (when (eq (concur-promise-state promise) :pending)
        (let ((new-state (if error :rejected :resolved)))
          (setq callbacks-to-run (concur-promise-callbacks promise))
          ;; Callbacks are cleared later by the responsible thread
          ;; to avoid race conditions.
          (setf (concur-promise-result promise) result)
          (setf (concur-promise-error promise) error)
          (setf (concur-promise-cancelled-p promise) is-cancellation)
          (setf (concur-promise-state promise) new-state)
          (setq settled-now t))))
    (when settled-now
      ;; If settlement happens in a background thread, dispatch callback
      ;; execution to the main thread to ensure safety.
      (if (and (eq (concur-promise-mode promise) :thread)
               (fboundp 'main-thread)
               (not (equal (current-thread) (main-thread))))
          (concur--thread-callback-dispatcher (concur-promise-id promise))
        ;; Otherwise, execute directly in the current (main) thread.
        (progn
          (setf (concur-promise-callbacks promise) nil) ; Clear callbacks now.
          (concur--trigger-callbacks-after-settle promise callbacks-to-run)
          (when is-cancellation
            (concur--kill-associated-process promise))))
      ;; Update promise state in registry for debugging/introspection.
      (when (fboundp 'concur-registry-update-promise-state)      
        (concur-registry-update-promise-state promise))))
  promise)

(defun concur--kill-associated-process (promise)
  "If PROMISE has an associated external process, kill it.

  Arguments:
  - `promise` (concur-promise): The promise whose associated process should
    be killed.

  Returns:
  - `nil` (side-effect: kills process)."
  (when-let ((proc (concur-promise-proc promise)))
    (when (process-live-p proc)
      (concur--log :debug (concur-promise-id promise)
                   "Killing associated process %S for promise." proc)
      (delete-process proc))
    (setf (concur-promise-proc promise) nil)))

(defun concur--trigger-callbacks-after-settle (promise callback-links)
  "Called once a promise settles to schedule its callbacks.
Promises/A+ Spec 2.2.2.3 & 2.2.3.3: Callbacks must not be called more
than once. Clearing the list in `concur--settle-promise` ensures this.

  Arguments:
  - `promise` (concur-promise): The promise that has settled.
  - `callback-links` (list): A list of `concur-callback-link` objects
    to schedule for execution.

  Returns:
  - `nil` (side-effect: schedules callbacks, handles unhandled rejections)."
  (concur--partition-and-schedule-callbacks callback-links)
  ;; **FIX:** Defer the unhandled rejection check to a later event loop turn.
  ;; This gives synchronous code (like the `await` in the test case) a
  ;; chance to attach a handler before this check runs.
  (when (eq (concur-promise-state promise) :rejected)
    (let ((p promise) (cbl callback-links))
      (run-with-idle-timer 0 nil
                           (lambda ()
                             (concur:with-mutex! (concur-promise-lock p)
                               (concur--handle-unhandled-rejection-if-any p cbl)))))))

(defun concur--partition-and-schedule-callbacks (callback-links)
  "Partitions callbacks into microtasks and macrotasks, then schedules them.
Microtasks (like await latches) run immediately, macrotasks are deferred
to the idle scheduler.

  Arguments:
  - `callback-links` (list): A list of `concur-callback-link` objects.

  Returns:
  - `nil` (side-effect: enqueues callbacks to schedulers)."
  (let* ((all-callbacks (apply #'append (mapcar #'concur-callback-link-callbacks
                                                callback-links)))
         (microtasks (-filter (lambda (cb) (eq (concur-callback-type cb)
                                               :await-latch))
                                all-callbacks))
         (macrotasks (-filter (lambda (cb) (not (eq (concur-callback-type cb)
                                                    :await-latch)))
                                all-callbacks)))
    (when microtasks
      (concur--log :debug nil "Scheduling %d microtasks." (length microtasks))
      (concur-microtask-queue-add microtasks))
    (when macrotasks
      (concur--log :debug nil "Scheduling %d macrotasks." (length macrotasks))
      (concur--schedule-macrotasks macrotasks))))

(defun concur--handle-unhandled-rejection-if-any (promise callback-links)
  "If PROMISE was rejected with no rejection handlers attached,
signals an unhandled rejection error.

  Arguments:
  - `promise` (concur-promise): The promise that settled.
  - `callback-links` (list): The list of callback links that were processed.

  Returns:
  - `nil` (side-effect: logs/signals unhandled rejection)."
  (when (and (eq (concur-promise-state promise) :rejected)
             (not (-some (lambda (link)
                           (-some (lambda (cb) (eq (concur-callback-type cb)
                                                   :rejected))
                                  (concur-callback-link-callbacks link)))
                         callback-links)))
    (let ((error-obj (concur:make-error
                      :type :unhandled-rejection
                      :message (format "Unhandled promise rejection: %s"
                                       (concur:error-message
                                        (concur-promise-error promise)))
                      :cause (concur-promise-error promise)
                      :promise promise)))
      (concur--log :warn (concur-promise-id promise)
                   "Unhandled promise rejection: %S" error-obj)
      (push error-obj concur--unhandled-rejections-queue)
      (run-hook-with-args 'concur-unhandled-rejection-hook promise error-obj)
      (when concur-throw-on-promise-rejection
        (signal 'concur-unhandled-rejection
                (list (concur:error-message error-obj) error-obj))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal: Callback and Context Management

(defun concur-current-async-stack-string ()
  "Format `concur--current-async-stack` into a readable string.

  Returns:
  - (string or nil): The formatted async stack trace, or `nil` if empty."
  (when concur--current-async-stack
    (mapconcat #'identity (reverse concur--current-async-stack) "\n↳ ")))

(defun concur--merge-contexts (existing-context captured-vars-alist)
  "Merge contexts into a new hash table.
Used to combine explicit context with AST-captured variables.

  Arguments:
  - `existing-context` (hash-table or alist): An existing context.
  - `captured-vars-alist` (alist): An alist of `(VAR . VAL)` pairs from
    AST analysis.

  Returns:
  - (hash-table): A new hash table containing merged context."
  (let ((merged-ht (make-hash-table :test 'eq)))
    (cond ((hash-table-p existing-context)
           (maphash (lambda (k v) (puthash k v merged-ht)) existing-context))
          ((listp existing-context)
           (--each existing-context (puthash (car it) (cdr it) merged-ht))))
    (when (listp captured-vars-alist)
      (--each captured-vars-alist (puthash (car it) (cdr it) merged-ht)))
    merged-ht))

(defun concur-execute-callback (callback)
  "Executes a single callback, handling context evaluation and errors.

  Arguments:
  - `callback` (concur-callback): The callback to execute.

  Returns:
  - `nil` (side-effect: executes handler, settles target promise)."
  (let* ((origin-promise (concur-callback-promise callback))
         (handler (concur-callback-fn callback))
         (type (concur-callback-type callback))
         (target-promise (concur-callback-promise callback))
         ;; Evaluate the captured lexical context before executing handler
         (context (eval (concur-callback-context callback)))
         (let-bindings
                  (let (bindings)
                    (maphash #'(lambda (k v) (push `(,k ',v) bindings)) context)
                      bindings)))
    (concur--log :debug (concur-promise-id target-promise)
                 "Executing callback type '%S' for promise %S."
                 type (concur-promise-id origin-promise))
    (let ((concur--current-promise-context target-promise))
      ;; Bind `concur-resource-tracking-function` for resource management.
      (let ((concur-resource-tracking-function
             (lambda (action resource)
               (pcase action
                 (:acquire (concur-registry-register-resource-hold
                            target-promise resource))
                 (:release (concur-registry-release-resource-hold
                            target-promise resource))))))
        (condition-case err
            (let ((result (concur-promise-result origin-promise))
                  (error (concur-promise-error origin-promise)))
              (pcase type
                (:resolved
                 (when (not error)
                   (concur-chain-or-settle-promise
                    target-promise (funcall handler result))))
                (:rejected
                 (when error
                   (concur-chain-or-settle-promise
                    target-promise (funcall handler error))))
                (:finally
                 (let ((res (funcall handler)))
                   (if error
                       (concur:reject target-promise error)
                     (concur-chain-or-settle-promise target-promise res))))
                (:await-latch
                 ;; Await latch handlers explicitly receive context as `context-ht`.
                 (funcall handler nil context))))
          (error
           (concur--log :error (concur-promise-id target-promise)
                        "Error in callback '%S' for promise %S: %S"
                        type (concur-promise-id origin-promise) err)
           (concur:reject
            target-promise
            (concur:make-error :type :callback-error
                               :message (format "Callback failed: %S" err)
                               :cause err :promise origin-promise))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal `await` Implementation

(defun concur--await-latch-signaler-function (_value context-ht)
  "Internal function for `:await-latch` callbacks.
This function is called when the awaited promise settles.

  Arguments:
  - `_value` (any): The resolved value (ignored).
  - `context-ht` (hash-table): Contains `latch` and `target-promise`."
  (let* ((latch (gethash 'latch context-ht))
         (promise (gethash 'target-promise context-ht)))
    ;; Prevent overwriting a 'timeout' signal with a success signal.
    (when (and latch (not (eq (concur-await-latch-signaled-p latch) 'timeout)))
      (setf (concur-await-latch-signaled-p latch) t)
      ;; Notify any thread waiting on the condition variable.
      (when-let (cond-var (concur-await-latch-cond-var latch))
        (concur:with-mutex! (concur-promise-lock promise)
          (condition-notify cond-var))))))

(cl-defun concur--make-await-latch-callback (latch target-promise)
  "Create a `concur-callback` for an `await` latch.

  Arguments:
  - `latch` (concur-await-latch): The latch to signal.
  - `target-promise` (concur-promise): The promise being awaited.

  Returns:
  - (concur-callback): A new callback struct."
  (let ((context (make-hash-table)))
    (puthash 'latch latch context)
    (puthash 'target-promise target-promise context)
    (%%make-callback :type :await-latch
                     :fn #'concur--await-latch-signaler-function
                     :promise target-promise
                     :context `',context)))

(defun concur--await-blocking (promise timeout)
  "The cooperative blocking implementation for `concur:await`.
This function is the heart of synchronous-style waiting. It handles
the full lifecycle of a blocking `await` call outside a coroutine.

  Arguments:
  - `promise` (concur-promise): The promise to wait for.
  - `timeout` (number, optional): Maximum seconds to wait before signaling
    a `concur-timeout-error`.

  Returns:
  - (any): The resolved value of the promise.

  Signals:
  - `concur-await-error`: If the promise is rejected.
  - `concur-timeout-error`: If the operation times out."
  ;; Step 1: Handle the trivial case where the promise is already settled.
  ;; This avoids all the overhead of setting up latches and timers.
  (when (not (eq (concur:status promise) :pending))
    (if-let ((err (concur:error-value promise)))
        ;; If it was rejected, signal a standard `concur-await-error`.
        (signal 'concur-await-error (list (concur:error-message err) err))
      (concur:value promise)))

  ;; Step 2: For a pending promise, set up the blocking machinery.
  (let ((latch (%%make-await-latch))
        (timer nil))
    ;; `unwind-protect` is crucial to ensure the timeout timer is always
    ;; cancelled, preventing it from firing after the await has completed.
    (unwind-protect
        (progn
          ;; Step 2a: Attach a high-priority microtask callback to the promise.
          ;; This callback's only job is to signal our latch when the promise settles.
          (concur-attach-callbacks
           promise (concur--make-await-latch-callback latch promise))

          ;; Step 2b: If a timeout was specified, create and start a timer.
          ;; The timer will signal the latch with the special 'timeout value.
          (when timeout
            (setq timer (run-at-time timeout nil
                                     #'(lambda ()
                                         ;; Prevent overwriting a success signal with timeout.
                                         (when (null (concur-await-latch-signaled-p latch))
                                           (setf (concur-await-latch-signaled-p latch) 'timeout))))))

          ;; Step 2c: Choose the blocking strategy based on the promise's mode.
          (if (eq (concur-promise-mode promise) :thread)
              ;; For `:thread` mode, use a real condition variable for efficient,
              ;; true thread blocking.
              (let ((cond-var (make-condition-variable
                               (concur-promise-lock promise))))
                (setf (concur-await-latch-cond-var latch) cond-var)
                (concur:with-mutex! (concur-promise-lock promise)
                  (while (not (concur-await-latch-signaled-p latch))
                    (condition-wait cond-var))))
            ;; For `:deferred` mode, use a cooperative polling loop. `sit-for`
            ;; yields control to Emacs, allowing other events to process.
            (while (not (concur-await-latch-signaled-p latch))
              (sit-for concur-await-poll-interval)))

          ;; Step 3: The loop has exited. Check the latch to see why.
          (if (eq (concur-await-latch-signaled-p latch) 'timeout)
              ;; The timer fired first.
              (user-error "[Concur Await] Await for %S timed out."
                          (concur:format-promise promise))
            ;; The promise settled. Check if it resolved or rejected.
            (if-let ((err (concur:error-value promise)))
                (signal 'concur-await-error (list (concur:error-message err) err))
              (concur:value promise))))
      ;; Final cleanup step of `unwind-protect`.
      (when timer (cancel-timer timer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Promise Construction and State Transition

;;;###autoload
(cl-defun concur:make-promise (&key (mode :deferred) name cancel-token parent-promise)
  "Create a new, pending `concur-promise`.
This is the main entry point for creating a promise that you will
manually resolve or reject later.

  Arguments:
  - `:MODE` (symbol, optional): Concurrency mode (`:deferred`, `:thread`,
    or `:async`). `:deferred` (default) schedules callbacks via an idle
    timer. `:thread` schedules callbacks safely to the main thread from
    background threads. `:async` is reserved for `concur-async` usage.
  - `:NAME` (string, optional): A descriptive name for debugging and registry.
  - `:CANCEL-TOKEN` (concur-cancel-token, optional): An optional cancel token.
    If provided, the promise will be rejected with a `concur-cancel-error`
    if the token is cancelled.
  - `:PARENT-PROMISE` (concur-promise, optional): The promise that created
    this one. Used internally for promise introspection/debugging.

  Returns:
  - (concur-promise): A new promise in the `:pending` state."
  (let* ((p (%%make-promise
             :id (gensym "promise-")
             :mode mode
             :lock (concur:make-lock (format "promise-lock-%S" (gensym))
                                     :mode mode)
             :cancel-token cancel-token)))
    ;; Register promise with concurrency registry for introspection.
    (when (fboundp 'concur-registry-register-promise)
      (concur-registry-register-promise p
                                        (or name (symbol-name (concur-promise-id p)))
                                        :parent-promise parent-promise))
    ;; Add callback to cancel promise if its cancel token is signalled.
    (when (and cancel-token (fboundp 'concur-cancel-token-add-callback))
      (concur-cancel-token-add-callback
       cancel-token (lambda () (concur:cancel p))))
    p))

;;;###autoload
(defun concur:resolve (promise result)
  "Resolve a PROMISE with a given RESULT.
If RESULT is another promise (or an object normalizable to a promise
via `concur-normalize-awaitable-hook`), the original PROMISE will
adopt its state (a process known as chaining), per the Promises/A+ spec.
This operation is idempotent; it has no effect if the promise is not pending.

  Arguments:
  - `PROMISE` (concur-promise): The promise to resolve.
  - `RESULT` (any): The value to resolve the promise with.

  Returns:
  - (concur-promise): The original `PROMISE`."
  (unless (concur-promise-p promise)
    (user-error "concur:resolve: Invalid promise object: %S" promise))
  (concur-chain-or-settle-promise promise result))

(defun concur-chain-or-settle-promise (promise value)
  "Resolve PROMISE with VALUE, implementing the Promise/A+ resolution procedure.
Promises/A+ Spec 2.3: The Promise Resolution Procedure.
This function encapsulates the logic for handling resolutions with
`thenable` values, ensuring compliance.

  Arguments:
  - `promise` (concur-promise): The promise to settle.
  - `value` (any): The value to resolve the promise with.

  Returns:
  - (concur-promise): The original promise."
  (let ((normalized-value (if (concur-promise-p value)
                              value
                            (run-hook-with-args-until-success
                             'concur-normalize-awaitable-hook value value))))
    (cond
     ;; Promises/A+ Spec 2.3.1: If promise and x refer to the same object,
     ;; reject promise with a `TypeError` as the reason.
     ((eq promise normalized-value)
      (concur--settle-promise
       promise nil
       (concur:make-error :type :type-error
                          :message "A promise cannot be resolved with itself.")
       nil))
     ;; Promises/A+ Spec 2.3.2: If x is a promise, adopt its state.
     ((concur-promise-p normalized-value)
      (concur--log :debug (concur-promise-id promise)
                   "Chaining promise %S to promise %S."
                   (concur-promise-id normalized-value)
                   (concur-promise-id promise))
      (concur-attach-callbacks
       normalized-value
       (concur-make-resolved-callback
        (lambda (res-val)
          (concur--log :debug (concur-promise-id promise)
                       "Chained promise %S resolved, resolving %S."
                       (concur-promise-id normalized-value)
                       (concur-promise-id promise))
          (concur-chain-or-settle-promise promise res-val))
        promise)
       (concur-make-rejected-callback
        (lambda (rej-err)
          (concur--log :debug (concur-promise-id promise)
                       "Chained promise %S rejected, rejecting %S."
                       (concur-promise-id normalized-value)
                       (concur-promise-id promise))
          (concur:reject promise rej-err))
        promise)))
     ;; Promises/A+ Spec 2.3.3: Otherwise, fulfill promise with x.
     (t (concur--settle-promise promise value nil nil))))
  promise)

;;;###autoload
(defun concur:reject (promise error)
  "Reject a PROMISE with a given ERROR.
This operation is idempotent. The provided `error` is standardized
into a `concur-error` struct for consistent handling.

  Arguments:
  - `PROMISE` (concur-promise): The promise to reject.
  - `ERROR` (any): The reason for the rejection. Can be an arbitrary Lisp
    object or a `concur-error` struct. It will be converted to a `concur-error`.

  Returns:
  - (concur-promise): The original `PROMISE`."
  (unless (concur-promise-p promise)
    (user-error "concur:reject: Invalid promise object: %S" promise))
  (let* ((is-cancellation (and (concur-error-p error)
                               (eq (concur-error-type error) :cancel)))
         (final-error
          (if (concur-error-p error)
              error
            ;; If the error is not already a concur-error struct, create one.
            (concur:make-error
             :type (if is-cancellation :cancel :generic)
             ;; FIX: Use the error directly if it's a string. This avoids
             ;; extra quoting and potential formatting issues.
             :message (if (stringp error) error (format "%S" error))
             :cause error
             :promise promise))))
    ;; Capture async stack trace if not already present.
    (when (and concur--current-async-stack
               (not (concur-error-async-stack-trace final-error)))
      (setf (concur-error-async-stack-trace final-error)
            (concur-current-async-stack-string)))
    (concur--log :debug (concur-promise-id promise)
                 "Rejecting promise %S with error: %S"
                 (concur-promise-id promise) final-error)
    (concur--settle-promise promise nil final-error is-cancellation)))

;;;###autoload
(cl-defun concur:resolved! (value &key (mode :deferred) name)
  "Create and return a new promise that is already resolved with VALUE.
This is a convenient factory function for immediately resolved promises.

  Arguments:
  - `VALUE` (any): The value to resolve the new promise with.
  - `:MODE` (symbol, optional): Concurrency mode for the promise's internal
    lock. Defaults to `:deferred`.
  - `:NAME` (string, optional): A descriptive name for debugging and registry.

  Returns:
  - (concur-promise): A new promise in the `:resolved` state."
  (let ((p (concur:make-promise :mode mode :name name)))
    (concur:resolve p value)
    p))

;;;###autoload
(cl-defun concur:rejected! (error &key (mode :deferred) name)
  "Create and return a new promise that is already rejected with ERROR.
This is a convenient factory function for immediately rejected promises.

  Arguments:
  - `ERROR` (any): The error to reject the new promise with. This can be an
    arbitrary Lisp object or a `concur-error` struct.
  - `:MODE` (symbol, optional): Concurrency mode for the promise's internal
    lock. Defaults to `:deferred`.
  - `:NAME` (string, optional): A descriptive name for debugging and registry.

  Returns:
  - (concur-promise): A new promise in the `:rejected` state."
  (let ((p (concur:make-promise :mode mode :name name)))
    (concur:reject p error)
    p))

;;;###autoload
(defun concur:cancel (promise &optional reason)
  "Cancel a pending PROMISE.
This rejects the promise with a cancellation error. If the promise has an
associated external process (`concur-promise-proc`), it will also be killed.

  Arguments:
  - `PROMISE` (concur-promise): The promise to cancel.
  - `REASON` (string, optional): A descriptive reason for the cancellation.

  Returns:
  - (concur-promise): The original `PROMISE` (now rejected if pending)."
  (unless (concur-promise-p promise)
    (user-error "concur:cancel: Invalid promise object: %S" promise))
  (when (eq (concur:status promise) :pending)
    (concur--log :info (concur-promise-id promise)
                 "Cancelling promise %S (Reason: %S)."
                 (concur-promise-id promise) reason)
    (concur:reject promise
                   (concur:make-error :type :cancel
                                      :message (or reason "Promise cancelled")
                                      :promise promise))))

;;;###autoload
(cl-defun concur:make-error (&rest args &key type message cause promise
                                         cmd cmd-args cwd exit-code signal
                                         process-status stdout stderr)
  "Create a new `concur-error` struct.
This function provides a convenient way to create standardized error objects
for consistent rejection reasons across the Concur library. If the `:cause`
is itself a `concur-error`, its fields will be inherited.

  Arguments:
  - `ARGS` (plist): Keyword arguments matching the `concur-error` struct fields.
  - `:TYPE` (keyword): A keyword identifying the error type.
    Defaults to `:generic`.
  - `:MESSAGE` (string): A human-readable error message.
  - `:CAUSE` (any, optional): The original error or reason that caused this error.
  - `:PROMISE` (concur-promise, optional): The promise associated with error.
  - `:CMD`, `:CMD-ARGS`, `:CWD`, `:EXIT-CODE`, `:SIGNAL`, `:PROCESS-STATUS`,
    `:STDOUT`, `:STDERR`: Optional fields for process-related errors.

  Returns:
  - (concur-error): A new error struct."
  (let* ((initial-async-stack (concur-current-async-stack-string))
         (lisp-stack-trace nil)
         (final-args args))
    ;; Capture Lisp stack trace if the cause is a standard Emacs Lisp error.
    (when (and cause
               (consp cause)
               (symbolp (car-safe cause))
               (get (car-safe cause) 'error-conditions)
               (fboundp 'debug-last-call))
      (condition-case nil
          (setq lisp-stack-trace (with-output-to-string (debug-print-stack (list cause))))
        (error nil))) ; Don't fail just because stack trace capture failed

    ;; If cause is a concur-error, intelligently inherit its fields.
    (when (concur-error-p cause)
      (let ((fields-to-inherit '(:async-stack-trace :cmd :args :cwd :exit-code
                                 :signal :process-status :stdout :stderr)))
        (dolist (field fields-to-inherit)
          (unless (plist-get final-args field)
            (let ((value (cl-case field
                           (:async-stack-trace (concur-error-async-stack-trace cause))
                           ;; FIX: Use the correct slot reader `concur-error-args`
                           (:cmd (concur-error-cmd cause))
                           (:args (concur-error-args cause)) 
                           (:cwd (concur-error-cwd cause))
                           (:exit-code (concur-error-exit-code cause))
                           (:signal (concur-error-signal cause))
                           (:process-status (concur-error-process-status cause))
                           (:stdout (concur-error-stdout cause))
                           (:stderr (concur-error-stderr cause)))))
              (when value
                ;; FIX: Put the inherited value into the correct keyword in the plist.
                ;; The keyword in the struct is `:args`, so we must use that.
                (setq final-args (plist-put final-args :args value))))))))
    
    (apply #'%%make-concur-error
           :async-stack-trace (or lisp-stack-trace initial-async-stack)
           final-args)))

;;;###autoload
(cl-defmacro concur:with-executor (executor-fn-form &rest opts
                                   &key (mode :deferred) cancel-token 
                                   &environment env)
  "Define and execute an async block that controls a new promise.
This is a primary entry point for creating promises from imperative code. It
robustly captures the lexical environment of the executor lambda to ensure it
works correctly when byte-compiled. It also establishes context for resource
tracking, linking primitives used inside to the new promise.

  Arguments:
  - `EXECUTOR-FN-FORM` (lambda): A lambda of `(lambda (resolve reject) ...)`.
    `resolve` and `reject` are functions to settle the promise.
  - `OPTS` (plist): Options passed to `concur:make-promise` (e.g., `:name`).
  - `:MODE` (symbol, optional): Concurrency mode for the new promise.
    Defaults to `:deferred`.
  - `:CANCEL-TOKEN` (concur-cancel-token, optional): For cancellation.

  Returns:
  - (concur-promise): A new promise controlled by the executor."
  (declare (indent 1) (debug t))
  ;; Step 1: Analyze the executor lambda to find its free variables.
  ;; This is crucial for capturing the lexical context.
  (let* ((promise (gensym "promise-"))
         (analysis (concur-ast-analysis executor-fn-form env))
         (callable (concur-ast-analysis-result-expanded-callable-form analysis))
         (context-form (concur-ast-make-captured-vars-form
                        (concur-ast-analysis-result-free-vars-list analysis))))
    `(let ((,promise (concur:make-promise :mode ,mode :cancel-token ,cancel-token
                                          ,@opts)))
       ;; Step 2: Dynamically bind a tracking function. Any `concur` primitive
       ;; used inside the executor will call this hook to register its
       ;; resource (e.g., a lock) with the new promise.
       (let ((concur-resource-tracking-function
              (lambda (action resource)
                (pcase action
                  (:acquire (concur-registry-register-resource-hold
                             ,promise resource))
                  (:release (concur-registry-release-resource-hold
                             ,promise resource))))))
         ;; Step 3: Execute the user's code inside a `condition-case` to
         ;; catch any synchronous errors during initialization.
         (condition-case err
             (let ((context ,context-form))
               (concur--log :debug (concur-promise-id ,promise)
                            "Executing executor for promise %S."
                            (concur-promise-id ,promise))
               ;; **FIX:** Call the executor with exactly two arguments.
               (funcall ,callable
                        (lambda (value) (concur:resolve ,promise value))
                        (lambda (error) (concur:reject ,promise error))))
           (error
            ;; If the executor itself throws an error, reject the promise.
            (concur--log :error (concur-promise-id ,promise)
                         "Executor failed: %S" err)
            (concur:reject
             ,promise
             (concur:make-error :type :executor-error
                                :message (format "Executor failed: %S" err)
                                :cause err :promise ,promise))))
         ;; Step 4: Return the new promise immediately.
         ,promise))))

;;;###autoload
(defmacro concur:await (promise-form &optional timeout)
  "Synchronously and cooperatively wait for a promise to settle.
This provides a way to write asynchronous code in a more sequential style.

  Its behavior depends on the context:
  1.  **Outside a coroutine:** It blocks based on the promise's `mode`.
      - `:deferred`: Blocks Emacs cooperatively (UI remains responsive).
      - `:thread`: Blocks the current thread using a condition variable.
  2.  **Inside a `concur:async` coroutine:** It yields control to the
      coroutine scheduler, resuming only after the awaited promise settles.

  Arguments:
  - `PROMISE-FORM` (form): An form that evaluates to a `concur-promise`
    or another awaitable object.
  - `TIMEOUT` (number, optional): Seconds to wait before signaling a
    `concur-timeout-error` (only applies outside coroutines).
    If `nil`, waits indefinitely. If omitted, uses `concur-await-default-timeout`.

  Returns:
  - (any): The resolved value of the promise.

  Signals:
  - `concur-await-error`: If the promise is rejected.
  - `concur-timeout-error`: If the operation times out (only outside coroutine)."
  (declare (indent 1) (debug t))
  `(let ((p ,promise-form))
     (if (and (boundp 'coroutine--current-ctx) coroutine--current-ctx)
         ;; In a coroutine context, yield instead of blocking.
         (if (eq (concur:status p) :pending)
             (yield--internal-throw-form p ',concur--coroutine-yield-throw-tag)
           (if-let ((err (concur:error-value p)))
               (signal 'concur-await-error
                       (list (concur:error-message err) err))
             (concur:value p)))
       ;; Outside a coroutine, block synchronously.
       (concur--await-blocking p (or ,timeout concur-await-default-timeout)))))

;;;###autoload
(defmacro concur:from-callback (fetch-fn-form)
  "Wrap a traditional callback-based async function into a `concur-promise`.
This is a bridge for older APIs that use the `(lambda (result error) ...)`
pattern, integrating them seamlessly into the Promise system.

  Arguments:
  - `FETCH-FN-FORM` (form): A form that evaluates to a function. This
    function is called with a single argument: the `(result error)` callback.

  Returns:
  - (concur-promise): A promise that resolves or rejects when
    the underlying callback is invoked."
  (declare (indent 1) (debug t))
  `(concur:with-executor
       (lambda (resolve reject)
         (funcall ,fetch-fn-form
                  (lambda (result error)
                    (if error
                        (funcall reject error)
                      (funcall resolve result)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Promise Introspection & Unhandled Rejection API

;;;###autoload
(defun concur:status (promise)
  "Return current state of a PROMISE without blocking.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (symbol): The current state (`:pending`, `:resolved`, or `:rejected`)."
  (unless (concur-promise-p promise)
    (user-error "concur:status: Invalid promise object: %S" promise))
  (concur-promise-state promise))

;;;###autoload
(defun concur:pending-p (promise)
  "Return non-nil if PROMISE is pending.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (boolean): `t` if pending, `nil` otherwise."
  (unless (concur-promise-p promise)
    (user-error "concur:pending-p: Invalid promise object: %S" promise))
  (eq (concur:status promise) :pending))

;;;###autoload
(defun concur:resolved-p (promise)
  "Return non-nil if PROMISE has resolved successfully.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (boolean): `t` if resolved, `nil` otherwise."
  (unless (concur-promise-p promise)
    (user-error "concur:resolved-p: Invalid promise object: %S" promise))
  (eq (concur:status promise) :resolved))

;;;###autoload
(defun concur:rejected-p (promise)
  "Return non-nil if PROMISE was rejected.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (boolean): `t` if rejected, `nil` otherwise."
  (unless (concur-promise-p promise)
    (user-error "concur:rejected-p: Invalid promise object: %S" promise))
  (eq (concur:status promise) :rejected))

;;;###autoload
(defun concur:cancelled-p (promise)
  "Return non-nil if PROMISE was cancelled.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (boolean): `t` if cancelled, `nil` otherwise."
  (unless (concur-promise-p promise)
    (user-error "concur:cancelled-p: Invalid promise object: %S" promise))
  (concur-promise-cancelled-p promise))

;;;###autoload
(defun concur:value (promise)
  "Return resolved value of PROMISE, or nil if not resolved. Non-blocking.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (any): The resolved value, or `nil` if not resolved."
  (unless (concur-promise-p promise)
    (user-error "concur:value: Invalid promise object: %S" promise))
  (when (eq (concur:status promise) :resolved)
    (concur-promise-result promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return error of PROMISE if rejected, else nil. Non-blocking.

  Arguments:
  - `PROMISE` (concur-promise): The promise to inspect.

  Returns:
  - (concur-error or nil): The rejection error, or `nil`."
  (unless (concur-promise-p promise)
    (user-error "concur:error-value: Invalid promise object: %S" promise))
  (when (eq (concur:status promise) :rejected)
    (concur-promise-error promise)))

;;;###autoload
(defun concur:error-message (promise-or-error)
  "Return human-readable message from a promise's error or an error object.

  Arguments:
  - `PROMISE-OR-ERROR` (concur-promise or concur-error or any): A promise or
    error object.

  Returns:
  - (string): A descriptive error message."
  (let ((err (if (concur-promise-p promise-or-error)
                 (concur:error-value promise-or-error)
               promise-or-error)))
    (if (concur-error-p err) (concur-error-message err)
      (format "%S" err)))) ; Use %S for generic object stringification

;;;###autoload
(defun concur:format-promise (p)
  "Return human-readable string representation of a promise.
This function leverages the promise registry for descriptive names.

  Arguments:
  - `P` (concur-promise): The promise to format.

  Returns:
  - (string): A descriptive string including ID, mode, state, and name."
  (unless (concur-promise-p p)
    (user-error "concur:format-promise: Invalid promise object: %S" p))
  (let* ((id (concur-promise-id p))
         (mode (concur-promise-mode p))
         (status (concur:status p))
         (name (if (fboundp 'concur-registry-get-promise-name)
                   (concur-registry-get-promise-name p (symbol-name id))
                 (symbol-name id))))
    (pcase status
      (:pending (format "#<Promise %s (%s) %s: pending>" name id mode))
      (:resolved (format "#<Promise %s (%s) %s: resolved with %s>" name id mode
                         (s-truncate concur-log-value-max-length
                                     (format "%S" (concur:value p)))))
      (:rejected (format "#<Promise %s (%s) %s: rejected with %s>" name id mode
                         (s-truncate concur-log-value-max-length
                                     (concur:error-message (concur:error-value p))))))))

(defun concur-unhandled-rejections-count ()
  "Return the number of unhandled promise rejections currently queued.

  Returns:
  - (integer): The count of unhandled rejections."
  (length concur--unhandled-rejections-queue))

(defun concur-get-unhandled-rejections ()
  "Return a list of all currently tracked unhandled promise rejections.
This function clears the internal queue after returning the list.

  Returns:
  - (list): A list of `concur-error` objects."
  (prog1 (nreverse concur--unhandled-rejections-queue)
    (setq concur--unhandled-rejections-queue '())))

(defun concur-has-unhandled-rejections-p ()
  "Return non-nil if there are any unhandled promise rejections queued.

  Returns:
  - (boolean): `t` if unhandled rejections exist, `nil` otherwise."
  (not (null concur--unhandled-rejections-queue)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Low-Level Primitives for Library Authors

(defun concur-attach-callbacks (promise &rest callbacks)
  "Attach a set of callbacks to a PROMISE.
This is a low-level primitive intended for macro authors or
advanced use. For general use, prefer `concur:then`.

  Arguments:
  - `PROMISE` (concur-promise): The promise to attach callbacks to.
  - `CALLBACKS` (list of `concur-callback`): A list of `concur-callback`
    structs to attach.

  Returns:
  - (concur-promise): The original `PROMISE`."
  (unless (concur-promise-p promise)
    (user-error "concur-attach-callbacks: Invalid promise object: %S" promise))
  (let* ((non-nil-callbacks (-filter #'identity callbacks))
         (link (%%make-callback-link :id (gensym "link-")
                                     :callbacks non-nil-callbacks)))
    (concur:with-mutex! (concur-promise-lock promise)
      (if (eq (concur-promise-state promise) :pending)
          ;; Promises/A+ Spec 2.2.6: `then` may be called multiple times on the
          ;; same promise.
          (push link (concur-promise-callbacks promise))
        ;; If already settled, schedule the callbacks now.
        (concur--partition-and-schedule-callbacks (list link)))))
  promise)

(cl-defun concur-make-resolved-callback
    (handler-fn target-promise &key context captured-vars)
  "Create a `concur-callback` struct for a resolved handler.

  Arguments:
  - `HANDLER-FN` (function): The success handler function.
  - `TARGET-PROMISE` (concur-promise): The promise this callback will settle.
  - `:CONTEXT` (hash-table or alist): An explicit context to merge.
  - `:CAPTURED-VARS` (alist): An alist of captured vars from AST analysis.

  Returns:
  - (concur-callback): A new callback struct."
  (unless (functionp handler-fn)
    (error "concur-make-resolved-callback: HANDLER-FN must be a function: %S" handler-fn))
  (unless (concur-promise-p target-promise)
    (error "concur-make-rejected-callback: TARGET-PROMISE must be a promise: %S" target-promise))
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (%%make-callback :type :resolved :fn handler-fn
                     :promise target-promise
                     :context `',final-context)))

(cl-defun concur-make-rejected-callback
    (handler-fn target-promise &key context captured-vars)
  "Create a `concur-callback` struct for a rejected handler.

  Arguments:
  - `HANDLER-FN` (function): The failure handler function.
  - `TARGET-PROMISE` (concur-promise): The promise this callback will settle.
  - `:CONTEXT` (hash-table or alist): An explicit context to merge.
  - `:CAPTURED-VARS` (alist): An alist of captured vars from AST analysis.

  Returns:
  - (concur-callback): A new callback struct."
  (unless (functionp handler-fn)
    (error "concur-make-rejected-callback: HANDLER-FN must be a function: %S" handler-fn))
  (unless (concur-promise-p target-promise)
    (error "concur-make-rejected-callback: TARGET-PROMISE must be a promise: %S" target-promise))
  (let ((final-context (concur--merge-contexts context captured-vars)))
    (%%make-callback :type :rejected :fn handler-fn
                     :promise target-promise
                     :context `',final-context)))

;; Initialize the thread signaling mechanism on load, if threads are available.
(concur--init-thread-signaling)
;; Initialize the global macrotask queue.
(concur--init-macrotask-queue)

(provide 'concur-core)
;;; concur-core.el ends here