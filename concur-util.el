;;; concur-util.el --- Utility variables and functions  -*- lexical-binding: t; -*-
(require 'scribe)

(defvar concur--debug t
  "Whether to enable debug logging for concur.")

(defmacro concur--log! (fmt &rest args)
  "Log FMT and ARGS when `concur--debug` is non-nil.

If the macro `log!` from the `scribe` package is available, it is used;
otherwise fallback to `message` prefixed with [concur]."
  (if (macrop 'log!)  ;; <- This must happen at macro-expansion time
      `(when concur--debug
         (log! ,fmt ,@args))  ;; expand log! directly
    `(when concur--debug
       (message (concat "[concur] " ,fmt) ,@args))))

(provide 'concur-util)
;;; concur-util.el ends here

(cl-defstruct (concur-task (:constructor make-concur-task))
  semaphore
  cancel-token
  future
  schedule ;; One of 'immediate, 'async, or 'event-loop
  meta
  name
  created-at)

(defun concur-scheduler-run ()
  "Run the next task in the async queue, or stop if the queue is empty."
  (if (ring-empty-p concur--task-queue)
      (concur-scheduler-stop)
    (let ((task (ring-remove concur--task-queue))
          (future (concur-task-future task))
          (promise (concur-future-promise future))
          (task-fn (concur-future-fn future))  ;; Get the function from the future
          (schedule (concur-task-schedule task)))

      (let ((concur--inside-scheduler t))
        (condition-case err
            (cond
             ;; If schedule is true, defer the task using `run-at-time`
             ((eq schedule t)
              (run-at-time 0 nil
                           (lambda ()
                             (funcall task-fn)
                             (concur-promise-resolve promise result))))

             ;; If schedule is false or nil, run the task immediately
             ((eq schedule nil)
              (funcall task-fn)
              (concur-promise-resolve promise result))

             ;; Handle asynchronous scheduling
             ((eq schedule 'async)
              (async-start
               (lambda () (funcall task-fn))
               (lambda (result)
                 (concur-promise-resolve promise result))))

             ;; Handle deferred scheduling (runs after the current event loop)
             ((eq schedule 'deferred)
              (run-at-time
               0 nil ;; Run after the current event loop
               (lambda ()
                 (funcall task-fn)
                 (concur-promise-resolve promise result))))

             ;; Error for unknown :schedule values
             (t
              (error "Unknown :schedule value %S" schedule)))

          (error
           ;; Handle task errors
           (concur-promise-reject promise err)
           (run-hook-with-args 'concur-scheduler-error-hook err)
           (concur--log! "Task error: %S" err)))))))

;;;###autoload
(defun concur-scheduler-queue-task (task)
  "Queue TASK into the asynchronous scheduler. If the queue is full, the oldest task will be dropped.

This function adds a new task (a function) to the promise scheduler task queue.
If the queue is at its capacity, it will discard the oldest task in favor of the new one.
The promise scheduler is started if it is not already running.

Arguments:
- TASK: A function to be scheduled for execution in the promise scheduler.

Side Effects:
- Adds the task to the task queue.
- Starts the promise scheduler if it is not already running.

Precondition:
- The TASK argument must be a valid task object of type `concur-task`."
  (cl-assert (concur-task-p task))  ;; Ensure TASK is a concur-task object
  
  ;; Add the task to the ring buffer (queue) for future processing
  (if (= (ring-length concur--task-queue) (ring-size concur--task-queue))
      ;; If the ring is full, remove the oldest task
      (ring-remove concur--task-queue)  
    ;; Insert the new task at the end of the ring
    (ring-insert concur--task-queue task))

  ;; Ensure the scheduler starts if it's not already running
  (concur-scheduler-start))

;;; Cancel Token

;;;###autoload
(defun concur-cancel-token-create ()
  "Create and return a new cancel token.
This function creates a new cancel token and marks it as active by default.

Returns:
  A cancel token struct, initialized with an `:active` field set to t."
  (make-concur-cancel-token :active t))

;;;###autoload
(defun concur-cancel-token-cancel (token)
  "Cancel the given TOKEN, marking it as inactive.
This function sets the cancel token's `:active` field to nil to indicate the task
associated with this token should be canceled.

Arguments:
  - token: The cancel token to cancel. Should be a valid cancel token object.
  
Side Effects:
  - Sets the `:active` field of the token to nil, marking it as canceled.
  
Error Handling:
  - Signals an error if the token is not a valid cancel token."
  (if (not (concur-cancel-token-active-p token))
      (error "The token is either nil or already canceled. Cannot cancel again."))
  (setf (concur-cancel-token-active token) nil)
  (concur--log! "Cancel token %s: Marked as canceled" (concur-cancel-token-name token)))

;;;###autoload
(defun concur-cancel-token-active-p (token)
  "Check if the cancel TOKEN is still active (i.e., not canceled).
This function checks the `:active` field of the token to determine if the task
associated with this token should still be active.

Arguments:
  - token: The cancel token to check. Should be a valid cancel token object.
  
Returns:
  - t if the token is active (not canceled).
  - nil if the token is canceled or invalid."
  (if (not token)
      (error "Invalid token: nil"))
  (concur-cancel-token-active token))

;;;###autoload
(defun concur-cancel-token-check (token)
  "Check if the task should be canceled by evaluating the cancel TOKEN.
If the token is canceled, this function logs the cancellation and returns `t` to
indicate that the task should be canceled. If the token is still active, it returns `nil`.

Arguments:
  - token: The cancel token to check.
  
Returns:
  - t if the token is canceled (task should be canceled).
  - nil if the token is active (task should continue)."
  (if (not (concur-cancel-token-active-p token))
      (progn
        (concur--log! "Task canceled due to token %s." (concur-cancel-token-name token))
        t)  ;; Return t to indicate cancellation
    nil))  ;; Return nil if the task is still active

;;; Internal Helper Functions

(defun concur--log! (message &rest args)
  "Logs a message with optional arguments."
  (apply #'message (concat "[Concur] " message) args))

(defun concur-cancel-token-name (token)
  "Return a human-readable name for the cancel TOKEN.
If the token contains a `:name` field, return that; otherwise, generate a unique name."
  (or (plist-get (concur-cancel-token-data token) :name)
      (symbol-name (gensym "cancel-token-"))))

;;; Example Usage:

;; Create a cancel token
(let ((token (concur-cancel-token-create)))
  ;; Check if the token is active
  (when (concur-cancel-token-active-p token)
    (message "Token is active, proceeding with task..."))

  ;; Cancel the token
  (concur-cancel-token-cancel token)

  ;; Check if the token is active after cancellation
  (if (concur-cancel-token-check token)
      (message "Task is canceled.")
    (message "Task is still active.")))

;;;###autoload
(defun concur-async-task (task &optional delay)
  "Run TASK (a function returning a promise or value) asynchronously.

If DELAY is non-nil, the task will be scheduled after that many seconds
using `run-at-time`. If DELAY is nil, the task is scheduled to run using
`async-start` for a truly asynchronous, non-blocking execution.

Returns a concur-promise resolving to the task result."
  (let ((promise (concur-promise-new))
        (wrapped-task (concur-future-wrap (lambda () (funcall task)))))
    (if delay
        (run-at-time (or delay 0) nil
                     (lambda () (concur-future-force wrapped-task)))  ;; Force the wrapped task after delay
      (async-start
       `(lambda () (concur-future-force ,wrapped-task))  ;; Force the wrapped task when async starts
       (lambda (result) 
         (concur-promise-resolve promise result))))
    promise))

(defmacro concur-async! (&rest args)
  "Run BODY asynchronously with optional SEMAPHORE, :schedule nil, :cancel TOKEN, and :meta METADATA."
  (declare (indent defun))
  (let* ((args* args)
         (semaphore nil)
         (schedule t)
         (cancel-token nil)
         (meta nil)
         (body nil))

    ;; Extract keyword arguments
    (while (keywordp (car (last args*)))
      (let ((kw (car (last args*)))
            (val (car (last (butlast args*)))))
        (setq args* (butlast args* 2))
        (pcase kw
          (:schedule (setq schedule val))
          (:cancel   (setq cancel-token val))
          (:meta     (setq meta val))
          (_ (error "Unknown keyword %S in concur-async!" kw)))))

    ;; Detect optional semaphore
    (if (and args* (not (keywordp (car args*))))
        (setq semaphore (car args*)
              body (cdr args*))
      (setq body args*))

    ;; Symbols
    (let ((done   (gensym "done-"))
          (result (gensym "result-"))
          (self   (gensym "self-"))
          (future (gensym "future-"))
          (promise (gensym "promise-")))

      `(let* ((,done nil)
              (,result nil))

         (cl-labels ((,self ()
                       (catch 'concur-yield
                         ;; Cancellation-aware logic
                         (when ,(if cancel-token
                                    `(concur-cancel-token-active-p ,cancel-token)
                                  t)
                           (setq ,result
                                 ,(if semaphore
                                      `(concur-with-semaphore! ,semaphore ,@body)
                                    `(progn ,@body)))
                           (setq ,done t)))))

         (let* ((,future
                 (concur-future-wrap
                  (lambda ()
                    (setq ,promise (concur-future-promise ,future))
                    (condition-case err
                        (progn
                          (,self)
                          ;; Resolve only if task completed and still active
                          (when ,done
                            (when ,(if cancel-token
                                       `(concur-cancel-token-active-p ,cancel-token)
                                     t)
                              (concur-promise-resolve ,promise ,result))))
                      (error
                       (concur-promise-reject ,promise err)
                       (concur--log! "concur-async! task error: %S" err)))))))

                (task
                 (make-concur-task
                  :future ,future
                  :promise ,promise
                  :schedule ,schedule
                  :cancel ,cancel-token
                  :meta ,meta)))

           (concur-scheduler-queue-task task)
           ,promise)))) 

(defmacro concur-await! (form)
  "Await the result of FORM, which must evaluate to a `concur-future` or `concur-promise`.

This macro blocks execution until the result of FORM is available, whether it's a `concur-future` or a `concur-promise`. The future or promise can be created either inside the scheduler or outside of it.

Behavior:
  - If called **inside the scheduler**, it yields cooperatively by re-queuing the task to the scheduler until the task is completed.
  - If called **outside the scheduler**, it uses a polling loop, periodically checking the status of the task with `sleep-for` to avoid blocking the Emacs event loop.

Arguments:
  - FORM: The expression that should evaluate to a `concur-future` or `concur-promise`.

Returns:
  - The value stored in the future or promise if successful, or signals an error if encountered.

Error Handling:
  - If the future or promise has encountered an error, it will be raised as a Lisp error using `signal`.

Example:
  (concur-await! (concur-async! (some-task)))
  ;; Wait until the asynchronous task completes, then continue execution."
  (let ((val (gensym "val"))
        (task (gensym "task"))
        (result (gensym "result")))
    `(let* ((,task ,form)
            (,val nil))
       ;; Check if FORM evaluates to a future or a promise
       (cl-assert (or (concur-future-p ,task) (concur-promise-p ,task))
                  nil "Expected a concur-future or concur-promise, but got: %S" ,task)
       
       (if (boundp 'concur--inside-scheduler)
           ;; If inside scheduler: yield cooperatively by re-queuing the task
           (cl-labels
               ((self ()
                      (unless (or (concur-future-done-p ,task)
                                  (concur-promise-done-p ,task))
                        (concur-scheduler-queue-task #'self))))
             ;; Block until the future or promise is done, using cooperative scheduling
             (concur-block-until
              (lambda () (or (concur-future-done-p ,task) (concur-promise-done-p ,task)))
              #'self))
         
         ;; If outside scheduler: use polling loop with sleep to avoid blocking
         (while (not (or (concur-future-done-p ,task) (concur-promise-done-p ,task)))
           (sleep-for concur-await-poll-interval)))

       ;; Handle the result depending on whether it's a future or a promise
       (if (concur-future-error-p ,task)
           (signal (car (concur-future-error ,task))
                   (cdr (concur-future-error ,task)))
         
         ;; If it's a promise, resolve it using `concur-promise-value`
         (if (concur-promise-p ,task)
             (setq ,val (concur-promise-value ,task))
           ;; Otherwise, resolve the future
           (setq ,val (concur-future-value ,task))))

       ;; Return the value of the future or promise
       ,val)))           

;;;###autoload
(cl-defun concur-async-task-wrap (fn-or-val &key catch finally semaphore schedule cancel-token)
  "Wrap FN-OR-VAL in an async task using `concur-async!`, with optional CATCH, FINALLY, SEMAPHORE, 
  SCHEDULE, and CANCEL-TOKEN.

If FN-OR-VAL is a function, it is invoked asynchronously. If FN-OR-VAL is a value, it is 
resolved immediately using `concur-promise-resolve`.

Arguments:
  - FN-OR-VAL: Either a function to execute asynchronously or a value to resolve immediately.
  - CATCH (optional): A function to handle errors in the asynchronous task.
  - FINALLY (optional): A function to be invoked when the task finishes, regardless of success or failure.
  - SEMAPHORE (optional): A semaphore to limit concurrency.
  - SCHEDULE (optional): If non-nil, bypass the task pool and run the task immediately without scheduling.
  - CANCEL-TOKEN (optional): A symbol or function to check for cancelation. If provided, task execution may 
  be short-circuited based on the token.

Returns:
  A `concur-future` that represents the result of the task."
  (if (functionp fn-or-val)
      ;; Forward the schedule symbol directly to concur-async!
      (concur-async!
       :catch catch
       :finally finally
       :semaphore semaphore
       :cancel cancel-token  
       :schedule schedule ;; Forward the schedule symbol here
       (funcall fn-or-val))
    ;; If FN-OR-VAL is already a value, resolve immediately
    (concur-promise-resolved! fn-or-val)))