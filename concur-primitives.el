;;; concur-primitives.el --- Concurrency Primitives for Emacs Lisp -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This library provides basic concurrency primitives for Emacs Lisp,
;; including macros for ensuring code runs once, and for managing locks
;; (mutexes) and semaphores to protect critical sections and manage resource access.
;;
;; Features:
;; - `concur:once-do!`: Ensures a block of code runs only once.
;; - `concur:once-callback!`: A specialized version for executing a callback once.
;; - `concur:with-lock!`: A basic mutual exclusion lock for temporary critical sections (place-based).
;; - `concur:make-lock`, `concur:lock-acquire`, `concur:lock-release`:
;;   Functions for creating and managing explicit lock objects (mutexes).
;; - `concur:with-mutex!`: A macro that uses explicit lock objects to define critical sections.
;; - `concur:block-until`: A cooperative blocking primitive that yields control
;;   until a condition is met or a timeout occurs.
;; - Semaphores: `concur:make-semaphore` (formerly `concur-semaphore-new`),
;;   `concur:semaphore-acquire`, `concur:semaphore-try-acquire`,
;;   `concur:semaphore-release`, `concur:semaphore-reset`,
;;   `concur:semaphore-describe`, and `concur:with-semaphore!`.
;;
;; These primitives are designed to be simple and lightweight, suitable for
;; common concurrency patterns within Emacs Lisp where true multi-threading
;; is not available. They rely on atomic operations where possible and
;; `unwind-protect` to ensure proper resource cleanup.

;;; Code:

