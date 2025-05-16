;;; concur-coroutine.el --- Coroutine control primitives for cooperative concurrency -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides low-level coroutine control primitives for use
;; in cooperative concurrency systems. It implements yield, throw, and
;; catch mechanisms tailored for structured coroutines running in Emacs Lisp.
;;
;; These coroutines operate on an explicit context (managed internally),
;; allowing for step-wise, resumable execution with proper support for:
;;
;; - Yielding values from inside coroutines (`concur-coroutine-yield`)
;; - Catching coroutine-level throws (`concur-coroutine-catch!`)
;; - Throwing errors or values between steps (`concur-coroutine-throw!`)
;;
;; Coroutine contexts are managed transparently, but consumers must ensure
;; these forms are only used within an active coroutine context.
;;
;; This forms the foundation for higher-level concurrency constructs such as
;; async workflows, generators, schedulers, and task runners.
;;
;; Each coroutine maintains:
;; - A stack of active catch tags
;; - A "sent" value received upon resume
;; - Optional throw metadata (flag, tag, value)
;;
;; Example:
;;
;; (concur-coroutine-catch! 'my-tag
;;   (when (some-condition)
;;     (concur-coroutine-throw! 'my-tag "aborted")))
;;
;; (let ((val (concur-coroutine-yield 'intermediate)))
;;   ;; Resume with new value here...
;;   )
;;
;;; Code:

(require 'cl-lib)
(require 'concur-generator)
(require 'dash)
(require 'ht)
(require 'scribe)

(define-error 'concur-coroutine-done "Coroutine has finished execution")

(cl-defstruct
    (concur-coroutine-ctx
     (:constructor nil)
     (:constructor concur-coroutine-ctx-create (&key state locals catch-stack done 
                                                     throw-flag throw-tag throw-val 
                                                     before after on-error sent)))
  "Context struct holding coroutine execution state.

Fields:

`state`        Current step index.
`locals`       Hash table of coroutine-local variables.
`catch-stack`  Stack of catch tags (for `coroutine-catch` / `coroutine-throw`).
`done`         Non-nil if coroutine has finished.
`throw-flag`   Non-nil if a `coroutine-throw` has been signaled.
`throw-tag`    Tag of pending throw.
`throw-val`    Value of pending throw.
`before`       Optional pre-step hook: (fn step idx results ctx).
`after`        Optional post-step hook: (fn step idx results ctx result).
`on-error`     Optional error handler: (fn error ctx).
`sent`         Value sent to coroutine (via `send`)."
state
locals
catch-stack
done
throw-flag
throw-tag
throw-val
before
after
on-error
sent)

(defun concur-coroutine--current-ctx ()
  "Retrieve current coroutine context from dynamic binding.
Throws if `concur-coroutine-ctx` is not bound."
  (or (bound-and-true-p concur-coroutine-ctx)
      (error "No coroutine context bound")))

(defun concur-coroutine--split-steps (body)
  "Wrap BODY forms as zero-arg lambdas.
Special forms like `concur-coroutine-catch!` and `concur-coroutine-throw!` are left as-is."
  (--map (if (and (listp it)
                  (memq (car it) '(concur-coroutine-catch! concur-coroutine-throw!)))
           `(lambda () ,it)
         `(lambda () ,it))
         body))

(defun concur-coroutine--make-step-fn (step-lambda ctx)
  "Return a function that runs STEP-LAMBDA in the local environment of CTX.
Coroutine locals from `ctx`'s hash table are let-bound dynamically."
  (lambda ()
    (let* ((locals (concur-coroutine-ctx-locals ctx))
           (bindings (--map `(,it ,(ht-get locals it)) (ht-keys locals))))
      (log! "evaluating step with locals keys: %S" (ht-keys locals))
      (eval `(let ,bindings (funcall ,step-lambda))))))

(defun concur-coroutine--run-step (ctx step-lambda)
  "Execute a single STEP-LAMBDA in CTX with full error/throw handling.
Returns a plist containing :result, :throw? (boolean), :throw-tag, :throw-val."
  (let ((result nil)
        (thrown nil)
        (throw-tag nil)
        (throw-val nil))
    (log! "entering step with ctx-state=%s"
          (concur-coroutine-ctx-state ctx))
    (condition-case err
        (setq result
              (catch 'coroutine-catch
                (funcall step-lambda)))
      (error
       (log! "ERROR %S in ctx-state=%s"
             err (concur-coroutine-ctx-state ctx) :error :trace)
       (if-let ((handler (concur-coroutine-ctx-on-error ctx)))
           (funcall handler err ctx)
         (signal (car err) (cdr err)))))
    ;; Handle coroutine-level throw
    (when (and (concur-coroutine-ctx-throw-flag ctx)
               (equal (concur-coroutine-ctx-throw-tag ctx)
                      (car (concur-coroutine-ctx-catch-stack ctx))))
      (setq thrown t
            throw-tag (concur-coroutine-ctx-throw-tag ctx)
            throw-val (concur-coroutine-ctx-throw-val ctx))
      (log! "caught throw %S %S" throw-tag throw-val)
      (setf (concur-coroutine-ctx-throw-flag ctx) nil)
      (pop (concur-coroutine-ctx-catch-stack ctx)))
    (log! "result=%S thrown=%s" result thrown)
    `(:result ,result :throw? ,thrown :throw-tag ,throw-tag :throw-val ,throw-val)))

;;;###autoload
(defun concur-coroutine-resume (runner &optional send-val)
  "Resume coroutine RUNNER, optionally sending SEND-VAL.
Returns the next yielded value or signals `concur-coroutine-done` when finished."
  (let ((ctx (plist-get (symbol-plist runner) :coroutine-ctx)))
    (unless ctx
      (error "Runner does not have associated coroutine context"))
    (log! "resuming runner %S with send-val=%S"
          runner send-val)
    (setf (concur-coroutine-ctx-sent ctx) send-val)
    (let ((result (funcall runner)))
      (if (concur-coroutine-ctx-done ctx)
          (progn
            (log! "runner done, signaling done")
            (signal 'concur-coroutine-done nil))
        (log! "yielded result %S" result)
        result))))

;;;###autoload
(defun concur-coroutine-yield! (value)
  "Yield VALUE from the coroutine and suspend execution.
Resumes from this step when re-invoked. Must be used inside a coroutine."
  (log! "yielding value %S" value)
  (setf (concur-coroutine-ctx-sent (concur-coroutine--current-ctx)) nil)
  (throw 'concur-coroutine-yield! value))

;;;###autoload
(defmacro concur-coroutine-throw! (tag val)
  "Signal a coroutine-level throw with TAG and value VAL.
Causes unwinding to nearest `concur-coroutine-catch!` matching TAG."
  `(let ((ctx (concur-coroutine--current-ctx)))
     (log! "throwing tag %S with value %S" ,tag ,val)
     (setf (concur-coroutine-ctx-throw-flag ctx) t
           (concur-coroutine-ctx-throw-tag ctx) ,tag
           (concur-coroutine-ctx-throw-val ctx) ,val)
     (throw 'concur-coroutine-catch! ,val)))

;;;###autoload
(defmacro concur-coroutine-catch! (tag &rest body)
  "Catch coroutine throws tagged with TAG during execution of BODY.
Must be used inside a coroutine. TAG is pushed on the dynamic catch stack."
  (declare (indent 1))
  (let ((ctx-sym (make-symbol "ctx")))
    `(let ((,ctx-sym (concur-coroutine--current-ctx)))
       (log! "entering catch block for tag %S" ,tag)
       (catch 'concur-coroutine-catch!
         (push ,tag (concur-coroutine-ctx-catch-stack ,ctx-sym))
         (unwind-protect
             (progn ,@body)
           (pop (concur-coroutine-ctx-catch-stack ,ctx-sym)))))))

;;;###autoload
(defun concur-coroutine-done? (runner)
  "Return non-nil if coroutine RUNNER has finished."
  (let ((ctx (plist-get (symbol-plist runner) :coroutine-ctx)))
    (log! "checking done state for runner %S: %S"
          runner (and ctx (concur-coroutine-ctx-done ctx)))
    (and ctx (concur-coroutine-ctx-done ctx))))

;;;###autoload
(defun concur-coroutine-cancel (runner)
  "Mark coroutine RUNNER as done, canceling further execution."
  (when-let ((ctx (plist-get (symbol-plist runner) :coroutine-ctx)))
    (log! "cancelling runner %S" runner)
    (setf (concur-coroutine-ctx-done ctx) t)))

;;;###autoload
(defmacro defcoroutine! (name args &rest body)
  "Define a resumable coroutine NAME with ARGS and BODY as steps.
Supports :locals to define coroutine-local variables.
Returns a thunk that resumes the coroutine one step per call.

Example:
  (defcoroutine! my-co (:locals (x y))
    (setq x 1)
    (concur-coroutine-yield! x)
    (setq y 2)
    (message \"sum: %d\" (+ x y)))"
  (declare (indent defun))
  (let* ((ctx-sym (make-symbol "ctx"))
         (runner-sym (make-symbol "runner"))
         (locals-entry (--find (eq (car it) :locals) (-partition 2 args)))
         (locals-vars (cadr locals-entry))
         (args-core (--remove (memq (car it) '(:locals)) args))
         (steps (concur-coroutine--split-steps body))
         (wrapped-steps
          (--map `(:form (lambda ()
                           (log! "running step in coroutine %s" ',name)
                           (let ((res (concur-coroutine--run-step
                                       ,ctx-sym
                                       (concur-coroutine--make-step-fn ,it ,ctx-sym))))
                             (if (plist-get res :throw?)
                                 (progn
                                   (log! "step threw coroutine-throw!, re-throwing")
                                   (signal 'concur-coroutine-throw!
                                           (list (plist-get res :throw-tag)
                                                 (plist-get res :throw-val))))
                               (plist-get res :result))))) steps))
         (name-str (symbol-name name)))
    `(progn
       (defun ,name ,args-core
         (log! "initializing coroutine %s" ,name-str)
         (let ((,ctx-sym (concur-coroutine-ctx-create
                          :state 0 :locals (ht-create)
                          :catch-stack nil :done nil
                          :throw-flag nil :throw-tag nil :throw-val nil
                          :before nil :after nil :on-error nil :sent nil)))
           ;; Initialize coroutine locals
           ,@(when locals-vars
               `((dolist (sym ',locals-vars)
                   (log! "initializing local var %S to nil" sym)
                   (ht-set! (concur-coroutine-ctx-locals ,ctx-sym) sym nil))))
           ;; Construct generator runner
           (let ((,runner-sym
                  (concur-generator
                   ',wrapped-steps
                   (list
                    :context ,ctx-sym
                    :before (lambda (step idx results ctx)
                              (setf (concur-coroutine-ctx-state ,ctx-sym) idx)
                              (log! "coroutine-before [%s] step %d" ,name-str idx)
                              (when-let ((hook (concur-coroutine-ctx-before ,ctx-sym)))
                                (funcall hook step idx results ctx)))
                    :after (lambda (step idx results ctx result)
                             (log! "coroutine-after [%s] step %d => %S"
                                   ,name-str idx result)
                             (when-let ((hook (concur-coroutine-ctx-after ,ctx-sym)))
                               (funcall hook step idx results ctx result)))
                    :on-error (lambda (err idx step ctx bt)
                                (log! "[Coroutine %s] Step %d error: %S"
                                      ,name-str idx err :trace)
                                (when-let ((hook (concur-coroutine-ctx-on-error ,ctx-sym)))
                                  (funcall hook err idx step ctx bt)))))))
             (put ,runner-sym :coroutine-ctx ,ctx-sym)
             ,runner-sym))))))

(provide 'concur-coroutine)
;;; concur-coroutine.el ends here             