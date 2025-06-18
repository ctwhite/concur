;;; concur-combinators.el --- Combinator functions for Concur Promises -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This file provides functions that operate on collections of promises,
;; allowing for complex asynchronous control flow. It includes standard
;; combinators like `concur:all` (wait for all to succeed), `concur:race`
;; (wait for the first to settle), `concur:any` (wait for the first to
;; succeed), and more.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-primitives)
(require 'concur-ast)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Combinators

;;;###autoload
(defun concur:all (promises-list)
  "Return a promise that resolves when all promises in PROMISES-LIST resolve.
If any promise in the list rejects, the returned promise immediately rejects
with the reason of the first promise that rejected.

Arguments:
- `promises-list`: (list) A list of promises or plain values. Plain values are
  treated as already-resolved promises.

Returns:
- (`concur-promise`) A promise that resolves with a list of values (in the
  same order as `promises-list`), or rejects with the first error."
  (if (null promises-list)
      (concur:resolved! '())
    (let* ((total (length promises-list))
           (results (make-vector total nil))
           (aggregate-promise (concur:make-promise))
           (resolved-count 0)
           (lock (concur:make-lock)))
      (--each-indexed
       promises-list
       (lambda (i p)
         (let ((promise (if (concur-promise-p p) p (concur:resolved! p))))
           (concur:then
            promise
            ;; on-resolved:
            (lambda (res)
              (concur:with-mutex! lock
                ;; The check `concur-promise-resolved-p` is functionally
                ;; equivalent to a `settled-p` check in this library.
                (unless (concur-promise-resolved-p aggregate-promise)
                  (aset results i res)
                  (cl-incf resolved-count)
                  (when (= resolved-count total)
                    (concur:resolve aggregate-promise
                                    (cl-coerce results 'list))))))
            ;; on-rejected:
            (lambda (err)
              (concur:with-mutex! lock
                (unless (concur-promise-resolved-p aggregate-promise)
                  (concur:reject aggregate-promise err)))))))
      aggregate-promise))))

;;;###autoload
(defun concur:race (promises-list)
  "Return a promise that resolves or rejects with the first promise to settle.
Once the first promise in `PROMISES-LIST` settles, the returned promise
immediately adopts that state.

Arguments:
- `promises-list`: (list) A list of promises or plain values.

Returns:
- (`concur-promise`) A promise that settles with the value or error
  of the first input promise to settle."
  (let ((race-promise (concur:make-promise))
        (lock (concur:make-lock)))
    (dolist (p promises-list)
      (let ((promise (if (concur-promise-p p) p (concur:resolved! p))))
        (concur:then
         promise
         (lambda (res)
           (concur:with-mutex! lock
             (unless (concur-promise-resolved-p race-promise)
               (concur:resolve race-promise res))))
         (lambda (err)
           (concur:with-mutex! lock
             (unless (concur-promise-resolved-p race-promise)
               (concur:reject race-promise err)))))))
    race-promise))

;;;###autoload
(defun concur:any (promises-list)
  "Return a promise resolving with the first promise to fulfill (resolve).
If all promises reject, the returned promise rejects with an aggregate error.

Arguments:
- `promises-list`: (list) A list of promises or plain values.

Returns:
- (`concur-promise`) A promise that resolves with the value of the
  first promise to resolve. If all reject, it rejects with an
  `aggregate-error` condition."
  (if (null promises-list)
      (concur:rejected! '(aggregate-error "No promises provided"))
    (let* ((total (length promises-list))
           (errors (make-vector total nil))
           (any-promise (concur:make-promise))
           (rejected-count 0)
           (lock (concur:make-lock)))
      (--each-indexed
       promises-list
       (lambda (i p)
         (let ((promise (if (concur-promise-p p) p (concur:resolved! p))))
           (concur:then
            promise
            ;; on-resolved:
            (lambda (res)
              (concur:with-mutex! lock
                (unless (concur-promise-resolved-p any-promise)
                  (concur:resolve any-promise res))))
            ;; on-rejected:
            (lambda (err)
              (concur:with-mutex! lock
                (unless (concur-promise-resolved-p any-promise)
                  (aset errors i err)
                  (cl-incf rejected-count)
                  (when (= rejected-count total)
                    (concur:reject any-promise
                                   `(aggregate-error
                                     "All promises were rejected"
                                     ,(cl-coerce errors 'list)))))))))))
      any-promise)))

;;;###autoload
(defmacro concur:all-settled (promises-list-form)
  "Return a promise that resolves after all promises have settled.
The returned promise *always* resolves with a list of status objects.

Arguments:
- `promises-list-form`: (form) A form that evaluates to a list of promises.

Returns:
- (`concur-promise`) A promise that resolves to a list of status plists.
  Each plist has `:status` ('fulfilled or 'rejected), and either a
  `:value` or `:reason` key."
  (declare (indent 1) (debug t))
  `(let* ((promises (or ,promises-list-form '())))
     (if (null promises)
         (concur:resolved! '())
       (let* ((total (length promises))
              (outcomes (make-vector total nil))
              (aggregate-promise (concur:make-promise))
              (settled-count 0)
              (lock (concur:make-lock)))
         (--each-indexed
          promises
          (lambda (i p)
            (let ((promise (if (concur-promise-p p) p (concur:resolved! p))))
              (concur:finally
               promise
               (lambda ()
                 (concur:with-mutex! lock
                   (unless (>= settled-count total) ; Ensure idempotency
                     (aset outcomes i
                           (if (concur:rejected-p promise)
                               `(:status 'rejected
                                 :reason ,(concur:error-value promise))
                             `(:status 'fulfilled
                               :value ,(concur:value promise))))
                     (cl-incf settled-count)
                     (when (= settled-count total)
                       (concur:resolve aggregate-promise
                                       (cl-coerce outcomes 'list))))))))))
         aggregate-promise))))

;;;###autoload
(defun concur:map-series (items fn)
  "Process ITEMS sequentially with an asynchronous function FN.
Each item is processed only after the promise for the previous item resolves.
This iterative version is safe for very large lists.

Arguments:
- `items`: (list) A list of items to process.
- `fn`: (function) An async function `(item)` that returns a `concur-promise`.

Returns:
- (`concur-promise`) A promise that resolves with an ordered list of
  results. If any call rejects, the chain rejects."
  (let ((results-promise (concur:resolved! '())))
    (dolist (item items)
      (setq results-promise
            (concur:then results-promise
                         (lambda (collected-results)
                           (concur:then (funcall fn item)
                                        (lambda (current-result)
                                          (cons current-result
                                                collected-results)))))))
    ;; The results are built in reverse, so `nreverse` at the end.
    (concur:then results-promise #'nreverse)))

;;;###autoload
(defun concur:map-parallel (items fn)
  "Process ITEMS in parallel with an asynchronous function FN.
All calls to `FN` are initiated concurrently.

Arguments:
- `items`: (list) A list of items to process.
- `fn`: (function) An async function `(item)` that returns a `concur-promise`.

Returns:
- (`concur-promise`) A promise that resolves with a list of results
  (in order) once all operations complete. If any call rejects, the
  returned promise rejects immediately."
  (concur:all (--map (funcall fn it) items)))

(provide 'concur-combinators)
;;; concur-combinators.el ends here