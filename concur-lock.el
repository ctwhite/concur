;;; concur-lock.el --- Concur lock macros for Emacs -*- lexical-binding: t; -*-

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
              `(setf ,place ,lock-held)  ;; Simple variable modification
            `(gv-letplace (getter setter) ,place
               (funcall setter ,lock-held)))  ;; For generalized variables
         (unwind-protect (progn ,@body)
           ,(if (symbolp place)
                `(setf ,place nil)  ;; Simple variable modification
              `(gv-letplace (getter setter) ,place
                 (funcall setter nil))))))))

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
        (permanent (gensym "perm")))
    `(let* ((,permanent (and (consp ,place) (eq (car ,place) :permanent)))
            (,real-place (if ,permanent (cadr ,place) ,place)))
       (if ,real-place
           ,(if (and (consp fallback) (eq (car fallback) :else))
                `(progn ,@(cdr fallback))
              fallback)
         (concur-with-lock! ,real-place
           (:else nil)
           ;; Lock acquired: mark it permanent if requested
           ,(if (symbolp real-place)
                `(setf ,real-place t)
              `(gv-letplace (getter setter) ,real-place
                 (funcall setter t)))
           ,@body)))))

(provide 'concur-lock)
;;; concur-lock.el ends here