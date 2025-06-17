;;; concur-promise-combinators.el --- Combinator functions for Concur Promises
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides functions that operate on collections of promises, allowing
;; for complex asynchronous control flow. It includes standard combinators like
;; `concur:all` (wait for all to succeed), `concur:race` (wait for the first to
;; settle), `concur:any` (wait for the first to succeed), and more.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'concur-promise-core)
(require 'concur-promise-chain)
(require 'concur-ast)

(declare-function concur-ast-analysis "concur-ast")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API - Combinators

(defun concur:all (promises-list)
  "Return a promise that resolves when all promises in PROMISES-LIST resolve.
If any promise in the list rejects, the returned promise immediately rejects
with the reason of the first promise that rejected.

Arguments:
- PROMISES-LIST (list): A list of promises or plain values. Plain values are
  treated as already-resolved promises.

Returns:
A `concur-promise` that resolves with a list of values (in the same order as
PROMISES-LIST) when all inputs resolve, or rejects with the first error."
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
         (let ((promise (if (concur-promise-p p) p (concur:resolved! p)))))
           (concur:then
            promise
            ;; on-resolved:
            (lambda (res)
              ;; Use a mutex to protect shared state from potential race conditions.
              (concur:with-mutex! lock
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
      aggregate-promise)))

(defun concur:race (promises-list)
  "Return a promise that resolves or rejects with the first promise to settle.
Once the first promise in PROMISES-LIST settles (either resolves or
rejects), the returned promise immediately adopts that state.

Arguments:
- PROMISES-LIST (list): A list of promises or plain values.

Returns:
A `concur-promise` that settles with the value or error of the first input
promise to settle."
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

(defun concur:any (promises-list)
  "Return a promise resolving with the first promise to fulfill (resolve).
If all promises in PROMISES-LIST reject, the returned promise rejects with an
aggregate error containing all rejection reasons.

Arguments:
- PROMISES-LIST (list): A list of promises or plain values.

Returns:
A `concur-promise` that resolves with the value of the first promise to
resolve. If all reject, it rejects with an `aggregate-error` condition."
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
(cl-defmacro concur:all-settled (promises-list-form) ; <-- Change from promises-list to promises-list-form
  "Return a promise that resolves after all promises in PROMISES-LIST-FORM settle.
The returned promise *always* resolves with a list of status objects and
never rejects. This is useful when you need to know the outcome of every
promise, regardless of success or failure.

Arguments:
- PROMISES-LIST-FORM (form): A form that evaluates to a list of promises or plain values.

Returns:
A `concur-promise` that resolves to a list of status plists.
Each plist has a `:status` key (`'fulfilled` or `'rejected`), and either a
`:value` key or a `:reason` key."
  (declare (indent 1) (debug t)) ; Added declare for macro
  `(let* ((_promises-list ,promises-list-form)) ; <-- Evaluate the form at runtime
     (if (null _promises-list) (concur:resolved! '())
       (let* ((total (length _promises-list)) ; <-- Operate on the evaluated list
              (outcomes (make-vector total nil))
              (aggregate-promise (concur:make-promise))
              (settled-count 0)
              (lock (concur:make-lock)))
         (--each-indexed
          _promises-list ; <-- Operate on the evaluated list
          (lambda (i p)
            (let ((promise (if (concur-promise-p p) p (concur:resolved! p))))
              (concur:finally
               promise
               (lambda ()
                 (concur:with-mutex! lock
                   (unless (concur-promise-resolved-p aggregate-promise)
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
         
;; (defun concur:all-settled (promises-list)
;;   "Return a promise that resolves after all promises in PROMISES-LIST settle.
;; The returned promise *always* resolves with a list of status objects and
;; never rejects. This is useful when you need to know the outcome of every
;; promise, regardless of success or failure.

;; Arguments:
;; - PROMISES-LIST (list): A list of promises or plain values.

;; Returns:
;; A `concur-promise` that resolves to a list of status plists.
;; Each plist has a `:status` key (`'fulfilled` or `'rejected`), and either a
;; `:value` key or a `:reason` key."
;;   (if (null promises-list) (concur:resolved! '())
;;     (let* ((total (length promises-list))
;;            (outcomes (make-vector total nil))
;;            (aggregate-promise (concur:make-promise))
;;            (settled-count 0)
;;            (lock (concur:make-lock)))
;;       (--each-indexed
;;        promises-list
;;        (lambda (i p)
;;          (let ((promise (if (concur-promise-p p) p (concur:resolved! p))))
;;            (concur:finally
;;             promise
;;             (lambda ()
;;               (concur:with-mutex! lock
;;                 (unless (concur-promise-resolved-p aggregate-promise)
;;                   (aset outcomes i
;;                         (if (concur:rejected-p promise)
;;                             `(:status 'rejected
;;                               :reason ,(concur:error-value promise))
;;                           `(:status 'fulfilled
;;                             :value ,(concur:value promise))))
;;                   (cl-incf settled-count)
;;                   (when (= settled-count total)
;;                     (concur:resolve aggregate-promise
;;                                     (cl-coerce outcomes 'list))))))))))
;;       aggregate-promise)))

(defun concur:map-series (items fn)
  "Process ITEMS sequentially with an asynchronous function FN.
Each item is processed only after the promise returned by `FN` for the
previous item has resolved. This is useful for tasks that must be run in
a specific order without overlap.

Arguments:
- ITEMS (list): A list of items to process.
- FN (function): An async function `(item)` that returns a `concur-promise`.

Returns:
A `concur-promise` that resolves with an ordered list of results once all
items have been processed. If any call rejects, the chain rejects."
  ;; Base case: an empty list of items resolves to an empty list.
  (if (null items)
      (concur:resolved! '())
    ;; Recursive step:
    ;; 1. Process the first item.
    ;; 2. When it's done, recursively process the rest of the items.
    ;; 3. When the rest are done, cons the first result onto their results.
    (concur:then (funcall fn (car items))
                 (lambda (first-res)
                   (concur:then (concur:map-series (cdr items) fn)
                                (lambda (rest-res)
                                  (cons first-res rest-res)))))))

(defun concur:map-parallel (items fn)
  "Process ITEMS in parallel with an asynchronous function FN.
All calls to `FN` are initiated concurrently. The returned promise settles
when all operations have completed.

Arguments:
- ITEMS (list): A list of items to process.
- FN (function): An asynchronous function `(item)` that returns a
  `concur-promise`.

Returns:
A `concur-promise` that resolves with a list of results (in the same order
as ITEMS) once all parallel operations complete. If any call rejects, the
returned promise rejects immediately with the first error."
  ;; This is a concise way to map and then wait for all results.
  (concur:all (--map (funcall fn it) items)))

(provide 'concur-promise-combinators)
;;; concur-promise-combinators.el ends here