;;; concur-primitives.el --- Concur lock macros and semaphore primitives for concurrent task management -*- lexical-binding: t; -*-
;;
;; Commentary:

;; Provides lock-related macros to manage concurrency and synchronization
;; in Emacs, including:
;;
;; - `concur-once-do!`: Ensures a block of code is executed only once,
;;   based on the state of a flag.
;; - `concur-once-callback!`: Executes a callback only once, and uses
;;   fallback if a flag is set.
;; - `concur-with-lock!`: Acquires a lock temporarily and executes a body
;;   of code, releasing the lock afterward.
;; - `concur-with-mutex!`: A more flexible lock, which can persist across
;;   multiple executions if specified.
;;
;; These macros help ensure safe concurrent execution by preventing race
;; conditions, and by allowing persistent and temporary locking mechanisms.
;;
;; This file also provides semaphore primitives for managing concurrent task execution
;; in the concur scheduling system. A semaphore is used to control access to a 
;; shared resource, ensuring that a limited number of tasks can access the resource 
;; concurrently. The semaphore supports acquiring and releasing operations, as well 
;; as tracking the tasks that are waiting for access to the resource.
;;
;; Features:
;; - Semaphore creation and management
;; - Task synchronization using semaphores
;; - Support for cancel tokens, allowing tasks to be canceled while waiting for a semaphore
;; - Mechanisms to track waiting tasks and resource availability
;;
;; Usage:
;; The semaphore can be used to control concurrent access to shared resources by
;; creating a semaphore instance and associating tasks with it. Tasks will wait for
;; the semaphore to become available, and can be canceled if necessary. Semaphore 
;; management is tightly integrated with the concur scheduler system.
;;
;;; Code:

