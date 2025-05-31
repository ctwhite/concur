;;; concur-promise.el --- Lightweight Promises for async chaining in Emacs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This module provides a lightweight yet comprehensive Promise implementation
;; for Emacs Lisp, designed to facilitate asynchronous programming patterns.
;; It allows for chaining operations, handling errors gracefully, and managing
;; concurrent tasks. This library is a foundational component for building
;; more complex asynchronous systems in Emacs.
;;
;; Core Promise Lifecycle:
;; - Promises start in a "pending" state.
;; - They can be "resolved" with a success value or "rejected" with an error.
;; - Once settled (resolved or rejected), a promise's state does not change.
;; - Callbacks can be attached to a promise to react to its settlement.
;;
;; Key Features:
;; - Basic Promise Operations: `concur:make-promise`, `concur:with-executor`,
;;   `concur:resolve`, `concur:reject`, `concur:resolved!`, `concur:rejected!`.
;; - Chaining and Transformation: `concur:then`, `concur:catch`,
;;   `concur:finally`, `concur:tap`.
;; - Composition: `concur:all`, `concur:race`, `concur:any`,
;;   `concur:all-settled`.
;; - Advanced Control Flow & Utilities:
;;   - `concur:chain`: A powerful threading macro for building complex promise
;;     chains. Supports canonical clauses like `:then`, `:catch`, `:let`, `:if`,
;;     `:tap`, `:all`, `:race`, `:assert`, and syntactic sugar (see `concur--expand-sugar`
;;     for keywords like `:map`, `:filter`, `:each`, `:reduce`, `:sleep`, `:log`, `:retry`).
;;   - `concur:chain-when`: Similar to `concur:chain`, but short-circuits the
;;     processing chain if a step resolves to `nil`.
;;   - `concur:map-series`, `concur:map-parallel`, `concur:retry`.
;;   - `concur:defer`, `concur:delay`, `concur:timeout`.
;; - Cancellation: Integration with `concur-cancel-token`.
;; - Introspection: Status checking functions like `concur:status`.

;;; Code:

