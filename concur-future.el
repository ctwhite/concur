;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-future.el --- Concurrency primitives for lazy async tasks -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides primitives for working with "futures". A future
;; represents a deferred computation that is evaluated lazily only when its
;; result is needed. This is useful for defining expensive or asynchronous
;; operations without paying the cost until the result is actually requested.
;;
;; Futures use promises internally to manage the asynchronous result once the
;; computation is "forced" (i.e., executed).
;;
;; Key Features:
;; - Lazy Evaluation: A future's computation (its "thunk") is only run
;;   the first time its result is requested via `concur:force`.
;; - Thread-Safety: Forcing a future is an atomic, thread-safe operation.
;; - Concurrency Mode Propagation: Futures store a concurrency `mode` that is
;;   passed to their internal promise when forced, ensuring correct
;;   synchronization.
;; - Composability: Futures can be chained, composed, and integrate
;;   seamlessly with `concur-promise` objects.

;;; Code:

(require 'cl-lib)        ; For cl-defstruct, cl-loop
(require 'dash)          ; For --map
(require 'concur-ast)    ; For AST analysis and lexical context capture
(require 'concur-core)   ; For `concur-promise` types, `concur:make-promise`,
                         ; `concur:resolved!`, `concur:rejected!`,
                         ; `concur:resolve`, `concur:reject`, `concur:force`,
                         ; `concur-promise-p`, `concur-promise-mode`,
                         ; `concur-chain-or-settle-promise`, `user-error`, `concur--log`
(require 'concur-chain)  ; For `concur:then`, `concur:catch`, `concur:race`
                         ; (used by future chaining macros)
(require 'concur-lock)   ; For `concur-lock` and `concur:with-mutex!`

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Forward Declarations for Combinators (from concur-combinators.el)

(declare-function concur:all "concur-combinators")
(declare-function concur:race "concur-combinators")
(declare-function concur:delay "concur-combinators")
(declare-function concur:timeout "concur-combinators") ; Used by concur:future-timeout

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct Definition

(cl-defstruct (concur-future (:constructor %%make-future))
  "A lazy future represents a deferred computation.
Do not construct directly; use `concur:make-future`.

  Arguments:
  - `promise` (concur-promise or nil): The cached promise, created on demand
    when the future is first forced. It holds the result of the thunk.
    Defaults to `nil`.
  - `thunk` (function): A zero-argument function that performs the computation
    when the future is forced. This is the lazy part.
  - `evaluated-p` (boolean): A flag to ensure the thunk is only ever run once.
    Defaults to `nil`.
  - `mode` (symbol): The concurrency mode for the promise created by this
    future. Defaults to `:deferred`.
  - `lock` (concur-lock): A mutex to ensure that forcing the future is a
    thread-safe, atomic operation. Defaults to `nil` (initialized in
    `concur:make-future`)."
  (promise nil :type (or null (satisfies concur-promise-p)))
  (thunk (lambda () (error "Empty future thunk")) :type function)
  (evaluated-p nil :type boolean)
  (mode :deferred :type (member :deferred :thread :async))
  (lock nil :type (or null (satisfies concur-lock-p))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Future Creation & Forcing

;;;###autoload
(cl-defmacro concur:make-future (thunk-form &key (mode :deferred) &environment env)
  "Create a `concur-future` from THUNK-FORM.
The returned future represents a computation that is performed lazily when
`concur:force` is called. Lexical variables from the surrounding scope
are automatically captured via AST analysis.

  Arguments:
  - `THUNK-FORM` (form): A zero-argument lambda `(lambda () ...)`
    that performs the computation. Its return value can be a normal
    value or another awaitable (like a promise or another future).
  - `:MODE` (symbol, optional): The concurrency mode for the promise created
    when this future is forced. Defaults to `:deferred`.

  Returns:
  - (concur-future): A new `concur-future` object."
  (declare (indent 1) (debug t))
  (unless (listp thunk-form)
    (user-error "concur:make-future: THUNK-FORM must be a lambda: %S"
                thunk-form))
  (let* ((analysis (concur-ast-analysis thunk-form env))
         (callable (concur-ast-analysis-result-expanded-callable-form analysis))
         (free-vars (concur-ast-analysis-result-free-vars-list analysis))
         (context-form (concur-ast-make-captured-vars-form free-vars))
         (future-id (gensym "future-")))
    ;; The outer `let` captures the `context` when the future is created.
    `(let ((context ,context-form))
       (concur--log :debug nil "Creating future %S in mode %S."
                    ',future-id ,mode)
       (%%make-future
        :lock (concur:make-lock (format "future-lock-%S" ',future-id)
                                :mode ,mode)
        :mode ,mode
        :thunk (lambda ()
                 ,(format "Thunk for future %S." future-id)
                 ;; When the thunk finally executes, it unpacks the captured
                 ;; variable values into its own lexical environment.
                 (cl-destructuring-bind
                     (,@(cl-loop for var in free-vars
                                 collect var))
                     (cl-loop for var in free-vars
                              collect (gethash var context))
                   (concur--log :debug nil "Forcing future %S - executing thunk."
                                ',future-id)
                   (funcall ,callable)))))))

;;;###autoload
(defun concur:force (future)
  "Force FUTURE's thunk to run if not already evaluated.
This function is idempotent and thread-safe. The first time it is called on
a future, it executes the future's deferred computation (`thunk`). Subsequent
calls will return the same cached promise without re-running the thunk.

  Arguments:
  - `FUTURE` (concur-future): The future object to force.

  Returns:
  - (concur-promise): The promise associated with the future's result."
  (unless (concur-future-p future)
    (user-error "concur:force: Invalid future object: %S" future))

  ;; The entire forcing operation is atomic to prevent race conditions
  ;; where two threads could try to evaluate the same future simultaneously.
  (concur:with-mutex! (concur-future-lock future)
    (if (concur-future-evaluated-p future)
        (progn
          (concur--log :debug nil "Future %S already forced, returning cached promise."
                       (concur-future-id future))
          (concur-future-promise future))
      ;; Mark as evaluated immediately inside the lock to prevent re-entrancy.
      (setf (concur-future-evaluated-p future) t)
      ;; Create and store the promise that will hold the future's result.
      (let* ((promise (concur:make-promise :mode (concur-future-mode future)
                                           :name (format "future-promise-%S"
                                                         (concur-future-id future))))
             (thunk-result nil))
        (setf (concur-future-promise future) promise)
        (concur--log :info nil "Forcing future %S - executing thunk for first time."
                     (concur-future-id future))
        (condition-case err
            (setq thunk-result (funcall (concur-future-thunk future)))
          (error
           ;; If the thunk signals a synchronous error, reject our promise.
           (concur--log :error nil "Future %S thunk failed synchronously: %S"
                        (concur-future-id future) err)
           (concur:reject promise (concur:make-error :type :executor-error
                                                     :message (format "Future thunk failed: %S" err)
                                                     :cause err :promise promise))))
        ;; The result of the thunk might itself be a promise or another
        ;; future. `chain-or-settle` handles this correctly.
        (unless (concur:rejected-p promise) ; Don't try to settle if already rejected by error
          (concur-chain-or-settle-promise promise thunk-result))
        promise))))

;;;###autoload
(defun concur:future-get (future &optional timeout)
  "Force FUTURE and get its result, blocking cooperatively until available.
This function is synchronous and behaves identically to `concur:await` on
the future's underlying promise. Use with caution in performance-sensitive
or UI-related code.

  Arguments:
  - `FUTURE` (concur-future): The future whose result is needed.
  - `TIMEOUT` (number, optional): Maximum seconds to wait before erroring.

  Returns:
  - (any): The resolved value of the future.

  Signals:
  - `concur-error`: On rejection or timeout."
  (unless (concur-future-p future)
    (user-error "concur:future-get: Invalid future object: %S" future))
  (concur--log :info nil "Getting result for future %S (timeout: %S)."
               (concur-future-id future) timeout)
  (concur:await (concur:force future) timeout))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Future Creation (Pre-settled & Delayed)

;;;###autoload
(cl-defun concur:future-resolved! (value &key (mode :deferred))
  "Return a new `concur-future` that is already resolved with VALUE.
This future's thunk is never run; it directly contains a resolved promise.

  Arguments:
  - `VALUE` (any): The value for the pre-resolved future.
  - `:MODE` (symbol, optional): Concurrency mode for the future's internal promise.

  Returns:
  - (concur-future): A new, already-evaluated future."
  (let ((promise (concur:resolved! value :mode mode)))
    (concur--log :debug nil "Creating pre-resolved future with value %S." value)
    (%%make-future :promise promise :evaluated-p t :mode mode
                   :lock (concur:make-lock (format "future-lock-%S" (gensym))
                                           :mode mode))))

;;;###autoload
(cl-defun concur:future-rejected! (error &key (mode :deferred))
  "Return a new `concur-future` that is already rejected with ERROR.
This future's thunk is never run; it directly contains a rejected promise.

  Arguments:
  - `ERROR` (any): The error for the pre-rejected future.
  - `:MODE` (symbol, optional): Concurrency mode for the future's internal promise.

  Returns:
  - (concur-future): A new, already-evaluated future."
  (let ((promise (concur:rejected! error :mode mode)))
    (concur--log :debug nil "Creating pre-rejected future with error %S." error)
    (%%make-future :promise promise :evaluated-p t :mode mode
                   :lock (concur:make-lock (format "future-lock-%S" (gensym))
                                           :mode mode))))

;;;###autoload
(cl-defun concur:future-delay (seconds &optional value &key (mode :deferred))
  "Create a `concur-future` that resolves with VALUE after SECONDS.
The timer starts only when the future is forced via `concur:force`.

  Arguments:
  - `SECONDS` (number): The delay duration. Must be non-negative.
  - `VALUE` (any, optional): The value to resolve with. Defaults to `t`.
  - `:MODE` (symbol, optional): The concurrency mode for the future's promise.

  Returns:
  - (concur-future): A new, lazy future."
  (unless (and (numberp seconds) (>= seconds 0))
    (user-error "concur:future-delay: SECONDS must be a non-negative number: %S"
                seconds))
  (concur--log :debug nil "Creating lazy delay future for %Ss." seconds)
  (concur:make-future (lambda () (concur:delay seconds value)) :mode mode))

;;;###autoload
(cl-defun concur:future-timeout (future timeout-seconds)
  "Create a new future that, when forced, applies a timeout to `FUTURE`.
The timeout is applied to the promise produced by `FUTURE` when it's forced.

  Arguments:
  - `FUTURE` (concur-future): The future to apply a timeout to.
  - `TIMEOUT-SECONDS` (number): The timeout duration in seconds.

  Returns:
  - (concur-future): A new future that wraps the original with a timeout."
  (unless (concur-future-p future)
    (user-error "concur:future-timeout: FUTURE must be a future: %S" future))
  (unless (and (numberp timeout-seconds) (> timeout-seconds 0))
    (user-error "concur:future-timeout: TIMEOUT-SECONDS must be a positive number: %S"
                timeout-seconds))
  (concur--log :debug nil "Creating timeout future for %S (%Ss)."
               (concur-future-id future) timeout-seconds)
  (concur:make-future
   (lambda ()
     (concur:timeout (concur:force future) timeout-seconds))
   :mode (concur-future-mode future)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Future Chaining & Composition

;;;###autoload
(cl-defmacro concur:future-then (future transform-fn &environment env)
  "Apply `TRANSFORM-FN` to the result of a future, creating a new future.
The new future is also lazy. When it is forced, it will first force the
original `FUTURE`. Once the original future resolves, `TRANSFORM-FN` is
applied to its result to produce the new future's result.

  Arguments:
  - `FUTURE` (concur-future): The parent future.
  - `TRANSFORM-FN` (form): A lambda `(lambda (value) ...)` or function symbol.

  Returns:
  - (concur-future): A new future representing the chained computation."
  (declare (indent 1) (debug t))
  `(concur:make-future
    (lambda ()
      (concur--log :debug nil "Forcing `future-then` child future, chaining from %S."
                   (concur-future-id ,future))
      (concur:then (concur:force ,future) ,transform-fn))
    :mode (concur-future-mode ,future)))

;;;###autoload
(cl-defmacro concur:future-catch (future error-handler-fn &environment env)
"Attach an error handler to a future, creating a new recoverable future.
The new future is lazy. When forced, it forces the original future and, if
it rejects, applies the `ERROR-HANDLER-FN`.

  Arguments:
  - `FUTURE` (concur-future): The parent future.
  - `ERROR-HANDLER-FN` (form): A lambda `(lambda (error) ...)` or function symbol.

  Returns:
  - (concur-future): A new future that can handle the original's failure."
  (declare (indent 1) (debug t))
  `(concur:make-future
    (lambda ()
      (concur--log :debug nil "Forcing `future-catch` child future, chaining from %S."
                   (concur-future-id ,future))
      (concur:catch (concur:force ,future) ,error-handler-fn))
    :mode (concur-future-mode ,future)))

;;;###autoload
(defun concur:future-all (futures)
  "Create a future that, when forced, runs a list of FUTURES in parallel.
The resulting promise propagates the strongest concurrency mode from the
individual futures.

  Arguments:
  - `FUTURES` (list): A list of `concur-future` objects.

  Returns:
  - (concur-future): A new future that will resolve with a list of all results."
  (unless (listp futures)
    (user-error "concur:future-all: FUTURES must be a list: %S" futures))
  (concur--log :debug nil "Creating `future-all` for %d futures."
               (length futures))
  (concur:make-future
   (lambda ()
     (let* ((promises (--map (concur:force it) futures))
            (strongest-mode (concur-determine-strongest-mode promises)))
       (concur--log :debug nil "Forcing `future-all`, waiting for %d promises."
                    (length promises))
       (concur:all promises :mode strongest-mode)))))

;;;###autoload
(defun concur:future-race (futures)
  "Create a future that, when forced, races a list of FUTURES.
The resulting promise propagates the strongest concurrency mode from the
individual futures.

  Arguments:
  - `FUTURES` (list): A list of `concur-future` objects.

  Returns:
  - (concur-future): A new future that will settle with the first future to settle."
  (unless (listp futures)
    (user-error "concur:future-race: FUTURES must be a list: %S" futures))
  (concur--log :debug nil "Creating `future-race` for %d futures."
               (length futures))
  (concur:make-future
   (lambda ()
     (let* ((promises (--map (concur:force it) futures))
            (strongest-mode (concur-determine-strongest-mode promises)))
       (concur--log :debug nil "Forcing `future-race`, racing %d promises."
                    (length promises))
       (concur:race promises :mode strongest-mode)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API - Future Introspection

;;;###autoload
(defun concur:future-status (future)
  "Return a snapshot of the `FUTURE`'s current status.

  Arguments:
  - `FUTURE` (concur-future): The future to inspect.

  Returns:
  - (plist): A property list with future metrics:
    `:evaluated-p`: Whether the future's thunk has been executed.
    `:mode`: The concurrency mode of the future.
    `:promise-status`: The status of the underlying promise (`:pending`,
      `:resolved`, `:rejected`), or `nil` if not yet evaluated.
    `:promise-value`: The value of the underlying promise (if resolved).
    `:promise-error`: The error of the underlying promise (if rejected)."
  (interactive)
  (unless (concur-future-p future)
    (user-error "concur:future-status: Invalid future object: %S" future))
  (let* ((evaluated-p (concur-future-evaluated-p future))
         (promise (concur-future-promise future))
         (promise-status (when promise (concur:status promise)))
         (promise-value (when promise (concur:value promise)))
         (promise-error (when promise (concur:error-value promise))))
    `(:evaluated-p ,evaluated-p
      :mode ,(concur-future-mode future)
      :promise-status ,promise-status
      :promise-value ,promise-value
      :promise-error ,promise-error)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core Integration

(defun concur--future-normalize-awaitable (awaitable)
  "Normalize an awaitable into a promise if it's a `concur-future`.
This function is added to `concur-normalize-awaitable-hook` to allow core
functions like `concur:then` to transparently accept futures."
  (if (concur-future-p awaitable)
      (concur:force awaitable)
    nil))

;; Plug into the core promise system.
(add-hook 'concur-normalize-awaitable-hook #'concur--future-normalize-awaitable)

(provide 'concur-future)
;;; concur-future.el ends here