(require 'cl-lib)     ; For cl-lib functions, cl-defstruct, cl-incf, cl-decf
(require 'gv)         ; For generalized variables if `place` is not a simple symbol
(require 'subr-x)     ; For `when-let`
(require 'scribe)     ; For log!

;; Define a custom error type for timeouts
(define-error 'concur:timeout-error "Concurrency timeout error.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Once Execution Primitives                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro concur:once-do! (place fallback &rest body)
  "Run BODY once if PLACE is nil. Otherwise, run FALLBACK.

This macro ensures that a block of code is executed only once based on the
state of PLACE. If PLACE is nil, BODY is executed, and PLACE is set to `t`.
If PLACE is non-nil, FALLBACK is executed instead. FALLBACK can be either
a single form or a list of forms (e.g., `(:else FORM...)`).

Arguments:
- PLACE: A variable or place (could be a symbol or a generalized variable)
  that determines whether the body of code should be executed.
- FALLBACK: The code to run if PLACE is non-nil. Can either be a single value or
  a list of forms (e.g., `(:else FORM...)`).
- BODY: The code to run once if PLACE is nil.

Side Effects:
- Sets PLACE to `t` after executing BODY (if BODY completes successfully).
- If PLACE is non-nil, executes FALLBACK instead of BODY.
- Signals an error if PLACE is not a valid `setf`-able place.

Example:
  (let ((my-flag nil))
    (concur:once-do! my-flag
      (:else (message \"Already run!\"))
      (message \"Running for the first time\"))
    (concur:once-do! my-flag
      (:else (message \"Already run! (2nd)\"))
      (message \"This will not run again\")))"
  (declare (indent 2))
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     (list fallback))))
    `(if ,place
         (progn ,@else-body)
       (progn
         (setf ,place t)
         ,@body))))

;;;###autoload
(defmacro concur:once-callback! (flag callback &rest fallback)
  "Invoke CALLBACK once if FLAG is nil. Otherwise, run FALLBACK.

This macro is a specialized version of `concur:once-do!` that specifically
handles a callback function. It ensures that CALLBACK is called
only once, when FLAG is nil. If FLAG is non-nil, the code in
FALLBACK is executed.

Arguments:
- FLAG: A variable or place that determines whether the callback
  should be executed.
- CALLBACK: A function to call when FLAG is nil. If this is nil,
  nothing happens when FLAG is nil.
- FALLBACK: Code to execute if FLAG is non-nil. This can be a single
  form or a list of forms, as in `concur:once-do!`.

Side Effects:
- Sets FLAG to `t` after executing CALLBACK.
- If FLAG is non-nil, executes FALLBACK.
- Signals an error if FLAG is not a valid `setf`-able place.

Example:
  (let ((my-flag nil))
    (concur:once-callback! my-flag (lambda () (message \"Callback called\"))
                           (:else (message \"Fallback called\")))
    (concur:once-callback! my-flag (lambda () (message \"Callback called again\"))
                           (:else (message \"Fallback called again\"))))"
  (declare (indent 2))
  `(concur:once-do! ,flag
     (:else ,@fallback)
     (when ,callback
       (funcall ,callback))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                         Basic Lock (Mutex) Primitives                      ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defmacro concur:with-lock! (place fallback &rest body)
  "Acquire a lock on PLACE temporarily during the execution of BODY.

This macro ensures that the code in BODY will only execute if PLACE is not
locked. If PLACE is already locked (non-nil), FALLBACK will be executed
instead. The lock is released after the execution of BODY, regardless of
whether BODY is successful or not. This provides a basic mutual
exclusion mechanism based on a shared place.

Arguments:
- PLACE: A place (e.g., a symbol or generalized variable) that acts as a
  lock. The value at this place should be nil when the lock is free,
  and non-nil (typically t) when the lock is held.
- FALLBACK: Code to execute if PLACE is already locked. This can be a
  single form or a list of forms, as in `concur:once-do!`.
- BODY: Code that will run while PLACE is locked.

Side Effects:
- Sets PLACE to `t` temporarily during the execution of BODY.
- Releases the lock on PLACE after executing BODY, even if errors occur.
- Signals an error if PLACE is not a valid `setf`-able place.

Example:
  (let ((my-lock nil))
    (concur:with-lock! my-lock
      (:else (message \"Lock was held by someone else\"))
      (message \"Lock acquired\")
      (message \"Doing something critical\")))"
  (declare (indent 2))
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     (list fallback))))
    `(if ,place
         (progn ,@else-body)
       (progn
         (setf ,place t)
         (unwind-protect
             (progn ,@body)
           (setf ,place nil))))))

;;;###autoload
(defun concur:make-lock (&optional name)
  "Create a new lock object (mutex).
Optional NAME is used for debugging/logging purposes.
Returns a plist representing the lock, initialized to unlocked."
  (list :locked nil
        :owner nil
        :name (or name (format "lock-%s" (gensym)))))

;;;###autoload
(defun concur:lock-acquire (lock task)
  "Try to acquire LOCK for TASK. Non-blocking.
LOCK must be a plist representing the lock, created by `concur:make-lock`.
TASK is an identifier for the entity attempting to acquire the lock.
Returns t if acquired, nil otherwise. Modifies the LOCK plist in place."
  (interactive (error "Not interactive"))
  (unless (plist-get lock :locked)
    (setf (plist-get lock :locked) t)
    (setf (plist-get lock :owner) task)
    t))

;;;###autoload
(defun concur:lock-release (lock task)
  "Release LOCK if TASK is the owner.
LOCK must be a plist representing the lock.
TASK is the identifier of the entity attempting to release the lock.
Modifies the LOCK plist in place.
Raises an error if the lock is not held by TASK, or if it's not locked."
  (interactive (error "Not interactive"))
  (unless (plist-get lock :locked)
    (error "concur:lock-release: Lock %S is not currently held." (plist-get lock :name)))
  (unless (eq (plist-get lock :owner) task)
    (error "concur:lock-release: task %S does not own lock %S (current owner: %S)"
           task (plist-get lock :name) (plist-get lock :owner)))
  (setf (plist-get lock :locked) nil)
  (setf (plist-get lock :owner) nil))

;;;###autoload
(defmacro concur:with-mutex! (lock-obj fallback &rest body)
  "Acquire LOCK-OBJ temporarily during the execution of BODY.
LOCK-OBJ must be a lock object (plist) created by `concur:make-lock`.
If the lock cannot be acquired (already held), FALLBACK is executed.
The lock is guaranteed to be released after BODY completes.

Arguments:
- LOCK-OBJ: A lock object created by `concur:make-lock`.
- FALLBACK: Code to execute if the lock cannot be acquired.
- BODY: Code to run while the lock is held.

Example:
  (let ((my-mutex (concur:make-lock \"my-critical-section-lock\")))
    (concur:with-mutex! my-mutex
      (:else (message \"Mutex was busy!\"))
      (message \"Mutex acquired, doing critical work...\")
      ;; ... critical work ...
      (message \"Critical work done.\")))"
  (declare (indent 2))
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     (list fallback)))
        (task-id (gensym "task-id-"))) ; Unique ID for this execution context
    `(let ((,task-id (current-time-string))) ; Use current-time-string as a simple unique ID
       (if (concur:lock-acquire ,lock-obj ,task-id)
           (unwind-protect
               (progn ,@body)
             (concur:lock-release ,lock-obj ,task-id))
         (progn ,@else-body)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Blocking Primitives                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(cl-defun concur:block-until (test success-callback &key timeout interval meta error-function 
                                                         timeout-callback (start-time (float-time)) (step 0))
  "Block cooperatively until TEST returns non-nil.
When the condition is met, SUCCESS-CALLBACK is called.
If a timeout occurs, TIMEOUT-CALLBACK (if provided) or ERROR-FUNCTION (if provided) is called.

This function cooperatively waits for a condition to become true. It does not
block Emacs. Instead, it schedules itself to re-check the condition after a
short `interval`.

Arguments:
- TEST (function): A zero-argument function that returns non-nil when the condition is met.
- SUCCESS-CALLBACK (function): A zero-argument function to call when TEST returns non-nil.
- :timeout SECONDS (float, optional): Maximum time to wait in seconds.
- :interval SECONDS (float, optional): Minimum time in seconds between re-check attempts. Defaults to 0.1.
- :meta METADATA (any, optional): Arbitrary metadata for logging or tracking.
- :error-function (function, optional): A function `(lambda (meta))` to call if a timeout occurs
  and `timeout-callback` is not provided.
- :timeout-callback (function, optional): A zero-argument function to call if a timeout occurs.
  Takes precedence over `:error-function`.
- :start-time (float, internal): Do not set manually. Timestamp when blocking started.
- :step (integer, internal): Do not set manually. Counter for re-check attempts.
"
  (let* ((current-time (float-time))
         (context-name (or (plist-get meta :semaphore) 
                           (plist-get meta :context) 
                           "unknown-context"))) ; For logging context

    (log! :debug "concur:block-until: Checking condition for %S (step: %d)" context-name step)

    (if (funcall test)
        (progn
          (log! :debug "concur:block-until: Condition met for %S. Calling success-callback." context-name)
          (funcall success-callback))
      (if (and timeout (> (- current-time start-time) timeout))
          (progn
            (log! :warn "concur:block-until: Timeout while waiting for %S: %S" context-name meta)
            (if timeout-callback
                (funcall timeout-callback)
              (if error-function
                  (funcall error-function meta)
                (log! :error "concur:block-until: Timeout for %S, but no timeout-callback or error-function provided." context-name)
                (error 'concur:timeout-error (format "Timeout waiting for condition: %S" context-name)))))
        ;; Condition not met and no timeout, so re-queue
        (let ((next-step (1+ step)))
          (run-with-timer (or interval 0.1) nil
                          (lambda ()
                            (concur:block-until test success-callback
                                                :timeout timeout :interval interval :meta meta
                                                :error-function error-function :timeout-callback timeout-callback
                                                :start-time start-time :step next-step))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Semaphore Primitives                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (concur-semaphore
               (:constructor concur--semaphore-create-internal ; Renamed internal constructor
                             (&key count queue lock data max-count name)))
  "A semaphore object for controlling concurrent access.
Fields:
- COUNT: Current available slots.
- QUEUE: List of tasks waiting for a slot.
- LOCK: A lock object (created by `concur:make-lock`) to protect semaphore state.
- DATA: Arbitrary metadata (plist).
- MAX-COUNT: Initial/maximum number of slots.
- NAME: Optional human-readable name for the semaphore."
  count
  queue
  lock
  data
  max-count
  name)

(defun concur-semaphore--get-name (sem)
  "Internal helper to get a display name for SEM."
  (or (concur-semaphore-name sem)
      (format "sem-%s" (gensym))))

;;;###autoload
(defun concur:make-semaphore (n &optional name)
  "Create a semaphore with N available slots.
N must be a non-negative integer.
NAME is an optional descriptive name for debugging."
  (unless (and (integerp n) (>= n 0))
    (error "Semaphore slot count must be a non-negative integer: %S" n))
  (concur--semaphore-create-internal ; Use renamed internal constructor
   :count n
   :queue '()
   :lock (concur:make-lock (format "sem-lock-%s" (or name (gensym))))
   :data nil
   :max-count n
   :name (or name (format "sem-%s" (gensym)))))

;;;###autoload
(defvar concur-current-task nil
  "Dynamic variable holding the current cooperative task identifier.
This variable is typically bound by a cooperative scheduler to identify
the currently executing task, allowing primitives like semaphores to
track which task owns a resource or is waiting.")

;;;###autoload
(defun concur:semaphore-acquire (sem task success-callback &key timeout meta timeout-callback)
  "Acquire SEM for TASK, or block cooperatively until available.
Calls SUCCESS-CALLBACK when acquired.
If TIMEOUT occurs, calls TIMEOUT-CALLBACK or signals `concur:timeout-error`.
META is for logging/tracking. TASK is used for queueing."
  (unless (concur-semaphore-p sem)
    (error "concur:semaphore-acquire: SEM argument is not a semaphore: %S" sem))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :debug "Semaphore acquire: %s (task: %S, timeout: %s)"
                  sem-name task timeout)

    (concur:with-mutex! (concur-semaphore-lock sem)
        (:else
         (log! :error "Semaphore %s internal lock contention during acquire. This should be rare. Retrying acquire." sem-name)
         (run-at-time 0.01 nil 
                      (lambda () (concur:semaphore-acquire sem task success-callback
                                                           :timeout timeout :meta meta
                                                           :timeout-callback timeout-callback))))
      (if (> (concur-semaphore-count sem) 0)
          (progn
            (cl-decf (concur-semaphore-count sem))
            (log! :debug "Semaphore %s acquired immediately (count: %d)"
                          sem-name (concur-semaphore-count sem))
            (funcall success-callback))
        (progn
          (unless (member task (concur-semaphore-queue sem))
            (setf (concur-semaphore-queue sem) (nconc (concur-semaphore-queue sem) (list task)))
            (log! :debug "Task %S queued for semaphore: %s (queue len: %d)"
                          task sem-name (length (concur-semaphore-queue sem))))

          (let* ((block-meta (or meta (list :semaphore sem-name :task task)))
                 (block-success-cb
                  (lambda ()
                    (concur:with-mutex! (concur-semaphore-lock sem)
                        (:else (log! :error "Semaphore %s lock contention after block for task %S. Retrying." sem-name task)
                               (run-at-time 0.01 nil (lambda () 
                                                       (concur:semaphore-acquire 
                                                         sem 
                                                         task 
                                                         success-callback 
                                                         :timeout timeout 
                                                         :meta meta 
                                                         :timeout-callback timeout-callback))))
                      (if (> (concur-semaphore-count sem) 0)
                          (progn
                            (cl-decf (concur-semaphore-count sem))
                            (log! :debug "Semaphore %s acquired by task %S after blocking (count: %d)"
                                          sem-name task (concur-semaphore-count sem))
                            (funcall success-callback))
                        (error "Semaphore %s slot unavailable post-block for %S" sem-name task)
                        ))))
                  (block-timeout-cb
                   (lambda ()
                     (log! :warn "Timeout acquiring semaphore: %s for task %S" sem-name task)
                     (concur:with-mutex! (concur-semaphore-lock sem)
                         (:else (log! :error "Semaphore %s lock contention on timeout for task %S." sem-name task))
                       (setf (concur-semaphore-queue sem) (delete task (concur-semaphore-queue sem))))
                     (if timeout-callback (funcall timeout-callback)
                       (error 'concur:timeout-error
                             (format "Timeout acquiring semaphore %s for task %S" sem-name task))))))
            (concur:block-until
             (lambda () (> (concur-semaphore-count sem) 0))
             block-success-cb
             :timeout timeout
             :interval 0.1
             :meta block-meta
             :timeout-callback block-timeout-cb)))))))

;;;###autoload
(defun concur:semaphore-try-acquire (sem task)
  "Try to acquire SEM for TASK without blocking.
Returns t if acquired, nil otherwise."
  (unless (concur-semaphore-p sem)
    (error "concur:semaphore-try-acquire: SEM argument is not a semaphore: %S" sem))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :debug "Semaphore try-acquire: %s (task: %S)" sem-name task)
    (concur:with-mutex! (concur-semaphore-lock sem)
        (:else
         (log! :warn "Semaphore %s internal lock is held. Cannot try-acquire." sem-name)
         nil) 
      (if (> (concur-semaphore-count sem) 0)
          (progn
            (cl-decf (concur-semaphore-count sem))
            (log! :debug "Semaphore try-acquire successful: %s (count: %d)"
                          sem-name (concur-semaphore-count sem))
            t)
        (progn
          (log! :debug "Semaphore try-acquire failed: %s (count: %d)"
                        sem-name (concur-semaphore-count sem))
          nil)))))

;;;###autoload
(defun concur:semaphore-release (sem wake-fn)
  "Release SEM, waking one task from the queue if present using WAKE-FN.
WAKE-FN is `(lambda (task))` called for the woken task.
Returns the task that was woken up, or nil if no task was woken."
  (unless (concur-semaphore-p sem)
    (error "concur:semaphore-release: SEM argument is not a semaphore: %S" sem))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :debug "Semaphore release: %s" sem-name)
    (concur:with-mutex! (concur-semaphore-lock sem)
        (:else (error "Semaphore lock is held during release of %S" sem-name))
      (cl-incf (concur-semaphore-count sem))
      (log! :debug "Semaphore released: %s (count: %d)"
                    sem-name (concur-semaphore-count sem))
      (when (and (concur-semaphore-max-count sem)
                 (> (concur-semaphore-count sem) (concur-semaphore-max-count sem)))
        (log! :warn "Semaphore count (%d) exceeds max-count (%d) for %S after release. Adjusting."
              (concur-semaphore-count sem) (concur-semaphore-max-count sem) sem-name)
        (setf (concur-semaphore-count sem) (concur-semaphore-max-count sem)))
      
      (let ((queue (concur-semaphore-queue sem)))
        (if (null queue)
            nil 
          (let ((next-task (car queue)))
            (setf (concur-semaphore-queue sem) (cdr queue))
            (log! :debug "Waking up task %S for semaphore: %s"
                          next-task sem-name)
            (funcall wake-fn next-task)
            next-task))))))

;;;###autoload
(defun concur:semaphore-reset (sem new-count)
  "Reset SEM to NEW-COUNT and clear its queue.
NEW-COUNT becomes the new max-count."
  (unless (concur-semaphore-p sem)
    (error "concur:semaphore-reset: SEM argument is not a semaphore: %S" sem))
  (unless (and (integerp new-count) (>= new-count 0))
    (error "Slot count must be a non-negative integer: %S" new-count))
  (let ((sem-name (concur-semaphore--get-name sem)))
    (log! :info "Resetting semaphore %s to %d" sem-name new-count)
    (concur:with-mutex! (concur-semaphore-lock sem)
        (:else (error "Semaphore lock is held during reset of %S" sem-name))
      (setf (concur-semaphore-count sem) new-count)
      (setf (concur-semaphore-queue sem) '())
      (setf (concur-semaphore-max-count sem) new-count)))
  sem)

;;;###autoload
(defun concur:semaphore-describe (sem)
  "Return a plist describing the state of SEM."
  (unless (concur-semaphore-p sem)
    (error "concur:semaphore-describe: SEM argument is not a semaphore: %S" sem))
  (let ((name (concur-semaphore--get-name sem)))
    (log! :debug "Describing semaphore: %s" name)
    `(:name ,name
      :count ,(concur-semaphore-count sem)
      :waiting ,(length (concur-semaphore-queue sem))
      :data ,(concur-semaphore-data sem)
      :max-count ,(concur-semaphore-max-count sem))))

;;;###autoload
(defmacro concur:with-semaphore! (sem wake-fn &rest body)
  "Run BODY in a cooperative critical section guarded by SEM.
Acquires SEM for `concur-current-task` (or a generated ID), runs BODY,
then releases SEM using WAKE-FN.
If semaphore cannot be acquired immediately (due to internal mutex contention
on the semaphore itself, not because it's full), the :else clause is run.
This macro relies on `concur:semaphore-acquire` which handles queuing and
cooperative blocking if the semaphore is full.

Arguments:
- sem:     A symbol that, at *run time*, will be bound to the
           semaphore to acquire.
- wake-fn: The function (symbol or lambda) to invoke to wake up a waiting task
           when the semaphore is released by this macro. This function is
           called by `concur:semaphore-release` with the woken task as its argument.
- body:    The body of code to execute while holding the semaphore.
           This should be a list of forms.

Keyword support:
  :else FORMS...   — If the semaphore's internal lock is busy during the
                    initial acquire attempt (rare), run these forms.

Returns:
  - The result of the last form in BODY if the semaphore was acquired and
    BODY executed successfully. Otherwise, the result of the :else clause
    or nil if no :else clause and lock was busy.
    Note: The actual execution of BODY is within a callback to
    `concur:semaphore-acquire`. This macro sets up that asynchronous acquisition.
    The macro itself will return nil because `concur:semaphore-acquire` is async.
"
  (declare (indent defun))
  (unless (symbolp sem)
    (error "sem argument to concur:with-semaphore! must be a symbol: %S" sem))
  (unless (or (symbolp wake-fn) (and (consp wake-fn) (eq (car wake-fn) 'lambda)))
    (error "wake-fn argument to concur:with-semaphore! must be a symbol or a lambda: %S" wake-fn))

  (let* ((else-clause-forms (cdr (assoc :else body))) 
         (body-forms (if else-clause-forms (cl-delete :else body :key #'car) body)) 
         (task-var (gensym "task-"))
         (sem-name-var (gensym "sem-name-"))
         (acquired-var (gensym "acquired-")))
    `(let ((,task-var (or concur-current-task (current-time-string)))
           (,sem-name-var (concur-semaphore--get-name ,sem))
           (,acquired-var nil)) 
       (if (concur-semaphore-p ,sem)
           (progn
             (log! :debug "concur:with-semaphore!: Attempting acquire for semaphore %S (task: %S)."
                           ,sem-name-var ,task-var)
             (concur:semaphore-acquire
              ,sem ,task-var
              (lambda ()
                (setq ,acquired-var t)
                (unwind-protect
                    (progn
                      (log! :debug "concur:with-semaphore!: Acquired semaphore %S. Running body."
                                    ,sem-name-var)
                      ,@body-forms)
                  (log! :debug "concur:with-semaphore!: Releasing semaphore %S from task %S."
                                ,sem-name-var ,task-var)
                  (concur:semaphore-release ,sem ,wake-fn)))
              :timeout-callback (lambda ()
                                  (log! :warn "concur:with-semaphore!: Timeout acquiring semaphore %S for task %S. Else clause will run."
                                                ,sem-name-var ,task-var)
                                  ,@else-clause-forms)))
         (error "sem argument to concur:with-semaphore! was not a semaphore at run time: %S" ,sem))
       nil)))

(provide 'concur-primitives)
;;; concur-primitives.el ends here