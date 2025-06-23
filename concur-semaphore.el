;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-semaphore.el --- Semaphore Primitive for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides the `concur-semaphore` primitive, a counting
;; semaphore for controlling access to a finite number of resources.
;; It supports both cooperative (`:deferred`, `:async`) and thread-blocking
;; (`:thread`) acquisition, integrating with the `concur-lock` and `concur-core`
;; modules for internal synchronization and asynchronous operation.

;;; Code:

(require 'cl-lib)           ; For cl-incf, cl-decf, cl-delete, cl-loop
(require 'subr-x)           ; For when-let
(require 'concur-core)      ; For promises, executors, errors, `concur--log`,
                            ; `concur-promise-p`, `user-error`
(require 'concur-lock)      ; For concur-lock and concur:with-mutex!
(require 'concur-microtask) ; For scheduling callbacks as microtasks

;; Ensure native Emacs thread functions are loaded if available.
(when (fboundp 'make-thread) (require 'thread))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Struct Definition

(eval-and-compile
  (cl-defstruct (concur-semaphore (:constructor %%make-semaphore))
    "A semaphore for controlling access to a finite number of resources.
Its behavior depends on the `mode` of its internal lock.

  Arguments:
  - `count` (integer): The current number of available slots. Defaults to 0.
  - `max-count` (integer): The maximum capacity of the semaphore. Defaults to 0.
  - `name` (string): A descriptive name for the semaphore. Defaults to \"\".
  - `lock` (concur-lock): The internal mutex protecting the semaphore's state.
    Defaults to `nil` (initialized in `concur:make-semaphore`).
  - `wait-queue` (list): A queue of `(resolve . reject)` pairs (for
    `:thread` mode) or `resolve-fn` (for `:deferred` mode) for waiting
    acquirers. Defaults to `nil`.
  - `cond-var` (condition-variable or nil): The condition variable used
    for waiting/notifying in `:thread` mode. Defaults to `nil`."
    (count 0 :type integer)
    (max-count 0 :type integer)
    (name "" :type string)
    (lock nil :type (or null (satisfies concur-lock-p)))
    (wait-queue nil :type list)
    (cond-var nil :type (or null (satisfies condition-variable-p)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public Semaphore API

;;;###autoload
(cl-defun concur:make-semaphore (n &optional name &key (mode :deferred))
  "Create a semaphore with N available slots.
The semaphore's internal lock `mode` determines its blocking behavior.

  Arguments:
  - `N` (integer): The initial (and maximum) number of available slots.
    Must be a non-negative integer.
  - `NAME` (string, optional): A descriptive name for debugging.
    Defaults to a unique `gensym`-based name.
  - `:MODE` (symbol, optional): The semaphore's internal lock mode.
    Can be `:deferred`, `:async` (cooperative), or `:thread` (blocking).
    Defaults to `:deferred`.

  Returns:
  - (concur-semaphore): A new semaphore object."
  (unless (and (integerp n) (>= n 0))
    (user-error "concur:make-semaphore: Semaphore count must be a \
                 non-negative integer: %S" n))
  (unless (memq mode '(:deferred :async :thread))
    (user-error "concur:make-semaphore: Invalid mode %S. Must be :deferred, \
                 :async, or :thread." mode))
  (let* ((sem-name (or name (format "sem-%S" (gensym))))
         (sem-lock (concur:make-lock (format "sem-lock-%s" sem-name)
                                     :mode mode)))
    (concur--log :debug sem-name "Creating semaphore with %d slots, mode %S."
                 n mode)
    (pcase mode
      (:thread
       (unless (fboundp 'make-thread)
         (user-error "concur:make-semaphore: Cannot create :thread mode \
                      semaphore without Emacs thread support."))
       (%%make-semaphore
        :count n :max-count n :name sem-name :lock sem-lock
        :cond-var (make-condition-variable
                   (concur-lock-native-mutex sem-lock))))
      ((or :async :deferred)
       (%%make-semaphore
        :count n :max-count n :name sem-name :lock sem-lock)))))

;;;###autoload
(defun concur:semaphore-try-acquire (sem)
  "Attempt to acquire a slot from `SEM` without blocking.
If successful, decrements the semaphore count and returns `t`.

  Arguments:
  - `SEM` (concur-semaphore): The semaphore to acquire.

  Returns:
  - (boolean): `t` if a slot was acquired, `nil` otherwise."
  (unless (concur-semaphore-p sem)
    (user-error "concur:semaphore-try-acquire: Invalid semaphore object: %S"
                sem))
  (let ((acquired-p nil))
    (concur:with-mutex! (concur-semaphore-lock sem)
      (when (> (concur-semaphore-count sem) 0)
        (cl-decf (concur-semaphore-count sem))
        (setq acquired-p t)))
    (when acquired-p
      (concur--log :debug (concur-semaphore-name sem) "Acquired slot via try-acquire. Count: %d." (concur-semaphore-count sem))
      ;; If resource tracking is active, register the acquisition.
      (when (and (fboundp 'concur-resource-tracking-function)
                 concur-resource-tracking-function)
        (funcall concur-resource-tracking-function :acquire sem)))
    acquired-p))

;;;###autoload
(defun concur:semaphore-release (sem)
  "Release one slot in `SEM`.
Increments the semaphore count and notifies a waiting acquirer if any
exists. This function is thread-safe.

  Arguments:
  - `SEM` (concur-semaphore): The semaphore to release.

  Returns:
  - `nil` (side-effect: modifies the semaphore, notifies waiters)."
  (unless (concur-semaphore-p sem)
    (user-error "concur:semaphore-release: Invalid semaphore object: %S" sem))
  ;; If resource tracking is active, release the acquisition.
  (when (and (fboundp 'concur-resource-tracking-function)
             concur-resource-tracking-function)
    (funcall concur-resource-tracking-function :release sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
    (if (>= (concur-semaphore-count sem) (concur-semaphore-max-count sem))
        (user-error "concur:semaphore-release: Cannot release semaphore '%s': \
                     already at max capacity (%d)"
                    (concur-semaphore-name sem)
                    (concur-semaphore-max-count sem))
      (cl-incf (concur-semaphore-count sem))
      (concur--log :debug (concur-semaphore-name sem) "Released slot. Count: %d." (concur-semaphore-count sem))
      ;; After incrementing, check if anyone is waiting.
      (pcase (concur-lock-mode (concur-semaphore-lock sem))
        (:thread
         (when (concur-semaphore-cond-var sem)
           (condition-notify (concur-semaphore-cond-var sem))))
        ((or :async :deferred) ; Cooperative modes
         (when-let ((waiter-fns (cl-loop while (concur-semaphore-wait-queue sem)
                                         collect (pop (concur-semaphore-wait-queue sem)))))
           ;; Schedule all queued waiters as microtasks
           (concur-microtask-queue-add waiter-fns)))))))

;;;###autoload
(cl-defun concur:semaphore-acquire (sem &key timeout)
  "Acquire a slot from `SEM`, returning a promise for the operation.
The returned promise resolves with `t` on successful acquisition or rejects
with a `concur-timeout-error` on timeout. This function is thread-safe.

  Arguments:
  - `SEM` (concur-semaphore): The semaphore to acquire.
  - `:TIMEOUT` (number, optional): Maximum seconds to wait for acquisition.
    If `nil`, waits indefinitely.

  Returns:
  - (concur-promise): A promise that resolves to `t` on successful
    acquisition, or rejects on timeout or other error."
  (unless (concur-semaphore-p sem)
    (user-error "concur:semaphore-acquire: Invalid semaphore object: %S" sem))
  (let ((mode (concur-lock-mode (concur-semaphore-lock sem)))
        (sem-name (concur-semaphore-name sem)))
    (concur:with-executor (lambda (resolve reject)
      (let ((acquired nil)
            (timer nil)
            (acquirer-cb (lambda () (funcall resolve t))))
        ;; Set up timeout if requested.
        (when timeout
          (setq timer
                (run-at-time
                 timeout nil
                 (lambda ()
                   (concur:with-mutex! (concur-semaphore-lock sem)
                     ;; Remove the current waiter from the queue if still present
                     (setf (concur-semaphore-wait-queue sem)
                           (cl-delete (cons resolve reject)
                                      (concur-semaphore-wait-queue sem)
                                      :test #'equal)))
                   (concur--log :warn sem-name "Acquisition timed out after %Ss."
                                timeout)
                   (funcall reject (concur:make-error :type :timeout
                                                      :message (format "Semaphore \
                                                                       acquisition \
                                                                       for '%s' \
                                                                       timed out \
                                                                       after %Ss."
                                                                       sem-name
                                                                       timeout)))))))
        ;; Attempt to acquire immediately.
        (concur:with-mutex! (concur-semaphore-lock sem)
          (if (> (concur-semaphore-count sem) 0)
              (progn
                (cl-decf (concur-semaphore-count sem))
                (setq acquired t)
                (concur--log :debug sem-name "Acquired slot immediately. Count: %d."
                             (concur-semaphore-count sem)))
            ;; If not available, queue the acquirer.
            (pcase mode
              (:thread
               ;; For :thread mode, queue (resolve . reject) pair to notify
               (setf (concur-semaphore-wait-queue sem)
                     (append (concur-semaphore-wait-queue sem)
                             (list (cons resolve reject)))))
              ((or :async :deferred)
               ;; For cooperative modes, queue the `acquirer-cb` directly.
               (setf (concur-semaphore-wait-queue sem)
                     (append (concur-semaphore-wait-queue sem)
                             (list acquirer-cb)))))
            (concur--log :debug sem-name "Queueing for acquisition. Queue length: %d."
                         (length (concur-semaphore-wait-queue sem)))))
        (cond
         (acquired
          (when timer (cancel-timer timer)) ; Cancel timeout if acquired
          (funcall resolve t)) ; Resolve immediately if acquired
         ((eq mode :thread)
          ;; For :thread mode, perform actual blocking wait outside the lock,
          ;; then re-acquire the lock to decrement and resolve.
          (concur:with-mutex! (concur-semaphore-lock sem)
            (while (zerop (concur-semaphore-count sem))
              (condition-wait (concur-semaphore-cond-var sem)))
            (cl-decf (concur-semaphore-count sem))
            (concur--log :debug sem-name "Acquired slot after thread wait. Count: %d."
                         (concur-semaphore-count sem))
            (when timer (cancel-timer timer)) ; Cancel timeout if acquired
            (funcall resolve t))))))
     :mode mode))) ; Ensure the executor runs in the correct mode context

;;;###autoload
(defmacro concur:with-semaphore! (sem-obj &rest body)
  "Execute BODY after acquiring a slot from SEM-OBJ.
Ensures the acquired slot is released upon successful completion of BODY
or if an error occurs within BODY.

  Arguments:
  - `SEM-OBJ` (concur-semaphore): The semaphore object to acquire a slot from.
  - `BODY` (forms): The forms to execute after acquiring the semaphore.
    The first form can optionally be an `:else` clause
    `(:else <fallback-forms...>)` to execute on timeout of acquisition.

  Returns:
  - (concur-promise): A promise that resolves with the result of `BODY`
    or rejects with a timeout error or any error from `BODY`."
  (declare (indent 1) (debug t))
  (let* ((fallback-forms '((concur:rejected!
                            (concur:make-error
                             :type :timeout
                             :message "Semaphore acquisition timed out."))))
         (main-body body))
    (when (and (consp (car body)) (eq (caar body) :else))
      (setq fallback-forms (cdr (car body))) ; Get forms after :else
      (setq main-body (cdr body))) ; Rest of body after :else clause

    `(concur:chain (concur:semaphore-acquire ,sem-obj)
       (:then (lambda (_)
                (unwind-protect (progn ,@main-body)
                  ;; Ensure release in all cases.
                  (concur:semaphore-release ,sem-obj))))
       (:catch (lambda (err)
                 (concur--log :error (concur-semaphore-name ,sem-obj)
                              "Semaphore acquisition or body failed: %S" err)
                 ;; If acquisition itself fails (e.g., timeout), execute fallback.
                 (if (concur-error-p err)
                     (pcase (concur-error-type err)
                       (:timeout
                        (concur:chain (concur:rejected! err) ; Re-reject timeout error
                          (:finally (lambda () ,@fallback-forms))))
                       (_ (concur:rejected! err)))
                   (concur:rejected! err)))))))

;;;###autoload
(cl-defun concur:semaphore-status (sem)
  "Return a snapshot of the `SEM`'s current status.

  Arguments:
  - `SEM` (concur-semaphore): The semaphore to inspect.

  Returns:
  - (plist): A property list with semaphore metrics:
    `:name`: Name of the semaphore.
    `:count`: Current available slots.
    `:max-count`: Maximum capacity.
    `:mode`: Concurrency mode (:deferred, :thread).
    `:pending-acquirers`: Number of promises waiting to acquire a slot."
  (interactive)
  (unless (concur-semaphore-p sem)
    (user-error "concur:semaphore-status: Invalid semaphore object: %S" sem))
  (concur:with-mutex! (concur-semaphore-lock sem)
    `(:name ,(concur-semaphore-name sem)
      :count ,(concur-semaphore-count sem)
      :max-count ,(concur-semaphore-max-count sem)
      :mode ,(concur-lock-mode (concur-semaphore-lock sem))
      :pending-acquirers ,(length (concur-semaphore-wait-queue sem)))))

(provide 'concur-semaphore)
;;; concur-semaphore.el ends here