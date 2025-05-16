;;; concur-fsm.el --- Generator Pipeline FSM  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ht)
(require 'scribe)

;; FSM result keys
(defconst concur--done-tag :concur-done)
(defconst concur--yield-tag :yield)

;; FSM internal throw tags
(defconst concur--yield-throw-tag 'concur-yield)
(defconst concur--done-throw-tag 'concur-finished)

;; Signals
(defconst concur--timeout-signal 'timeout)

(cl-defstruct (concur-fsm
               (:constructor nil)
               (:constructor make-concur-fsm)
               (:copier nil))
  "A concurrent-style finite state machine (FSM) for orchestrating step-based control flows.

Each FSM maintains its execution context, step metadata, intermediate results, and error-handling information.

Fields:

`state`         The current FSM state, a symbol such as :init, :step, etc.
`index`         The integer index of the current step being executed.
`steps`         A list of step plists, each describing a unit of work and its callbacks.
`results`       A hash table storing named results from completed steps.
`context`       Arbitrary user data passed into each step’s callbacks.
`retries`       Number of allowed retries for a step on error.
`retry-count`   Current retry attempt count for the active step.
`step`          The plist describing the current step.
`step-result`   The result value from the last successful step execution.
`step-error`    The error object from the last failed step execution, if any.
`phase`         Execution phase, typically :normal or :finally.
`yielded`       Yielded result used to suspend and resume FSM execution.
`error-handler` Optional function called on error.
`error-store`   Optional function to log or store step errors.
`finished`      Final result of the FSM, usually a list with status and results."
  state
  index
  steps
  results
  context
  retries
  retry-count
  step
  step-result
  step-error
  phase
  yielded
  error-handler
  error-store
  finished)

(defun concur--run-callback (fn step idx results ctx &optional result)
  "Run FSM lifecycle callback FN for STEP at IDX with context CTX.
Ignores errors in callback. Passes RESULT if this is an :after callback."
  (when (functionp fn)
    (condition-case err
        (funcall fn step idx results ctx result)
      (error (message "[FSM callback error] %s" err)))))

;;;###autoload
(defun concur-fsm-transition (fsm)
  "Advance the FSM (finite state machine) by one transition step.
This function drives a step-based workflow (FSM) used by concur.el,
executing each step in order with optional `:before`, `:after`,
timeouts, retries, and error handling.

Each FSM step is a plist with the following keys:
  :name    - Identifier for the step, used in results and logging.
  :thunk   - A zero-arg function to execute.
  :before  - Optional callback run before the thunk.
  :after   - Optional callback run after the thunk.
  :timeout - Optional timeout (in seconds) for the thunk.

FSM phases:
  :init        -> Initialize internal state.
  :step        -> Load the next step or enter :done.
  :before-step -> Call the :before callback.
  :run-step    -> Execute the thunk with optional timeout.
  :after-step  -> Call the :after callback.
  :advance     -> Move to the next step.
  :yielded     -> Yield control externally.
  :error       -> Handle errors and optionally retry.
  :done        -> Final state, throws result."
  (pcase (concur-fsm-state fsm)
    ;; Initial state: clear metadata and prepare for stepping.
    (:init
     (log! "FSM init: clearing state." :level 'debug)
     (setf (concur-fsm-results fsm) (ht-create)
           (concur-fsm-index fsm) 0
           (concur-fsm-retry-count fsm) 0
           (concur-fsm-phase fsm) :normal
           (concur-fsm-state fsm) :step))

    ;; :step state: select the next step to run or finish.
    (:step
     (let ((index (concur-fsm-index fsm))
           (steps (concur-fsm-steps fsm)))
       (log! "FSM step: index=%d phase=%s" index (concur-fsm-phase fsm) :level 'debug)
       (if (>= index (length steps))
           ;; If we’ve run all normal steps, run final ones if any.
           (if (eq (concur-fsm-phase fsm) :normal)
               (progn
                 (log! "FSM switching to :finally phase." :level 'info)
                 (setf (concur-fsm-phase fsm) :finally
                       (concur-fsm-index fsm) 0
                       (concur-fsm-state fsm) :step))
             ;; Otherwise, we are done.
             (progn
               (log! "FSM completed all steps." :level 'info)
               (setf (concur-fsm-state fsm) :done
                     (concur-fsm-finished fsm) (list concur--done-tag t))))
         ;; Prepare to run the next step.
         (let ((step (nth index steps)))
           (log! "FSM preparing step %d: %s" index (plist-get step :name) :level 'debug)
           (setf (concur-fsm-step fsm) step
                 (concur-fsm-step-result fsm) nil
                 (concur-fsm-step-error fsm) nil
                 (concur-fsm-state fsm) :before-step)))))

    ;; :before-step state: run optional `:before` callback.
    (:before-step
     (let* ((step (concur-fsm-step fsm))
            (idx (concur-fsm-index fsm))
            (results (concur-fsm-results fsm))
            (ctx (concur-fsm-context fsm)))
       (log! "FSM before-step: %s" (plist-get step :name) :level 'debug)
       (concur--run-callback (plist-get step :before) step idx results ctx)
       (setf (concur-fsm-state fsm) :run-step)))

    ;; :run-step state: run the step’s thunk, with timeout and error handling.
    (:run-step
     (let* ((step (concur-fsm-step fsm))
            (name (plist-get step :name))
            (thunk (plist-get step :thunk))
            (timeout (plist-get step :timeout))
            result err)
       (log! "FSM run-step: %s (timeout=%s)" name timeout :level 'info)
       (condition-case caught
           ;; Run thunk with or without timeout.
           (setq result
                 (if timeout
                     (with-timeout (timeout (signal concur--timeout-signal nil))
                       (funcall thunk))
                   (funcall thunk)))
         ;; Handle errors via logging, storing, and user handler.
         (error
          (setq err caught)
          (let ((bt (with-output-to-string (backtrace))))
            (log! "Error in step %s: %S" name err :level 'error :trace)
            (when-let ((store (concur-fsm-error-store fsm)))
              (funcall store err name thunk step bt))
            (when-let ((handler (concur-fsm-error-handler fsm)))
              (funcall handler err name thunk step bt)))
          (setf (concur-fsm-step-error fsm) err
                (concur-fsm-state fsm) :error)))

       (when (not err)
         ;; Handle result: done, yielded, or store it.
         (cond
          ((equal result concur--done-tag)
           (log! "FSM done-tag detected in %s" name :level 'info)
           (setf (concur-fsm-state fsm) :done
                 (concur-fsm-finished fsm) (list concur--done-tag t)))

          ((and (listp result) (plist-get result concur--yield-tag))
           (log! "FSM yielded from %s" name :level 'info)
           (setf (concur-fsm-yielded fsm) result
                 (concur-fsm-state fsm) :yielded))

          (t
           (log! "FSM step %s completed with result." name :level 'debug)
           ;; Save result and move to :after-step
           (ht-set (concur-fsm-results fsm) name result)
           (setf (concur-fsm-step-result fsm) result
                 (concur-fsm-state fsm) :after-step))))))

    ;; :after-step state: run optional `:after` callback.
    (:after-step
     (let* ((step (concur-fsm-step fsm))
            (idx (concur-fsm-index fsm))
            (results (concur-fsm-results fsm))
            (ctx (concur-fsm-context fsm))
            (result (concur-fsm-step-result fsm)))
       (log! "FSM after-step: %s" (plist-get step :name) :level 'debug)
       (concur--run-callback (plist-get step :after) step idx results ctx result)
       (setf (concur-fsm-state fsm) :advance)))

    ;; :advance state: increment step index, reset retries.
    (:advance
     (log! "FSM advancing to next step." :level 'debug)
     (setf (concur-fsm-index fsm) (1+ (concur-fsm-index fsm))
           (concur-fsm-retry-count fsm) 0
           (concur-fsm-state fsm) :step))

    ;; :yielded state: throw to external handler to resume later.
    (:yielded
     (log! "FSM yielded control externally." :level 'info)
     (throw concur--yield-throw-tag
            `(:step-index ,(concur-fsm-index fsm)
              :step-name ,(plist-get (concur-fsm-step fsm) :name)
              :result ,(concur-fsm-yielded fsm)
              :done nil)))

    ;; :error state: optionally retry step, else store and continue.
    (:error
     (let ((retry (concur-fsm-retry-count fsm))
           (max-retries (concur-fsm-retries fsm))
           (step (concur-fsm-step fsm)))
       (log! "FSM error state for step %s: retry %d/%d"
             (plist-get step :name) retry max-retries :level 'warn)
       (if (< retry max-retries)
           ;; Retry the step.
           (progn
             (log! "FSM retrying step %s" (plist-get step :name) :level 'warn)
             (setf (concur-fsm-retry-count fsm) (1+ retry)
                   (concur-fsm-state fsm) :run-step))
         ;; Out of retries: store and handle error.
         (log! "FSM exhausted retries for %s, storing error." (plist-get step :name) :level 'error)
         (when-let ((fn (concur-fsm-error-store fsm)))
           (funcall fn (plist-get step :name) (concur-fsm-step-error fsm)))
         (when-let ((fn (concur-fsm-error-handler fsm)))
           (funcall fn (concur-fsm-step-error fsm)))
         (setf (concur-fsm-state fsm) :advance))))

    ;; :done state: throw result to indicate FSM completion.
    (:done
     (log! "FSM finished execution." :level 'info)
     (throw concur--done-throw-tag
            (or (concur-fsm-finished fsm)
                (list concur--done-tag t :results (concur-fsm-results fsm)))))

    ;; Fallback for unexpected states.
    (_ (error "[FSM] Unknown state: %S" (concur-fsm-state fsm)))))

;;;###autoload
(defun concur-fsm-run (steps &optional options)
  "Run STEPS as a generator-style FSM pipeline.

STEPS is a list of step plists. Each step plist should contain:
  :name    - a unique symbol or string identifying the step
  :thunk   - a no-argument function to run the step
  :timeout - optional timeout in seconds for the thunk
  :before  - optional function (step) called before running the thunk
  :after   - optional function (step) called after running the thunk

OPTIONS is a plist supporting:
  :retries       - number of retries per step (default 1)
  :error-store   - function (name error) to store/log errors
  :on-error      - function (error) called on unrecoverable errors

Returns a plist (:done t :results HASH-TABLE) when finished."
  (log! "Running FSM with %d steps." (length steps) :level 'info)
  (let ((fsm (make-concur-fsm
              :state :init
              :steps steps
              :context (or (plist-get options :context) (ht-create))
              :retries (or (plist-get options :retries) 1)
              :error-store (plist-get options :error-store)
              :error-handler (plist-get options :on-error))))
    (catch concur--throw-done-tag
      (catch concur--throw-yield-tag
        (while t
          (concur-fsm-transition fsm))))))

(provide 'concur-fsm)
;;; concur-fsm.el ends here          