(require 'cl-lib)
(require 'concur-cancel)
(require 'dash)
(require 'ht)
;; (require 'scribe nil t) ; Scribe temporarily disabled for error path diagnostics
(require 'ts)
(require 's)
(require 'subr-x)

(declare-function 'macro-function "subr" (symbol))

;; Using plain `message` for all logging in this diagnostic version.
;; For actual use, this should be scribe's log! or a similar structured logger.
(defun log! (level format-string &rest args)
  "Diagnostic logging function using `message`."
  (apply #'message (concat "CONCUR-PROMISE-LOG [" (if (keywordp level) (symbol-name level) (format "%S" level)) "]: " format-string) args))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Constants and Customization                      ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst concur--promise-cancelled-key :cancelled
  "Keyword in rejection objects indicating cancellation.")

(defcustom concur-throw-on-promise-rejection t
  "If non-nil, unhandled rejected promises (not due to cancellation) throw an error."
  :type 'boolean
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Internal Structs                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(cl-defstruct (concur-promise-callback-entry
               (:constructor concur--callback-entry-create (id &key on-resolved on-rejected)))
  id
  on-resolved
  on-rejected)

(cl-defstruct
    (concur-promise
     (:constructor concur--promise-create
                   (&key result error resolved? callbacks
                         cancel-token cancelled? proc)))
  result
  error
  resolved?
  callbacks
  cancel-token
  cancelled?
  proc)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Internal Helpers                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun concur--run-callbacks (promise)
  (let ((callbacks (concur-promise-callbacks promise))
        (result (concur-promise-result promise))
        (error (concur-promise-error promise)))
    (setf (concur-promise-callbacks promise) nil)
    (--each callbacks
      (let ((on-resolved-fn (concur-promise-callback-entry-on-resolved it))
            (on-rejected-fn (concur-promise-callback-entry-on-rejected it)))
        (run-at-time 0 nil
                     (lambda ()
                       (ignore-errors
                         (if error
                             (when on-rejected-fn (funcall on-rejected-fn error))
                           (when on-resolved-fn (funcall on-resolved-fn result))))))))))

(defun concur--check-cancel (promise)
  (let ((cancel-token (concur-promise-cancel-token promise)))
    (when (and cancel-token
               (not (concur-cancel-token-active? cancel-token))
               (not (concur-promise-cancelled? promise))
               (not (concur-promise-resolved? promise)))
      (log! :warn "concur--check-cancel: Promise %S is cancelled via token %S."
            promise cancel-token)
      (concur:cancel promise
                     (format "Cancelled via token %s"
                             (concur-cancel-token-name cancel-token)))
      t)))

(defun concur--has-error? (promise)
  (and (concur-promise-p promise)
       (not (null (concur-promise-error promise)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Core Promise API                               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:make-promise (&rest slots)
  (apply #'concur--promise-create
         :resolved? nil
         :cancelled? nil
         :callbacks nil
         slots))

;;;###autoload
(defun concur:with-executor (executor-fn &optional cancel-token)
  "Create a new promise and immediately invoke EXECUTOR-FN `(lambda (resolve reject))`."
  (let ((promise (concur:make-promise :cancel-token cancel-token)))
    (log! :debug "concur:with-executor: Created promise %S, calling executor." promise)
    (condition-case err ; This `err` should be bound to the error signaled by executor-fn
        (funcall executor-fn
                 (lambda (value) (concur:resolve promise value))
                 (lambda (error-reason) (concur:reject promise error-reason)))
      (error ; This handler is for errors *from* the executor-fn
       ;; Explicitly bind the error condition to a new variable within the handler's scope
       (let ((caught-error-condition err))
         (message "CONCUR:WITH-EXECUTOR: Error in executor. Promise: %S. Caught Condition: %S"
                  promise caught-error-condition)
         (concur:reject promise
                        (list :error-type 'executor-function-error
                              :message "Error in promise executor function"
                              :original-error caught-error-condition)))))
    promise))

;;;###autoload
(defun concur:resolve (promise result)
  (log! :info "concur:resolve: Resolving promise %S with result: %S." promise result)
  (if (or (concur-promise-resolved? promise) (concur-promise-cancelled? promise))
      (log! :warn "concur:resolve: Promise %S already settled/cancelled; skipping." promise)
    (setf (concur-promise-result promise) result
          (concur-promise-error promise) nil
          (concur-promise-resolved? promise) t)
    (log! :debug "concur:resolve: Promise %S marked resolved." promise)
    (concur--run-callbacks promise)))

;;;###autoload
(defun concur:reject (promise error &optional is-cancellation)
  (message "CONCUR:REJECT: Rejecting promise %S with error: %S (cancel: %S)."
           promise error is-cancellation)
  (unless (concur-promise-resolved? promise)
    (setf (concur-promise-error promise) error
          (concur-promise-resolved? promise) t)
    (when is-cancellation (setf (concur-promise-cancelled? promise) t))
    (concur--run-callbacks promise)
    (when (and (not is-cancellation) concur-throw-on-promise-rejection)
      (message "CONCUR:REJECT: Promise %S rejected with unhandled error: %S" promise error)
      (error "[concur] Promise rejected with error: %S" error))))

;;;###autoload
(defun concur:from-callback (fetch-fn)
  (log! :debug "concur:from-callback: Wrapping callback function %S." fetch-fn)
  (concur:with-executor
   (lambda (resolve reject)
     (funcall fetch-fn
              (lambda (result error)
                (if error (funcall reject error) (funcall resolve result)))))))

;;;###autoload
(cl-defun concur:on-resolve (promise &key on-resolved on-rejected)
  (log! :debug "concur:on-resolve: Registering for %S (res: %S, rej: %S)."
        promise (functionp on-resolved) (functionp on-rejected))
  (concur--check-cancel promise)
  (let ((callback-id (make-symbol "promise-cb-id")))
    (if (concur-promise-resolved? promise)
        (progn
          (log! :debug "Promise %S already settled; scheduling immediate cb." promise)
          (run-at-time 0 nil
                       (lambda ()
                         (ignore-errors
                           (if-let ((err (concur-promise-error promise)))
                               (when on-rejected (funcall on-rejected err))
                             (when on-resolved (funcall on-resolved
                                                        (concur-promise-result promise))))))))
      (progn
        (log! :debug "Promise %S pending; queuing cb ID %S." promise callback-id)
        (setf (concur-promise-callbacks promise)
              (append (concur-promise-callbacks promise)
                      (list (concur--callback-entry-create
                             callback-id
                             :on-resolved on-resolved
                             :on-rejected on-rejected))))))
    callback-id))

;;;###autoload
(defun concur:unregister-callback (promise callback-id)
  (log! :debug "concur:unregister-callback: Unregistering ID %S from %S."
        callback-id promise)
  (unless (concur-promise-resolved? promise)
    (let* ((current-cbs (concur-promise-callbacks promise))
           (new-cbs (-remove (lambda (cb) (eq (concur-promise-callback-entry-id cb)
                                              callback-id))
                             current-cbs)))
      (if (< (length new-cbs) (length current-cbs))
          (progn (setf (concur-promise-callbacks promise) new-cbs) t)
        (log! :debug "Callback ID %S not found on promise %S." callback-id promise)
        nil))))

;;;###autoload
(defun concur:resolved! (value)
  (let ((p (concur:make-promise)))
    (log! :info "concur:resolved!: Created resolved promise %S with %S." p value)
    (setf (concur-promise-result p) value
          (concur-promise-resolved? p) t)
    p))

;;;###autoload
(defun concur:rejected! (err)
  (let ((p (concur:make-promise)))
    (setf (concur-promise-error p) err
          (concur-promise-resolved? p) t)
    (message "CONCUR:REJECTED!: Created rejected promise %S with %S." p err)
    p))

;;;###autoload
(defun concur:cancel (promise &optional reason)
  (if (concur-promise-resolved? promise)
      (log! :warn "concur:cancel: Promise %S already settled; no-op." promise)
    (setf (concur-promise-cancelled? promise) t)
    (log! :info "concur:cancel: Cancelling promise %S, reason: %S." promise reason)
    (when-let ((proc (concur-promise-proc promise)))
      (when (process-live-p proc)
        (log! :debug "Killing process %S for cancelled promise %S." proc promise)
        (ignore-errors (kill-process proc))))
    (concur:reject promise
                   (if (and (consp reason) (plist-member reason concur--promise-cancelled-key))
                       reason
                     (list concur--promise-cancelled-key (or reason "Promise cancelled")))
                   t)))

;;;###autoload
(defun concur:await (promise &optional timeout throw-on-error poll-interval)
  (log! :info "concur:await: Awaiting %S (timeout: %S, throw: %S)."
        promise timeout throw-on-error)
  (let* ((start (ts-now)) (interval (or poll-interval 0.05))
         (proc (concur-promise-proc promise)))
    (while (not (concur-promise-resolved? promise))
      (when (concur--check-cancel promise)
        (log! :warn "Promise %S cancelled during await." promise)
        (when throw-on-error (error "Promise cancelled: %S" (concur-promise-error promise)))
        (cl-return-from concur:await (cons nil (concur-promise-error promise))))
      (if proc (accept-process-output proc interval 0) (sit-for interval))
      (when (and timeout (> (ts-diff (ts-now) start 'second) timeout))
        (log! :warn "Timeout (%.2fs) for promise %S." timeout promise)
        (concur:cancel promise '(:timeout "Promise timed out"))))
    (if-let ((err (concur-promise-error promise)))
        (progn (message "CONCUR:AWAIT: promise %S error: %S." promise err)
               (when throw-on-error (error "Promise error: %S" err)) (cons nil err))
      (let ((res (concur-promise-result promise)))
        (log! :info "Await: promise %S resolved: %S." promise res) (cons res nil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Chaining and Transformation                      ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(cl-defun concur:then (promise &rest positional-args &key on-resolved on-rejected)
  (log! :debug "concur:then: Chaining from %S (on-res: %S, on-rej: %S)."
        promise (functionp on-resolved) (functionp on-rejected))
  (let* ((eff-on-res (if (and positional-args (functionp (car positional-args)))
                         (car positional-args) on-resolved))
         (eff-on-rej (if (and positional-args (> (length positional-args) 1)
                              (functionp (cadr positional-args)))
                         (cadr positional-args) on-rejected))
         (chained (concur:make-promise :cancel-token (concur-promise-cancel-token promise))))

    (concur:on-resolve promise
     :on-resolved (lambda (res)
                    (log! :debug "then: Orig %S resolved: %S" promise res)
                    (if (concur-promise-cancelled? promise)
                        (concur:reject chained (or (concur-promise-error promise)
                                                   '(:cancelled "Chained from cancelled promise")) t)
                      (if eff-on-res
                          (condition-case ex
                              (let ((next-val (funcall eff-on-res res)))
                                (if (concur-promise-p next-val)
                                    (concur:on-resolve next-val
                                     :on-resolved (lambda (r) (concur:resolve chained r))
                                     :on-rejected (lambda (e) (concur:reject chained e)))
                                  (concur:resolve chained next-val)))
                            (error (message "CONCUR:THEN:ON-RESOLVED-HANDLER-ERROR: %S. Input res: %S" ex res)
                                   (concur:reject chained ex)))
                        (concur:resolve chained res))))
     :on-rejected (lambda (err)
                    (log! :debug "then: Orig %S rejected: %S" promise err)
                    (if eff-on-rej
                        (condition-case ex
                            (let ((next-val (funcall eff-on-rej err)))
                              (if (concur-promise-p next-val)
                                  (concur:on-resolve next-val
                                   :on-resolved (lambda (r) (concur:resolve chained r))
                                   :on-rejected (lambda (e) (concur:reject chained e)))
                                (concur:resolve chained next-val)))
                          (error (message "CONCUR:THEN:ON-REJECTED-HANDLER-ERROR: %S. Input err: %S" ex err)
                                 (concur:reject chained ex)))
                      (concur:reject chained err))))
    chained))

;;;###autoload
(defun concur:catch (promise handler)
  (log! :debug "concur:catch: Attaching catch handler to %S." promise)
  (concur:then promise :on-rejected handler))

;;;###autoload
(defun concur:finally (promise callback)
  (log! :debug "concur:finally: Attaching finally handler to %S." promise)
  (let ((next (concur:make-promise :cancel-token (concur-promise-cancel-token promise))))
    (concur:on-resolve promise
     :on-resolved (lambda (res)
                    (condition-case ex
                        (let ((fin-res (funcall callback)))
                          (if (concur-promise-p fin-res)
                              (concur:on-resolve fin-res
                               :on-resolved (lambda (_) (concur:resolve next res))
                               :on-rejected (lambda (e) (concur:reject next e)))
                            (concur:resolve next res)))
                      (error (message "CONCUR:FINALLY:ON-RESOLVED-HANDLER-ERROR: %S" ex)
                             (concur:reject next ex))))
     :on-rejected (lambda (err)
                    (condition-case ex
                        (let ((fin-res (funcall callback)))
                          (if (concur-promise-p fin-res)
                              (concur:on-resolve fin-res
                               :on-resolved (lambda (_) (concur:reject next err))
                               :on-rejected (lambda (e) (concur:reject next e)))
                            (concur:reject next err)))
                      (error (message "CONCUR:FINALLY:ON-REJECTED-HANDLER-ERROR: %S" ex)
                             (concur:reject next ex)))))
    next))

;;;###autoload
(defun concur:tap (promise callback)
  (log! :debug "concur:tap: Attaching tap callback to %S." promise)
  (concur:on-resolve promise
   :on-resolved (lambda (val) (ignore-errors (funcall callback val nil)))
   :on-rejected (lambda (err) (ignore-errors (funcall callback nil err))))
  promise)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Promise Composition                            ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:all (promises &rest opts)
  "Return promise that resolves when all PROMISES are fulfilled, or rejects on first error."
  (unless (listp promises)
    (error "concur:all: PROMISES must be a list, but got %S" promises))
  (let ((cancel-token (plist-get opts :cancel-token)))
    (if (null promises)
        (concur:resolved! '())
      (let* ((total (length promises)) (results (make-vector total nil))
             (done (concur:make-promise :cancel-token cancel-token))
             (resolved-count 0) (unregister-ids nil) cancel-callback-id)
        (when cancel-token
          (setq cancel-callback-id
                (concur-cancel-token-on-cancel
                 cancel-token
                 (lambda ()
                   (unless (concur-promise-resolved? done)
                     (log! :warn "concur:all: Cancelled by external token %S."
                           cancel-token)
                     (concur:cancel done
                                    '(:cancelled "All cancelled by external token")))))))
        (log! :debug "concur:all: Awaiting %d promises." total)
        (--each-indexed promises
          (lambda (idx p)
            (unless (concur-promise-p p)
              (error "concur:all: Item at index %d is not a promise: %S" idx p))
            (let ((cb-id
                   (concur:on-resolve p
                    :on-resolved (lambda (res)
                                   (unless (concur-promise-resolved? done)
                                     (aset results idx res)
                                     (setq resolved-count (1+ resolved-count))
                                     (when (= resolved-count total)
                                       (concur:resolve done (cl-coerce results 'list)))))
                    :on-rejected (lambda (err)
                                   (unless (concur-promise-resolved? done)
                                     (concur:reject done err))))))
              (push (cons p cb-id) unregister-ids))))
        (concur:finally done
         (lambda ()
           (log! :debug "concur:all: Cleaning up %d listeners for promise %S."
                 (length unregister-ids) done)
           (--each unregister-ids
             (lambda (item)
               (concur:unregister-callback (car item) (cdr item))))
           (when (and cancel-token cancel-callback-id)
             (concur-cancel-token-unregister cancel-token cancel-callback-id))))
        done))))

;;;###autoload
(defun concur:race (promises &optional cancel-token)
  "Return promise that resolves/rejects with the first PROMISE to settle."
  (unless (listp promises)
    (error "concur:race: PROMISES must be a list, but got %S." promises))
  (log! :info "concur:race: Starting race for %d promises." (length promises))
  (let* ((internal-token-p (null cancel-token))
         (effective-cancel-token (or cancel-token
                                     (concur-cancel-token-create "concur-race-internal")))
         (winner-promise (concur:make-promise :cancel-token effective-cancel-token))
         (settled-flag nil) 
         (unregister-ids nil) 
         (main-cancel-callback-id nil))

    (when cancel-token 
      (setq main-cancel-callback-id
            (concur-cancel-token-on-cancel
             cancel-token 
             (lambda ()
               (unless (concur-promise-resolved? winner-promise)
                 (log! :warn "concur:race: Race cancelled by external token %S."
                       cancel-token)
                 (concur:cancel winner-promise
                                '(:cancelled "Race cancelled by external token")))))))

    (--each promises
      (lambda (p)
        (unless (concur-promise-p p)
          (error "concur:race: Item is not a promise: %S" p))
        (log! :debug "race: Attaching to promise %S." p)
        (let ((cb-id
               (concur:on-resolve p
                :on-resolved (lambda (res)
                               (unless settled-flag
                                 (setq settled-flag t)
                                 (log! :info "race: Promise %S resolved first. Cancelling others." p)
                                 (concur-cancel-token-cancel effective-cancel-token)
                                 (concur:resolve winner-promise res)))
                :on-rejected (lambda (err)
                               (unless settled-flag
                                 (setq settled-flag t)
                                 (log! :info "race: Promise %S rejected first. Cancelling others." p)
                                 (concur-cancel-token-cancel effective-cancel-token)
                                 (concur:reject winner-promise err))))))
          (push (cons p cb-id) unregister-ids))))

    (concur:finally winner-promise
     (lambda ()
       (log! :debug "race: Winner promise %S settled. Cleaning up listeners." winner-promise)
       (--each unregister-ids
         (lambda (item) (concur:unregister-callback (car item) (cdr item))))
       (when (and cancel-token main-cancel-callback-id)
         (concur-cancel-token-unregister cancel-token main-cancel-callback-id))
       ))
    winner-promise))

;;;###autoload
(defun concur:any (promises &optional cancel-token)
  "Resolves with value of first promise in PROMISES to fulfill.
Rejects with AggregateError if all reject."
  (unless (listp promises) (error "concur:any: PROMISES must be list, got %S" promises))
  (log! :info "concur:any: Waiting for any of %d promises." (length promises))
  (if (null promises) (concur:rejected! '(:aggregate-error "No promises provided to concur:any" nil))
    (let* ((num (length promises)) (rejects (make-vector num nil)) (rej-c 0)
           (overall (concur:make-promise :cancel-token cancel-token)) (set? nil)
           (ids nil) main-id)
      (when cancel-token
        (setq main-id (concur-cancel-token-on-cancel
                       cancel-token
                       (lambda () (unless set? (setq set? t)
                                    (concur:cancel overall '(:cancelled "Any cancelled")))))))
      (--each-indexed promises
        (lambda (idx p)
          (unless (concur-promise-p p) (error "Item at %d not promise: %S" idx p))
          (push (cons p (concur:on-resolve p
                         :on-resolved (lambda (r)
                                        (unless set? (setq set? t)
                                          (--each ids (lambda (i)
                                                        (unless (eq (car i) p)
                                                          (concur:cancel (car i) "Race for any won"))))
                                          (concur:resolve overall r)))
                         :on-rejected (lambda (e)
                                        (unless set? (aset rejects idx e) (setq rej-c (1+ rej-c))
                                          (when (= rej-c num) (setq set? t)
                                            (concur:reject overall
                                                           (list :aggregate-error "All promises were rejected"
                                                                 (cl-coerce rejects 'list))))))))
                ids)))
      (concur:finally overall
       (lambda () (log! :debug "any: Overall %S settled. Cleaning." overall)
                (--each ids (lambda (i) (concur:unregister-callback (car i) (cdr item))))
                (when (and cancel-token main-id)
                  (concur-cancel-token-unregister cancel-token main-id))))
      overall)))

;;;###autoload
(defun concur:all-settled (promises &optional cancel-token)
  "Resolves after all PROMISES settle. Resolves with list of outcome objects:
`(:status 'fulfilled :value VAL)` or `(:status 'rejected :reason ERR)`."
  (unless (listp promises) (error "all-settled: PROMISES must be list, got %S" promises))
  (log! :info "all-settled: Waiting for %d promises to settle." (length promises))
  (if (null promises) (concur:resolved! '())
    (let* ((num (length promises)) (outcomes (make-vector num nil))
           (overall (concur:make-promise :cancel-token cancel-token)) (set-c 0)
           (ids nil) main-id)
      (when cancel-token
        (setq main-id (concur-cancel-token-on-cancel
                       cancel-token
                       (lambda () (unless (concur-promise-resolved? overall)
                                    (concur:cancel overall
                                                   '(:cancelled "All-settled cancelled")))))))
      (--each-indexed promises
        (lambda (idx p)
          (unless (concur-promise-p p) (error "Item at %d not promise: %S" idx p))
          (push (cons p (concur:on-resolve p
                         :on-resolved (lambda (r)
                                        (unless (concur-promise-resolved? overall)
                                          (aset outcomes idx `(:status 'fulfilled :value ,r))
                                          (setq set-c (1+ set-c))
                                          (when (= set-c num)
                                            (concur:resolve overall (cl-coerce outcomes 'list)))))
                         :on-rejected (lambda (e)
                                        (unless (concur-promise-resolved? overall)
                                          (aset outcomes idx `(:status 'rejected :reason ,e))
                                          (setq set-c (1+ set-c))
                                          (when (= set-c num)
                                            (concur:resolve overall (cl-coerce outcomes 'list)))))))
                ids)))
      (concur:finally overall
       (lambda ()
         (log! :debug "all-settled: Overall %S settled. Cleaning." overall)
         (--each ids (lambda (i) (concur:unregister-callback (car i) (cdr item))))
         (when (and cancel-token main-id)
           (concur-cancel-token-unregister cancel-token main-id))))
      overall)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                 Utility Functions                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun concur:rejected? (promise)
  "Return non-nil if PROMISE has been rejected (settled with an error)."
  (and (concur-promise-p promise) (concur-promise-resolved? promise)
       (concur--has-error? promise)))

;;;###autoload
(defun concur:error-value (promise)
  "Return the error value of PROMISE if rejected, else nil. Non-blocking."
  (when (concur:rejected? promise) (concur-promise-error promise)))

;;;###autoload
(defun concur:error-message (promise-or-error-val)
  "Return a human-readable message for PROMISE's error or a given ERROR-VAL."
  (let ((err (if (concur-promise-p promise-or-error-val)
                 (concur-promise-error promise-or-error-val)
               promise-or-error-val)))
    (cond ((stringp err) err)
          ((plistp err) (or (plist-get err :message) (plist-get err :error)
                            (format "%S" err)))
          ((symbolp err) (symbol-name err))
          (err (format "%S" err))
          (t nil))))

;;;###autoload
(defun concur:wrap (fn &rest args)
  "Execute FN with ARGS, wrapping result/error in an immediately settled promise."
  (log! :debug "concur:wrap: Wrapping fn %S with args %S." fn args)
  (concur:with-executor
   (lambda (resolve reject)
     (condition-case ex (resolve (apply fn args))
       (error (message "CONCUR:WRAP: Wrapped fn %S failed: %S." fn ex)
              (reject ex))))))

;;;###autoload
(defun concur:status (promise)
  "Return status of PROMISE: 'pending, 'resolved, 'rejected, or 'cancelled."
  (unless (concur-promise-p promise) (error "Invalid promise object: %S" promise))
  (cond ((not (concur-promise-resolved? promise)) 'pending)
        ((concur-promise-cancelled? promise) 'cancelled)
        ((concur:rejected? promise) 'rejected)
        (t 'resolved)))

;;;###autoload
(defun concur:delay (seconds &optional value)
  "Return promise that resolves with VALUE (default t) after SECONDS."
  (log! :info "concur:delay: Delaying %s s, value %S." seconds value)
  (if (<= seconds 0) (concur:resolved! (or value t))
    (let ((p (concur:make-promise)))
      (run-at-time seconds nil (lambda () (concur:resolve p (or value t)))) p)))

;;;###autoload
(defun concur:timeout (inner-promise timeout-seconds)
  "Wrap INNER-PROMISE, rejecting if it doesn't settle within TIMEOUT-SECONDS."
  (log! :info "concur:timeout: Timeout %s s for %S." timeout-seconds inner-promise)
  (unless (concur-promise-p inner-promise)
    (error "INNER-PROMISE must be a promise: %S" inner-promise))
  (let ((p (concur:make-promise
            :cancel-token (concur-promise-cancel-token inner-promise))))
    (concur:on-resolve inner-promise
     :on-resolved (lambda (r) (unless (concur-promise-resolved? p) (concur:resolve p r)))
     :on-rejected (lambda (e) (unless (concur-promise-resolved? p) (concur:reject p e))))
    (run-at-time timeout-seconds nil
                 (lambda () (unless (concur-promise-resolved? p)
                              (log! :warn "timeout: %S timed out." inner-promise)
                              (concur:reject p '(:timeout "Promise timed out")))))
    p))

;;;###autoload
(cl-defun concur:map-series (items fn &key cancel-token)
  "Process ITEMS sequentially with async FN `(lambda (item))` -> promise."
  (log! :info "map-series: Mapping %d items." (length items))
  (let ((res-prom (concur:resolved! '())) (final-res nil))
    (if (null items) res-prom
      (--reduce-from
       (lambda (acc-p cur-item)
         (concur:then acc-p
          :on-resolved (lambda (_)
                         (log! :debug "map-series: Processing %S." cur-item)
                         (let ((item-p (funcall fn cur-item)))
                           (unless (concur-promise-p item-p)
                             (error "FN must return promise, got %S for %S" item-p cur-item))
                           (concur:then item-p
                            :on-resolved (lambda (ir) (push ir final-res) ir)
                            :on-rejected (lambda (e)
                                           (message "CONCUR:MAP-SERIES: Item %S failed: %S" cur-item e)
                                           (signal 'concur-async-error
                                                   (list "Series item failed" e))))))
          :on-rejected (lambda (e)
                         (message "CONCUR:MAP-SERIES: Prev failed: %S" e)
                         (signal 'concur-async-error (list "Series interrupted" e)))))
       res-prom items)
      (concur:then res-prom
       :on-resolved (lambda (_) (nreverse final-res))
       :on-rejected (lambda (e)
                      (message "CONCUR:MAP-SERIES: Failed: %S" e)
                      (signal 'concur-async-error (list "Series failed" e)))))))

;;;###autoload
(cl-defun concur:map-parallel (items fn &key cancel-token)
  "Process ITEMS in parallel with async FN `(lambda (item))` -> promise."
  (log! :info "map-parallel: Mapping %d items." (length items))
  (let ((promises (--map (let ((p (funcall fn it)))
                           (unless (concur-promise-p p)
                             (error "map-parallel: FN must return promise: %S for %S" p it))
                           p)
                         items)))
    (concur:all promises :cancel-token cancel-token)))

;;;###autoload
(cl-defun concur:retry (fn &key retries delay pred cancel-token)
  "Retry async FN `(lambda ())` -> promise, up to RETRIES times on failure."
  (let* ((num (or retries 3)) (r-delay (or delay 0.1))
         (p (or pred #'always)) (att 0)
         (final (concur:make-promise :cancel-token cancel-token)))
    (log! :info "retry: Starting for %S (retries:%d, delay:%S)." fn num r-delay)
    (cl-labels ((do-retry ()
                  (setq att (1+ att))
                  (log! :debug "retry: Attempt #%d for %S." att fn)
                  (let ((current-p (funcall fn)))
                    (unless (concur-promise-p current-p)
                      (error "retry: FN must return promise: %S" current-p))
                    (concur:then current-p
                     :on-resolved (lambda (r) (concur:resolve final r))
                     :on-rejected (lambda (e)
                                    (log! :debug "retry: Att #%d failed: %S" att e)
                                    (if (concur-promise-cancelled? current-p)
                                        (progn (log! :warn "retry: Att cancelled.")
                                               (concur:reject final e t))
                                      (if (or (>= att num) (not (funcall p e)))
                                          (progn (message "CONCUR:RETRY: All retries for %S failed. Final err: %S." fn e)
                                                 (concur:reject final e))
                                        (let ((cd (if (functionp r-delay)
                                                      (funcall r-delay att) r-delay)))
                                          (log! :info "retry: Retrying after %S s (att %d/%d)."
                                                cd att num)
                                          (concur:then (concur:delay cd)
                                           :on-resolved (lambda (_) (do-retry))
                                           :on-rejected (lambda (d-e)
                                                          (message "CONCUR:RETRY: Delay failed: %S." d-e)
                                                          (concur:reject final d-e)))))))))))
      (do-retry))
    final))

;;;###autoload
(cl-defun concur:defer ()
  "Return a deferred promise object `(:promise P :resolve FN :reject FN)`."
  (let ((p (concur:make-promise)))
    (log! :debug "defer: Created deferred promise %S." p)
    (list :promise p
          :resolve (lambda (v) (concur:resolve p v))
          :reject (lambda (e) (concur:reject p e)))))

;;;###autoload
(defun concur:value (promise)
  "Return resolved value of PROMISE, or nil if pending/rejected/resolved with nil."
  (when (and (concur-promise-p promise)
             (concur-promise-resolved? promise)
             (not (concur--has-error? promise)))
    (concur-promise-result promise)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Expansion Helper Functions for concur:chain and concur:chain-when Macros ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun concur--special-or-macro-p (sym)
  "Return non-nil if SYM is a special form or macro."
  (or (special-form-p sym)
      (condition-case nil (macro-function sym) (error nil))
      (memq sym '(lambda defun defmacro let let* progn cond if))))

(defun concur--expand-sugar (steps)
  "Transform sugar keywords in STEPS into canonical `concur:chain` clauses."
  (let ((processed-steps nil)
        (remaining-steps steps)
        arg1 arg2)
    (while remaining-steps
      (let ((key (pop remaining-steps)))
        (pcase key
          (:map
           (unless remaining-steps (error "concur:chain :map needs a form argument"))
           (setq arg1 (pop remaining-steps))
           (push `(:then (lambda (<>)
                           (let ((data <>))
                             (if (listp data)
                                 (--map (lambda (it) (let ((<> it)) ,arg1)) data) ; Ensure <> is bound to 'it' for map
                               (let ((<> data)) ,arg1))))) ; Apply to single item
                 processed-steps))

          (:filter
           (unless remaining-steps (error "concur:chain :filter needs a predicate form"))
           (setq arg1 (pop remaining-steps))
           (push `(:then (lambda (<>)
                           (let ((data <>))
                             (if (listp data)
                                 (--filter (lambda (it) (let ((<> it)) ,arg1)) data) ; Ensure <> is bound to 'it' for filter
                               (if (let ((<> data)) ,arg1) data
                                 (concur:rejected!
                                  (format "Filter predicate %S failed for: %S"
                                          ',arg1 data)))))))
                 processed-steps))

          (:each
           (unless remaining-steps (error "concur:chain :each needs a form argument"))
           (setq arg1 (pop remaining-steps))
           (push `(:tap (lambda (<>)
                          (let ((data <>))
                            (if (listp data)
                                (--each (lambda (it) (let ((<> it)) ,arg1)) data) ; Ensure <> is bound to 'it' for each
                              (let ((<> data)) ,arg1)))))
                 processed-steps))

          (:sleep
           (unless remaining-steps (error "concur:chain :sleep needs milliseconds"))
           (setq arg1 (pop remaining-steps))
           (push `(:then (lambda (<>) ; Explicitly take <>
                           (let ((original-value <>)) ; Capture it
                             (concur:then (concur:delay (/ (float ,arg1) 1000.0))
                                          (lambda (_) original-value))))) ; Return original value
                 processed-steps))

          (:log
           (if (or (null remaining-steps) (keywordp (car remaining-steps)))
               ;; Log current value if no format string
               (push `(:tap (lambda (<>) (log! :info "[concur:chain] value: %S" <>)))
                     processed-steps)
             ;; Format string and potentially args
             (let ((msg-or-fmt (pop remaining-steps))
                   (log-args nil))
               (while (and remaining-steps (not (keywordp (car remaining-steps))))
                 (push (pop remaining-steps) log-args))
               (setq log-args (nreverse log-args))
               ;; Ensure <> is appended to the log arguments if there are other arguments
               (if log-args
                   (push `(:tap (lambda (<>)
                                  (apply #'log! :info ,msg-or-fmt (append ,log-args (list <>)))))
                         processed-steps)
                 (push `(:tap (lambda (<>)
                                (log! :info ,(if (stringp msg-or-fmt) (format "%s: %%S" msg-or-fmt) `(format "%%s: %%S" ,msg-or-fmt))
                                      <>)))
                       processed-steps)))))
          
          (:reduce
           (unless remaining-steps (error "concur:chain :reduce needs (INIT BODY-LAMBDA) argument"))
           (setq arg1 (pop remaining-steps))
           (unless (and (listp arg1) (= (length arg1) 2))
             (error "concur:chain :reduce expects (INIT BODY-LAMBDA), got %S" arg1))
           (pcase-let ((`(,init ,body) arg1))
             (unless (and (consp body) (eq (car body) 'lambda) (>= (length (cadr body)) 2))
               (error "concur:chain :reduce BODY must be a lambda of at least two arguments (accumulator item), got %S" body))
             (push `(:then (lambda (<>)
                             (let ((items <>))
                               (if (listp items)
                                   (--reduce-from ,body ,init items)
                                 (error ":reduce expects list from promise, got: %S"
                                        items)))))
                   processed-steps)))

          (:retry
           (if (or (null remaining-steps) (null (cdr remaining-steps)))
               (error "concur:chain :retry needs N (retries) and BODY-FORM arguments"))
           (setq arg1 (pop remaining-steps)) ; N retries
           (setq arg2 (pop remaining-steps)) ; BODY-FORM
           ;; The BODY-FORM will be wrapped in a lambda that takes the current promise value `<>`
           ;; and makes it available as `<>` inside the BODY-FORM.
           (push `(:then (lambda (<>)
                           (concur:retry (lambda () (let ((<> <>)) ,arg2)) :retries ,arg1)))
                 processed-steps))


          ((or :then :catch :finally :let :if :when :guard :tap :all :race)
           (unless remaining-steps
             (error "Keyword %s needs an argument in concur:chain" key))
           (push key processed-steps)
           (push (pop remaining-steps) processed-steps))

          (:assert
           (if (or (null remaining-steps) (null (cdr remaining-steps)))
               (error ":assert needs a condition and a message string in concur:chain"))
           (push key processed-steps)
           (push (pop remaining-steps) processed-steps)
           (push (pop remaining-steps) processed-steps))

          (_direct-form
           (push key processed-steps)))))
    (nreverse processed-steps)))


(defun concur--expand-chain (current-promise-form steps-to-process)
  "Recursive helper to expand `concur:chain` steps into a promise chain."
  (if (null steps-to-process)
      current-promise-form
    (let* ((step1 (car steps-to-process)) (rest (cdr steps-to-process)))
      (pcase step1
        (:then
         (let* ((form (car rest)) (rest2 (cdr rest)) (val (cl-gensym "val->"))
                on-res on-rej)
           (cond ((and (listp form) (= (length form) 2) (listp (car form)) (listp (cadr form)))
                  (setq on-res `(lambda (,val) (let ((<> ,val)) ,@(car form)))
                        on-rej `(lambda (,val) (let ((<!> ,val)) ,@(cadr form)))))
                 ((listp form) (setq on-res `(lambda (,val) (let ((<> ,val)) ,@form))))
                 (t (error "concur:chain :then expects list(s), got %S" form)))
           (concur--expand-chain `(concur:then ,current-promise-form
                                               ,@(when on-res `(:on-resolved ,on-res))
                                               ,@(when on-rej `(:on-rejected ,on-rej)))
                                 rest2)))
        (:catch
         (let* ((form (car rest)) (rest2 (cdr rest)) (err (cl-gensym "err->")))
           (unless form (error ":catch needs arg"))
           (concur--expand-chain `(concur:catch ,current-promise-form
                                                (lambda (,err) (let ((<!> ,err))
                                                                 ,@(if (listp form) form (list form)))))
                                 rest2)))
        (:finally
         (let ((form (car rest)) (rest2 (cdr rest)))
           (unless form (error ":finally needs arg"))
           (concur--expand-chain `(concur:finally ,current-promise-form
                                                  (lambda () ,@(if (listp form) form (list form))))
                                 rest2)))
        (:let
         (let ((b (car rest)) (r2 (cdr rest)))
           `(let* ,b ,(concur--expand-chain current-promise-form r2))))
        ((or :if :when :guard)
         (let* ((c (car rest)) (r2 (cdr rest)) (v (cl-gensym "v->")))
           (concur--expand-chain `(concur:then ,current-promise-form
                                   :on-resolved (lambda (,v) (let ((<> ,v))
                                                               (if ,c ,v (concur:rejected!
                                                                          (format "Cond %s: %S failed" ',step1 ',c))))))
                                 r2)))
        (:assert
         (let* ((c (car rest)) (m (cadr rest)) (r2 (cddr rest)) (v (cl-gensym "v->")))
           (unless m (error ":assert needs condition and message"))
           (concur--expand-chain `(concur:then ,current-promise-form
                                   :on-resolved (lambda (,v) (let ((<> ,v))
                                                               (if ,c ,v (error ,m)))))
                                 r2)))
        (:tap
         (let* ((f (car rest)) (r2 (cdr rest)) (v (cl-gensym "v->")))
           (unless f (error ":tap needs arg"))
           (concur--expand-chain `(concur:then ,current-promise-form
                                   :on-resolved (lambda (,v) (let ((<> ,v))
                                                               ,@(if (listp f) f (list f)) ,v)))
                                 r2)))
        (:all
         (let ((pf (car rest)) (r2 (cdr rest)))
           (unless pf (error ":all needs list"))
           (concur--expand-chain `(concur:all ,pf) r2)))
        (:race
         (let ((pf (car rest)) (r2 (cdr rest)))
           (unless pf (error ":race needs list"))
           (concur--expand-chain `(concur:race ,pf) r2)))
        (_direct
         (if (and (symbolp step1) (concur--special-or-macro-p step1))
             (error "concur:chain: Direct step '%S' is special/macro." step1)
           (let ((v (cl-gensym "v->")))
             (concur--expand-chain `(concur:then ,current-promise-form
                                     :on-resolved (lambda (,v) (let ((<> ,v)) ,step1)))
                                   rest))))))))

(defun concur--expand-short-circuit-chain (current-promise-form steps-to-process)
  "Recursive helper to expand `concur:chain-when` steps."
  (if (null steps-to-process)
      current-promise-form
    (let* ((step1 (car steps-to-process)) (rest (cdr steps-to-process)))
      (pcase step1
        (:then
         (let* ((arg (car rest)) (rem (cdr rest)) (v (cl-gensym "v?>")) on-res on-rej)
           (cond ((and (listp arg) (= (length arg) 2) (listp (car arg)) (listp (cadr arg)))
                  (setq on-res `(lambda (,v) (when ,v (let ((<> ,v)) ,@(car arg))))
                        on-rej `(lambda (,v) (let ((<!> ,v)) ,@(cadr arg)))))
                 ((listp arg) (setq on-res `(lambda (,v) (when ,v (let ((<> ,v)) ,@arg)))))
                 (t (error "concur:chain-when :then expects list(s), got %S" arg)))
           (concur--expand-short-circuit-chain
            `(concur:then ,current-promise-form
                          ,@(when on-res `(:on-resolved ,on-res))
                          ,@(when on-rej `(:on-rejected ,on-rej)))
            rem)))
        (:catch
         (let* ((arg (car rest)) (rem (cdr rest)) (e (cl-gensym "e?>")))
           (unless arg (error ":catch needs arg"))
           (concur--expand-short-circuit-chain
            `(concur:catch ,current-promise-form
                           (lambda (,e) (let ((<!> ,e)) ,@(if (listp arg) arg (list arg)))))
            rem)))
        (:finally
         (let ((arg (car rest)) (rem (cdr rest)))
           (unless arg (error ":finally needs arg"))
           (concur--expand-short-circuit-chain
            `(concur:finally ,current-promise-form
                             (lambda () ,@(if (listp arg) arg (list arg))))
            rem)))
        (:let
         (let ((b (car rest)) (rem (cdr rest)))
           `(let* ,b ,(concur--expand-short-circuit-chain current-promise-form rem))))
        ((or :if :when :guard)
         (let* ((c (car rest)) (rem (cdr rest)) (v (cl-gensym "v?>")))
           (concur--expand-short-circuit-chain
            `(concur:then ,current-promise-form
                          :on-resolved (lambda (,v) (when ,v (let ((<> ,v))
                                                               (if ,c ,v (concur:rejected! "Condition failed"))))))
            rem)))
        (:assert
         (let* ((c (car rest)) (m (cadr rest)) (rem (cddr rest)) (v (cl-gensym "v?>")))
           (unless m (error ":assert needs condition and message"))
           (concur--expand-short-circuit-chain
            `(concur:then ,current-promise-form
                          :on-resolved (lambda (,v) (when ,v (let ((<> ,v))
                                                               (if ,c ,v (error ,m))))))
            rem)))
        (:tap
         (let* ((arg (car rest)) (rem (cdr rest)) (v (cl-gensym "v?>")))
           (unless arg (error ":tap needs arg"))
           (concur--expand-short-circuit-chain
            `(concur:then ,current-promise-form
                          :on-resolved (lambda (,v) (when ,v (let ((<> ,v))
                                                               ,@(if (listp arg) arg (list arg))
                                                               ,v))))
            rem)))
        (:all
         (let* ((pfs (car rest)) (rem (cdr rest)))
           (unless pfs (error ":all needs list"))
           (concur--expand-short-circuit-chain `(concur:all ,pfs) rem)))
        (:race
         (let* ((pfs (car rest)) (rem (cdr rest)))
           (unless pfs (error ":race needs list"))
           (concur--expand-short-circuit-chain `(concur:race ,pfs) rem)))
        (_form
         (if (and (symbolp step1) (concur--special-or-macro-p step1))
             (error "concur:chain-when: Direct step '%S' is special/macro." step1)
           (let ((v (cl-gensym "v?>")))
             (concur--expand-short-circuit-chain
              `(concur:then ,current-promise-form
                            :on-resolved (lambda (,v) (when ,v (let ((<> ,v)) ,step1))))
              rest))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                           Threading/Chaining Macros                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(cl-defmacro concur:chain (initial-promise-expr &rest steps)
  "Thread INITIAL-PROMISE-EXPR through async STEPS using promise chaining.
INITIAL-PROMISE-EXPR must be a form that evaluates to a promise.
Supports various clauses like `:then`, `:catch`, `:finally`, `:let`, `:if`,
`:when`, `:guard`, `:assert`, `:tap`, `:all`, `:race`, and syntactic sugar
keywords like `:map`, `:filter`, `:each`, `:reduce`, `:sleep`, `:log`, `:retry`.
See `concur--expand-sugar` for details on sugar expansion."
  (declare (indent 1))
  (unless initial-promise-expr
    (error "concur:chain: Must provide at least an initial promise-producing form."))
  (concur--expand-chain initial-promise-expr (concur--expand-sugar steps)))

;;;###autoload
(defalias 'concur-> #'concur:chain "Obsolete. Use `concur:chain` instead.")

;;;###autoload
(cl-defmacro concur:chain-when (initial-promise-expr &rest steps)
  "Like `concur:chain` but short-circuits on nil resolved values.
INITIAL-PROMISE-EXPR must be a form that evaluates to a promise.
If a step resolves to `nil`, subsequent steps are skipped (except :catch/:finally).
Supports the same clauses and sugar keywords as `concur:chain`."
  (declare (indent 1))
  (unless initial-promise-expr
    (error "concur:chain-when: Must provide at least an initial promise-producing form."))
  (concur--expand-short-circuit-chain initial-promise-expr (concur--expand-sugar steps)))

;;;###autoload
(defalias 'concur-?> #'concur:chain-when "Obsolete. Use `concur:chain-when` instead.")

(provide 'concur-promise)
;;; concur-promise.el ends here