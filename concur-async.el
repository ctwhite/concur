;;; concur-async.el --- Cooperative async primitives for Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; `concur-task.el` provides lightweight cooperative concurrency for Emacs.
;; It introduces the `concur-async!` macro to run coroutines, with
;; `concur-await!` for async result waiting and `concur-with-semaphore!` for
;; cooperative critical sections. A task scheduler runs via idle timers
;; and requeues coroutines using `ring`.
;;
;;; Code:

(require 'async)
(require 'cl-lib)
(require 'concur-primitives)
(require 'concur-scheduler)
(require 'concur-promise)
(require 'concur-future)
(require 'concur-task)
(require 'dash)
(require 'scribe)
  
(defcustom concur-await-poll-interval 0.005
  "Polling interval in seconds used by `concur-await!` when blocking outside the scheduler.
A small value (e.g. 0.005 = 5ms) gives more responsiveness, but may use more CPU."
  :type 'number
  :group 'concur)

;;;###autoload
(defun concur-async-run (fn &optional mode)
  "Run FN (a function returning a promise or value) asynchronously.

MODE determines how the function is executed:
  - If MODE is 'deferred, use `run-at-time` with 0 delay.
  - If MODE is a number, use `run-at-time` with MODE as the delay.
  - If MODE is 'async or nil, use `async-start` for non-blocking behavior.

Returns a concur-promise resolving to the task result."
  (let ((future (concur-future-new (lambda () (funcall fn))))
        (promise (concur-future-promise future)))
    (cond
     ((eq mode 'deferred)
      (run-at-time 0 nil
                   (lambda ()
                     (concur-future-force future))))
     ((numberp mode)
      (run-at-time mode nil
                   (lambda ()
                     (concur-future-force future))))
     (t
      (async-start
       `(lambda () 
          (require 'concur-future)
          (require 'concur-promise)
          (concur-future-force ,future))
       (lambda (result)
         (concur-promise-resolve promise result)))))
    promise))

;;;###autoload
(defmacro concur-async! (&rest args)
  "Run BODY asynchronously with optional SEMAPHORE, :schedule nil, :cancel TOKEN, and :meta METADATA.

This macro wraps a body of code and runs it asynchronously, supporting optional
parameters for concurrency control, task scheduling, cancellation, and metadata.

Arguments:
  - BODY: The code to be executed asynchronously.
  - :semaphore (optional): A semaphore object to limit the number of concurrent tasks.
  - :schedule (optional): A boolean that determines if the task should be scheduled 
    immediately or queued for later execution (defaults to t).
  - :cancel (optional): A cancellation token, which can be used to cancel the task.
  - :meta (optional): Metadata associated with the task, such as identifiers or tags.

Returns:
  - A `concur-future` representing the result of the task, which can be awaited with
    `concur-await!`.

Behavior:
  - The macro creates a new task, wraps it in a `concur-future`, and schedules it for 
    execution in the background.
  - If a semaphore is provided, the body of the task will be executed with the semaphore
    to limit concurrent executions.
  - If a cancel token is provided, the task checks for cancellation and may short-circuit
    if the cancellation token is active.
  - The task is then added to the scheduler, where it will be executed asynchronously.

Example:
  (concur-async! 
    :semaphore some-semaphore
    :schedule nil
    :cancel cancel-token
    :meta '(\"task1\")
    (do-some-work))

  ;; This example runs the `(do-some-work)` body asynchronously with a semaphore
  ;; and cancellation token. It will be scheduled immediately as the `:schedule`
  ;; argument is `nil`.

Error Handling:
  - If an error occurs during the execution of the task, it will be propagated and
    logged with `concur-promise-reject`."
  (declare (indent defun) (debug (form &rest (sexp body))))
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

    ;; Extract semaphore if present
    (if (and args* (not (keywordp (car args*))))
        (setq semaphore (car args*)
              body (cdr args*))
      (setq body args*))

    ;; Generate symbols
    (let ((done     (gensym "done-"))
          (result   (gensym "result-"))
          (step     (gensym "step-"))
          (self     (gensym "self-"))
          (future   (gensym "future-"))
          (task     (gensym "task-")))

      `(let* ((,done nil)
              (,result nil)
              (,step 0))
         (cl-labels
             ((,self ()
               ;; This catch block is used to allow the asynchronous task
               ;; to "yield" control back to the scheduler at certain points.
               ;; If the task needs to pause (e.g., waiting for a semaphore or
               ;; a cancellation check), it will throw the control to the 'concur-yield
               ;; label, allowing the scheduler to take over.
               ;;
               ;; This makes the task cooperative, meaning that it can voluntarily
               ;; give up control back to the scheduler at appropriate points.
               ;;
               ;; The catch will not end the task, it just allows for cooperative
               ;; multitasking where the task can resume later after the yield point.
               (catch 'concur-yield
                 (when ,(if cancel-token
                            `(not (concur-cancel-token-active-p ,cancel-token))
                          t)

                   ;; Yield before execution if scheduling type is 'thread'                                                    
                   (when (eq ,schedule 'thread)
                     (thread-yield))

                   ;; Execute the task with semaphore or without, beginning at 
                   ;; the current form in the body since last yield (if any)
                   (pcase ,step
                     ,@(-map-indexed
                        (lambda (i form)
                          `(,i
                            ,(if semaphore
                                 `(concur-with-semaphore! ,semaphore 'concur-scheduler-enqueue-task
                                    (setq ,result ,form))
                               `(setq ,result ,form))
                            (cl-incf ,step)
                            (when (< ,step ,(length body))
                              (throw 'concur-yield nil))))
                        ',body))
                   (setq ,done t)))))

           ;; Create the future task
           (let* ((,task nil)
                  (,future
                   (concur-future-new
                    (lambda ()
                      (let ((started nil))
                        (unwind-protect
                            (progn
                              ;; Bind task now that it's initialized
                              (concur-task-mark-started ,task)
                              (setq started t)

                              (run-hook-with-args 'concur-task-started-hook ,task)
                              (,self)
                              (when ,done
                                (when ,(if cancel-token
                                           `(not (concur-cancel-token-active-p ,cancel-token))
                                         t)
                                  ,result)))
                          ;; Clean up - mark task as ended
                          (when started
                            (run-hook-with-args 'concur-task-ended-hook ,task)
                            (concur-task-mark-ended ,task))))))))

             ;; Create the task
             (setq ,task
                   (concur-task-new
                    :future ,future
                    :schedule ,schedule
                    :cancel-token ,cancel-token
                    :data ,meta))

             ;; Schedule the task
             (concur-scheduler-enqueue-task ,task)
             (concur-future-promise ,future)))))))

;;;###autoload
(defmacro concur-await! (form &rest args)
  "Await the result of FORM, which must evaluate to a `concur-future` or `concur-promise`.

This macro blocks execution until the result of FORM is available, whether it's a
`concur-future` or a `concur-promise`. The future or promise can be created either
inside the scheduler or outside of it.

Behavior:
  - If called **inside the scheduler**, it yields cooperatively by re-queuing the
    task to the scheduler until the task is completed.
  - If called **outside the scheduler**, it uses a polling loop, periodically
    checking the status of the task with `sleep-for` to avoid blocking the Emacs
    event loop.

Arguments:
  - FORM: The expression that should evaluate to a `concur-future` or `concur-promise`.

Returns:
  - The value stored in the future or promise if successful, or signals an error if
    encountered.

Error Handling:
  - If the future or promise has encountered an error, it will be raised as a Lisp
    error using `signal`.

Example:
  (concur-await! (concur-async! (some-task)))
  ;; Wait until the asynchronous task completes, then continue execution."
  (declare (indent defun) (debug (form &rest (sexp args))))
  (let ((task (gensym "task"))
        (promise (gensym "promise"))
        (timeout (gensym "timeout"))
        (start (gensym "start")))
    `(let* ((,task ,form)
            (,timeout (plist-get (list ,@args) :timeout))
            (,start (and ,timeout (float-time)))
            (,promise
             (cond
              ((concur-future-p ,task)
               (concur-future-force ,task)
               (concur-future-promise ,task))
              ((concur-promise-p ,task) ,task)
              (t (error "Expected a concur-future or concur-promise, got: %S" ,task)))))

       (if concur--scheduler-running
           ;; Inside scheduler: cooperative wait with manual timeout
           (cl-labels ((self ()
                              (when (and ,timeout
                                         (> (- (float-time) ,start) ,timeout))
                                (signal 'concur-timeout (list ,task)))
                              (unless (concur-promise-resolved? ,promise)
                                (concur-scheduler-enqueue-task #'self))))
             (concur-block-until
              (lambda ()
                (or (concur-promise-resolved? ,promise)
                    (and ,timeout
                         (> (- (float-time) ,start) ,timeout))))
              #'self))
         ;; Outside scheduler: delegate to promise await (which handles timeout internally)
         nil)

       ;; Final result or error
       (concur-promise-await ,promise ,timeout))))

(defmacro concur-fire-and-forget! (&rest body)
  "Run BODY asynchronously without tracking result or cancellation.
Intended for side-effecting tasks where result is not needed."
  `(ignore (concur-async! ,@body)))

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
  - CANCEL-TOKEN (optional): A symbol or function to check for cancellation. If provided, task execution may 
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

;;;###autoload
(cl-defun concur-async-task-pipe (initial &rest fns &key semaphore schedule cancel-token)
  "Pipe INITIAL through FNS. Each function receives the result of the previous function.

This function executes each function in the sequence `fns` asynchronously, passing the result
from one function to the next. Optionally, SEMAPHORE can be used to limit concurrency.

Arguments:
  - INITIAL: The initial value passed into the first function in the pipeline.
  - FNS: A list of functions to apply in sequence to the result of the previous function.
  - SEMAPHORE (optional): A semaphore to control concurrency during the pipeline execution.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs the task immediately.
  - CANCEL-TOKEN (optional): A symbol or function to check for cancelation. If provided, task execution 
  may be short-circuited based on the token.

Returns:
  A `concur-future` representing the result of the last function in the pipeline."
  (let ((pipeline-fn
         (lambda (acc fn)
           (concur-promise-then acc
             (lambda (res)
               (concur-async-task-wrap (funcall fn res)
                                       :semaphore semaphore
                                       :schedule schedule
                                       :cancel cancel-token))))))
    ;; Apply each function in FNS to the result of the previous function in the pipeline
    (--reduce-from pipeline-fn
                   (concur-async-task-wrap initial :semaphore semaphore :schedule schedule :cancel cancel-token)
                   fns)))

;;;###autoload
(cl-defun concur-async-task-parallel (&rest tasks &key semaphore schedule cancel-token)
  "Run TASKS concurrently, with optional SEMAPHORE to limit concurrency.

Each task in TASKS is executed asynchronously. Optionally, a SEMAPHORE can be passed to
control the number of concurrent tasks.

Arguments:
  - TASKS: A list of functions or values to execute asynchronously.
  - SEMAPHORE (optional): A semaphore to limit concurrent task execution.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.
  - CANCEL-TOKEN (optional): A symbol or function to check for cancelation. If provided, task execution 
  may be short-circuited based on the token.

Returns:
  A `concur-future` representing the result of all tasks in parallel."
  (let ((wrapped (--map (lambda (task)
                          (concur-async-task-wrap task
                                                 :semaphore semaphore
                                                 :schedule schedule
                                                 :cancel cancel-token))
                        tasks)))
    ;; Wait for all tasks to complete and return their results
    (concur-promise-all wrapped)))

;;;###autoload
(cl-defun concur-async-task-map (task-fn tasks &key (semaphore 1) (cancel nil))
  "Map a function (TASK-FN) across a sequence of TASKS asynchronously.
TASK-FN should be a function that returns a thunk (a function to execute).
If CANCEL is provided and the cancellation condition is met, remaining tasks will be cancelled.

TASK-FN will be called asynchronously with each task in the TASKS list.

If no semaphore is provided, no concurrency limit will be enforced.
If no cancel token is provided, cancellation will not be handled."

  (let ((tasks-done 0)                 ;; Counter to track completed tasks
        (called? nil)                  ;; Flag to ensure callback is called once
        (total-tasks (length tasks))  ;; Total tasks to track
        (controller (make-symbol "concur-async-task-map-cancel-token"))
        (fallback-callback (lambda ()
                              (when (and (not called?) (>= tasks-done total-tasks))
                                (funcall cancel nil)))))
    
    (cl-labels
        ((should-cancel-p ()
           (or (and cancel (funcall cancel))
               (symbol-value controller)))

         (wrapped-task-fn (task)
           (lambda ()
             (unless (should-cancel-p)
               (funcall task)
               (setq tasks-done (1+ tasks-done))
               (when (and (not called?) (>= tasks-done total-tasks))
                 (funcall fallback-callback))))))
      
      ;; Apply wrapped task function to each task
      (mapc (lambda (task)
              (funcall (wrapped-task-fn task)))
            tasks)

      ;; Return a cancellation function
      (lambda ()
        (setf (symbol-value controller) t)))))

;;;###autoload
(cl-defun concur-async-task-race (task-fn tasks &key (semaphore 1) (cancel nil) (timeout-seconds nil))
  "Race across a sequence of tasks asynchronously, invoking the callback with the first successful result.

TASK-FN should be a function that takes a task and returns a thunk (a function to execute).
Each task is wrapped via `concur-async-task-wrap` and raced via `concur-promise-race`.

If CANCEL is provided (a cancel token), remaining tasks will be cancelled when the token becomes inactive.
If TIMEOUT-SECONDS is provided, each task will be subject to a timeout."
  (let* ((cancel-token (or cancel (concur-cancel-token-create)))
         (promises
          (--map (let* ((thunk (funcall task-fn it))
                        (wrapped (concur-async-task-wrap
                                  thunk
                                  :semaphore semaphore
                                  :cancel-token cancel-token)))
                   (if timeout-seconds
                       (concur-promise-timeout wrapped timeout-seconds)
                     wrapped))
                 tasks)))
    (concur-promise-race promises)))
    
;;;###autoload
(cl-defun concur-async-task-chain (&rest tasks &key semaphore catch finally schedule)
  "Run TASKS sequentially, each depending on the result of the previous.
Each task in TASKS is executed in sequence, and the result of each task is passed to the next one.

Arguments:
  - TASKS: A list of tasks (functions) to execute sequentially.
  - SEMAPHORE (optional): A semaphore to control concurrency during execution.
  - CATCH (optional): A function to handle errors in the asynchronous task.
  - FINALLY (optional): A function to be invoked when the task finishes, regardless of success or failure.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the final result after executing all tasks sequentially."
  (concur-promise-let* ((results
                         (--reduce-from
                          (lambda (promise task)
                            (concur-promise-then promise
                              (lambda (acc)
                                (let* ((prev (car (last acc)))
                                       (run (lambda () (funcall task prev)))
                                       (next (concur-async-task-wrap run 
                                                                  :semaphore semaphore 
                                                                  :catch catch 
                                                                  :finally finally
                                                                  :schedule schedule)))
                                  (concur-promise-then next
                                    (lambda (res)
                                      (append acc (list res))))))))
                          (concur-promise-resolve '())
                          tasks)))
    results))

;;;###autoload
(cl-defun concur-async-task-reduce (fn init items &key semaphore schedule)
  "Reduce ITEMS sequentially using FN, which returns a promise.
Each step of the reduction is done asynchronously, and the result of each step is passed to the next.

Arguments:
  - FN: A function that takes the accumulator and item and returns a promise.
  - INIT: The initial value of the accumulator.
  - ITEMS: A list of items to reduce.
  - SEMAPHORE (optional): A semaphore to control concurrency during reduction.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the final result after reducing all items."
  (let ((step
         (lambda (acc item)
           (concur-promise-then acc
             (lambda (res)
               (let ((thunk (lambda () (funcall fn res item))))
                 (concur-async-task-wrap thunk
                                         :semaphore semaphore
                                         :schedule schedule)))))))
    ;; Sequential reduction using FN
    (--reduce-from step
                  (concur-promise-resolve init)
                  items)))

;;;###autoload
(cl-defun concur-async-task-with-retries (task &key (retries 3) schedule)
  "Run TASK (a thunk or function) with up to RETRIES attempts on failure.

Arguments:
  - TASK: A function or thunk to run.
  - RETRIES: The number of retry attempts (default: 3).
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of the task after retries, or an error if it fails."
  (concur-promise-catch
   (concur-async-task-wrap task
                           :schedule schedule)
   (lambda (err)
     (if (> retries 0)
         (concur-async-task-with-retries task :retries (1- retries) :schedule schedule)
       (concur-promise-reject err)))))

;;;###autoload
(cl-defun concur-async-task-timeout (task secs &key schedule)
  "Run TASK (a thunk or promise), but reject if it takes longer than SECS seconds.

Arguments:
  - TASK: A function or promise to execute.
  - SECS: The maximum time in seconds to wait for TASK to complete.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` that either resolves when the task completes or rejects if it times out."
  (concur-promise-race
   (list
    (concur-async-task-wrap task :schedule schedule)
    (concur-promise-then (concur-promise-delayed secs)
      (lambda (_) (concur-promise-reject "Timeout"))))))

;;;###autoload
(cl-defun concur-async-task-retry-while (task pred &key (delay 0.5) schedule)
  "Run TASK and retry if it fails and PRED returns non-nil on the error.
Wait DELAY seconds between retries.

Arguments:
  - TASK: A function or promise to run.
  - PRED: A predicate function that determines if the task should be retried.
  - DELAY: The delay in seconds between retries (default: 0.5).
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of the task, retrying on failure."
  (concur-promise-catch
   (concur-async-task-wrap task :schedule schedule)
   (lambda (err)
     (if (funcall pred err)
         (concur-promise-then (concur-promise-delayed delay)
           (lambda () (concur-async-task-retry-while task pred :delay delay :schedule schedule)))
       (concur-promise-reject err)))))

;;;###autoload
(defun concur-async-task-loop (fn &key schedule)
  "Continuously run FN as long as it returns a truthy value.
Each iteration waits for the previous to resolve.

Arguments:
  - FN: A function that returns a truthy value to continue the loop.
  - SCHEDULE (optional): If non-nil, bypasses task pool and runs tasks immediately.

Returns:
  A `concur-future` representing the result of the loop, or nil if the loop ends."
  (concur-promise-then (concur-async-task-wrap fn :schedule schedule)
    (lambda (res)
      (if res
          (concur-async-task-loop fn :schedule schedule)
        (concur-promise-resolve nil)))))

;;;###autoload
(cl-defun concur-async-task-debounce (fn &key (delay 0.5))
  "Return a debounced version of FN that runs only after DELAY seconds of inactivity.

Arguments:
  - FN: A function to debounce.
  - DELAY: The delay in seconds before FN is called (default: 0.5).

Returns:
  A debounced version of FN."
  (let ((timer nil))
    (lambda (&rest args)
      (when timer (cancel-timer timer))
      (setq timer
            (run-with-timer delay nil
                            (lambda () (apply fn args)))))))

;;;###autoload
(defun concur-async-task-with-progress (task on-progress)
  "Run TASK and call ON-PROGRESS with 1.0 when complete.
Use this for tasks that don't natively report progress but need a completion signal.

Arguments:
  - TASK: A function or promise to run.
  - ON-PROGRESS: A function to call with progress updates, including a final value of 1.0.

Returns:
  A `concur-future` representing the result of TASK after calling ON-PROGRESS."
  (concur-promise-then (concur-async-task-wrap task)
    (lambda (res)
      (funcall on-progress 1.0)
      res)))

(provide 'concur-async)
;;; concur-async.el ends here



;; (defun concur-stream-results (tasks callback &optional schedule)
;;   "Run a list of TASKS asynchronously and stream results to CALLBACK as they complete.
;; If SCHEDULE is 'thread, ensure thread safety using a mutex. Otherwise, rely on
;; consult-async! to handle task scheduling."
;;   (let ((results (make-ring (length tasks)))  ; Shared ring buffer to collect results
;;         (completed 0)                        ; Track number of completed tasks
;;         (mutex (if (eq schedule 'thread) (make-thread-mutex) nil))) ; Mutex for threading
  
;;     (cl-labels
;;         ((task-execution (task)
;;            "Execute the task and handle result streaming."
;;            (let ((result (funcall task)))      ;; Execute the task
;;              (ring-insert results result)      ;; Insert the result into the ring
;;              (funcall callback result)         ;; Stream the result
;;              (setq completed (1+ completed))   ;; Increment completed tasks
;;              (when (= completed (length tasks))
;;                (message "All tasks completed."))))

;;       ;; Prepare task functions to pass to consult-async!
;;       (dolist (task tasks)
;;         (cl-labels
;;             ((task-wrapper ()
;;                "Wrap the task lambda with thread safety if needed."
;;                (if (eq schedule 'thread)
;;                    (with-mutex mutex
;;                      (task-execution task))  ;; Ensure thread safety here
;;                  (task-execution task))))   ;; No mutex for non-threaded

;;           (consult-async!
;;            task-wrapper  ;; Pass the wrapper (which includes mutex logic if needed)
;;            :schedule schedule)))

;;     ;; Return the ring of results (could be processed concurrently)
;;     results))