(require 'cl-lib)
(require 'dash)

;;; Atomicity / Locking Macros

;;;###autoload
(defmacro concur-once-do! (place fallback &rest body)
  "Run BODY once if PLACE is nil. Otherwise, run FALLBACK.

This macro ensures that a block of code is executed only once based on the
state of PLACE. If PLACE is nil, BODY is executed, and PLACE is set to `t`.
If PLACE is non-nil, FALLBACK is executed instead. FALLBACK can be either
a value or a list of forms to be evaluated.

Arguments:
- PLACE: A variable or place (could be a symbol or a generalized variable) 
  that determines whether the body of code should be executed.
- FALLBACK: The code to run if PLACE is non-nil. Can either be a value or
  a list of forms (e.g., `(:else FORM...)`).
- BODY: The code to run once if PLACE is nil.

Side Effects:
- Sets PLACE to `t` after executing BODY.
- If PLACE is non-nil, executes FALLBACK instead of BODY.

Example:
  (concur-once-do! my-flag
    (:else (message \"Already run!\")) 
    (message \"Running for the first time\"))"
  (declare (indent 2))
  (let ((else-body (if (and (consp fallback) (eq (car fallback) :else))
                       (cdr fallback)
                     `(,fallback))))
    `(if ,place
         (progn ,@else-body)
       (progn
         ,(if (symbolp place)
              `(setf ,place t)
            `(gv-letplace (getter setter) ,place
               (funcall setter t)))
         ,@body))))

;;;###autoload
(defmacro concur-once-callback! (flag callback &rest fallback)
  "Invoke CALLBACK once if FLAG is nil. Otherwise, run FALLBACK."
  `(concur-once-do! ,flag
     (:else ,@fallback)
     (when ,callback
       (funcall ,callback))))

;;;###autoload       
(defmacro concur-with-lock! (place fallback &rest body)
  "Acquire a lock on PLACE temporarily during the execution of BODY.

This macro ensures that the code in BODY will only execute if PLACE is not
locked. If PLACE is already locked (non-nil), FALLBACK will be executed instead.
The lock is released after the execution of BODY, regardless of whether BODY
is successful or not.

Arguments:
- PLACE: A place (e.g., a symbol or generalized variable) that acts as a lock.
- FALLBACK: Code to execute if PLACE is already locked (can be a value or
  `(:else FORMS...)`).
- BODY: Code that will run while PLACE is locked.

Side Effects:
- Modifies PLACE to `t` temporarily during the execution of BODY.
- Releases the lock on PLACE after executing BODY.

Example:
  (concur-with-lock! my-lock (:else (message \"Already locked!\")) (do-something))"
  (declare (indent 2))
  (let ((lock-held (gensym "lock-held")))
    `(if ,place
         ,(if (and (consp fallback) (eq (car fallback) :else))
              `(progn ,@(cdr fallback))
            fallback)
       (let ((,lock-held t))
         ,(if (symbolp place)
              `(setf ,place ,lock-held)
            `(gv-letplace (getter setter) ,place
               (funcall setter ,lock-held)))
         (unwind-protect
             (progn ,@body)
           ,(if (symbolp place)
                `(setf ,place nil)
              `(gv-letplace (getter setter) ,place
                 (funcall setter nil))))))))

;;;###autoload
(defmacro concur-with-mutex! (place fallback &rest body)
  "Generic lock macro with optional permanent form.
Acquire a lock on PLACE, and ensure that the lock persists across runs if 
needed.

PLACE may be of the form `(:permanent SYM)` to create a lock that persists
across multiple executions. If not permanent, the lock will only be held
during the execution of BODY. 

Arguments:
- PLACE: The place acting as a lock, which can be `(:permanent SYM)` to 
  indicate persistence or a symbol representing a simple lock.
- FALLBACK: Code to run if the lock cannot be acquired (can be a value or
  `(:else FORMS...)`).
- BODY: Code that will run while the lock is held.

Side Effects:
- Modifies PLACE to `t` temporarily during the execution of BODY.
- If PLACE is permanent, the lock persists across runs.
- Releases the lock on PLACE after executing BODY.

Example:
  (concur-with-mutex! my-mutex (:permanent my-lock) (do-something))"
  (declare (indent 2))
  (let ((real-place (gensym "real-place"))
        (permanent (gensym "permanent")))
    `(let* ((,permanent (and (consp ,place) (eq (car ,place) :permanent)))
            (,real-place (if ,permanent (cadr ,place) ,place)))
       (if ,real-place
           ,(if (and (consp fallback) (eq (car fallback) :else))
                `(progn ,@(cdr fallback))
              fallback)
         (concur-with-lock! ,real-place
           (:else nil)
           ;; Set lock explicitly (already done by concur-with-lock!)
           ,@body)))))

;;; Cooperative Multitasking Primitives

(defun concur-block-until (test enqueue &rest options)
  "Block cooperatively until TEST returns non-nil, using ENQUEUE to requeue if not.
OPTIONS is a plist supporting:
  - :timeout SECONDS   – max time to wait before giving up
  - :interval SECONDS  – min time between requeue attempts
  - :meta METADATA     – metadata for logging or tracking
  - :step              – controls whether to step through the task

Returns t if TEST eventually returns non-nil, or nil if timeout occurs."
  (let* ((start-time (float-time))
         (timeout (plist-get options :timeout))
         (interval (plist-get options :interval))
         (meta (plist-get options :meta))
         (step (plist-get options :step)))
    (cl-labels ((should-timeout ()
                  (and timeout
                       (> (- (float-time) start-time) timeout))))
      (catch 'concur-yield
        (while (not (funcall test))
          (when (should-timeout)
            (when meta
              (concur--log! "Timeout while waiting: %S" meta))
            (cl-return-from concur-block-until nil))

          ;; Clamp the interval to avoid scheduling immediate timers
          (when (and interval (> interval 0))
            (run-with-timer (max 0.01 interval) nil enqueue))

          ;; Requeue and yield
          (funcall enqueue)
          (when step
            (setq step (1+ step))) ;; optional step counter tracking
          (throw 'concur-yield nil)))
      t)))

;;;###autoload
(defmacro concur-yield! ()
  "Yield cooperatively to the asynchronous scheduler.
  
If the task is in stepping mode (i.e., executing one form at a time), 
this causes the task to yield after one step. Otherwise, it uses `throw`
to pause execution entirely and reschedule. This is useful in tasks
that involve multiple steps (e.g., loops or async workflows), enabling
resumption from the last yielded position."
  `(throw 'concur-yield t))

;;; Semaphore Primitives

(cl-defstruct (concur-semaphore
            (:constructor nil) ; disable default constructor
            (:constructor make-concur-semaphore (&key count queue lock data)))
  "A semaphore to limit concurrent access to shared resources.

Fields:
  - count: The number of available slots or resources. When `count` is greater than 0, 
      tasks can proceed.
  - queue: A queue of tasks waiting for access to the semaphore. These are tasks that are 
      blocked because there are no available resources.
  - lock: A mutex or lock used to protect the semaphore's state and prevent race conditions.
  - data: Arbitrary user-defined metadata that can be associated with the semaphore. This allows
      the user to store additional context (opaque data) relevant to the semaphore's usage."
  count
  queue
  lock
  data)

;;;###autoload
(defun concur-semaphore-create (n)
  "Create a semaphore with N available slots.

A semaphore is used to limit access to a particular resource or critical
section by multiple tasks. The semaphore is initialized with N available
slots, which can be acquired or released by tasks.

Arguments:
  - N: The number of slots available in the semaphore. Tasks can acquire
    these slots to access the resource.

Returns:
  - A semaphore object, represented as a struct with a `:count` field for
    the number of available slots and a `:queue` for tasks waiting to acquire
    the semaphore."
  (make-concur-semaphore :count n :queue '()))

;;;###autoload
(defun concur-semaphore-acquire (sem task)
  "Acquire SEM for TASK, or requeue it if unavailable.

This function attempts to acquire a slot from the semaphore. If the semaphore
has available slots, it decrements the slot count and allows the task to proceed.
If no slots are available, the task is added to the semaphore's queue and will
be retried when a slot becomes available.

Arguments:
  - sem: The semaphore to acquire.
  - task: The task to be queued if the semaphore is unavailable.

Returns:
  - Nothing, but logs the state of the semaphore."
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    ;; Block until there is an available slot in the semaphore
    (concur-block-until
     ;; Test for available slot
     (lambda () (> (concur-semaphore-count sem) 0))  
     (lambda () 
       ;; Requeue the task if the semaphore is unavailable
       (concur--log! "Task queued for semaphore: %s" (concur--semaphore-name sem))
       (setf (concur-semaphore-queue sem)
          (append (concur-semaphore-queue sem) (list task)))))  ;; FIFO Queue

    ;; Decrement available slots in semaphore
    (cl-decf (concur-semaphore-count sem))
    (concur--log! "Semaphore acquired: %s" sem)))

;;;###autoload
(defun concur-semaphore-try-acquire (sem task)
  "Try to acquire SEM for TASK without blocking.

This function attempts to acquire a slot from the semaphore, but does not block.
If the semaphore has available slots, the task acquires the slot and the function
returns `t`. Otherwise, it returns `nil` without modifying the semaphore or queue.

Arguments:
  - sem: The semaphore to try to acquire.
  - task: The task attempting to acquire the semaphore.

Returns:
  - t if the semaphore was successfully acquired, nil otherwise."
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    ;; Attempt non-blocking acquire
    (when (> (concur-semaphore-count sem) 0)
      (cl-decf (concur-semaphore-count sem))
      (concur--log! "Semaphore try-acquire successful: %s" sem)
      t)))

;;;###autoload
(defun concur-semaphore-release (sem wake-fn)
  "Release SEM, waking one task from the queue if present.

When a task releases the semaphore, it increments the available slot count.
If there are tasks waiting in the queue, one of them is woken up and allowed
to acquire the semaphore.

Arguments:
  - sem: The semaphore to release.
  - wake-fn: The function to wake up the next task in the queue.
Returns:
  - Nothing, but logs the state of the semaphore and the task being woken up."
  (concur-with-mutex! (concur-semaphore-lock sem)
    (:else nil)
    
    ;; Increment the available slots in the semaphore
    (cl-incf (concur-semaphore-count sem))
    (concur--log! "Semaphore released: %s" (concur--semaphore-name sem))

    ;; Wake up the next entry in the queue, if any
    (when-let ((next (car (concur-semaphore-queue sem))))
      (setf (concur-semaphore-queue sem)
            (cdr (concur-semaphore-queue sem)))
      (concur--log! "Waking up task for semaphore: %s" (concur--semaphore-name sem))
      (funcall wake-fn next))))

;;;###autoload
(defun concur-semaphore-reset (sem new-count)
  "Reset SEM to NEW-COUNT and clear its queue.

This function resets the semaphore to the specified number of available slots
and clears any tasks that are currently waiting in the queue.

Arguments:
  - sem: The semaphore to reset.
  - new-count: The new number of available slots in the semaphore.

Returns:
  - Nothing, but the semaphore's count and queue are reset."
  (setf (concur-semaphore-count sem) new-count)
  (setf (concur-semaphore-queue sem) '()))

;;;###autoload
(defun concur-semaphore-describe (sem)
  "Return a plist describing the state of SEM.

This function provides an overview of the semaphore's state, including the
number of available slots, the number of waiting tasks, and any additional data
associated with the semaphore.

Arguments:
  - sem: The semaphore to describe.

Returns:
  - A plist containing the semaphore's name, available slot count, the number
    of tasks waiting, and any additional data associated with the semaphore."
  `(:name ,(concur--semaphore-name sem)
    :count ,(concur-semaphore-count sem)
    :waiting ,(length (concur-semaphore-queue sem))
    :data ,(concur-semaphore-data sem)))

(defun concur--semaphore-name (sem)
  "Return a human-readable name for SEM based on its data field.

This function returns a name for the semaphore, either from the `:name` field
in the semaphore's data or a generated name if no name is provided.

Arguments:
  - sem: The semaphore whose name is being requested.

Returns:
  - A string representing the semaphore's name."
  (let ((data (concur-semaphore-data sem)))
    (or (plist-get data :name)
        ;; Fallback identifier if no name is provided
        (symbol-name (gensym "sem")))))  

;;;;###autoload
(defmacro concur-with-semaphore! (sem wake-fn &rest body)
  "Run BODY in a cooperative critical section guarded by SEM.

This macro attempts to acquire the semaphore SEM before executing BODY. If
the semaphore is unavailable, it either blocks until it can be acquired or
runs an alternative set of forms (if :else is provided).

Arguments:
  - sem: The semaphore to acquire.
  - wake-fn: The function to invoke once the semaphore is released.
  - body: The body of code to execute while holding the semaphore.

Keyword support:
  :else FORMS...   — If the semaphore is unavailable, run these forms instead of blocking.

Returns:
  - Nothing. If the semaphore is successfully acquired, BODY is executed
    in a critical section. If not, fallback forms are executed if :else is provided."
  (declare (indent defun))
  (-let* (((keys body-forms) (--split-with (lambda (x) (keywordp x)) body))
          (&plist :else else) keys
          (acquired (gensym "acquired")))
    `(let ((,acquired nil))
       (unwind-protect
           (progn
             ;; Attempt non-blocking acquire if :else is present
             (if ,(if else t nil)
                 (setq ,acquired (concur-semaphore-try-acquire ,sem nil))
               (progn
                 (concur-semaphore-acquire ,sem nil)
                 (setq ,acquired t)))

             (if ,acquired
                 (progn
                   ,@body-forms)
               ,@(when else
                   `((progn ,@else)))))
         (when ,acquired
           (concur-semaphore-release ,sem ,wake-fn))))))

(provide 'concur-primitives)
;;; concur-primitives.el ends here