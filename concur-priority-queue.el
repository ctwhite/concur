;;; concur-priority-queue.el --- Thread-Safe Priority Queue -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a thread-safe priority queue implementation based on a
;; binary min-heap. It is designed to manage items based on priority levels,
;; ensuring that high-priority items are processed first according to a
;; user-defined comparator.
;;
;; Features:
;; - Efficient priority-based retrieval (O(log n) for insert/pop).
;; - Thread-safe operations via an internal mutex.
;; - Support for removing arbitrary items (O(n) search + O(log n) removal).
;; - Flexible comparator to support min-heaps (default) or max-heaps.

;;; Code:

(require 'cl-lib)
(require 'concur-lock)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:make-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-priority-queue-error
  "A generic error related to a priority queue."
  'concur-error)

(define-error 'concur-invalid-priority-queue-error
  "An operation was attempted on an invalid priority queue object."
  'concur-priority-queue-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-priority-queue (:constructor %%make-priority-queue))
  "A binary heap-based, thread-safe priority queue.

Fields:
- `heap` (vector): A vector holding items in heap order.
- `lock` (concur-lock): A mutex protecting all heap operations.
- `comparator` (function): A function `(A B)` returning non-nil if A has
  higher priority than B. For a min-heap, this is `<`.
- `len` (integer): The current number of items in the heap."
  (heap (make-vector 32 nil) :type vector)
  (lock (concur:make-lock) :type concur-lock-p)
  (comparator #'< :type function)
  (len 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-queue (queue function-name)
  "Signal an error if QUEUE is not a `concur-priority-queue`.

Arguments:
- `QUEUE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not valid.
"
  (unless (eq (type-of queue) 'concur-priority-queue)
    (signal 'concur-invalid-priority-queue-error
            (list (format "%s: Invalid queue object" function-name) queue))))

(defun concur--priority-queue-heapify-up (queue idx)
  "Move the element at `IDX` up to maintain the heap property.
This must be called from within a locked context.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue.
- `IDX` (integer): The index of the element to heapify up.
"
  (let ((heap (concur-priority-queue-heap queue))
        (comparator (concur-priority-queue-comparator queue)))
    (catch 'done
      (while (> idx 0)
        (let* ((parent-idx (floor (1- idx) 2))
               (current (aref heap idx))
               (parent (aref heap parent-idx)))
          (if (funcall comparator parent current) (throw 'done nil)
            (cl-rotatef (aref heap idx) (aref heap parent-idx))
            (setq idx parent-idx)))))))

(defun concur--priority-queue-heapify-down (queue idx)
  "Move the element at `IDX` down to maintain the heap property.
This must be called from within a locked context.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue.
- `IDX` (integer): The index of the element to heapify down.
"
  (let ((heap (concur-priority-queue-heap queue))
        (len (concur-priority-queue-len queue))
        (comparator (concur-priority-queue-comparator queue)))
    (catch 'done
      (while t
        (let* ((left (1+ (* 2 idx)))
               (right (1+ left))
               (highest idx))
          (when (and (< left len) (funcall comparator (aref heap left)
                                           (aref heap highest)))
            (setq highest left))
          (when (and (< right len) (funcall comparator (aref heap right)
                                            (aref heap highest)))
            (setq highest right))
          (if (= highest idx) (throw 'done nil)
            (cl-rotatef (aref heap idx) (aref heap highest))
            (setq idx highest)))))))

(defun concur--priority-queue-pop-internal (queue)
  "Non-locking version of `pop` for internal use.
This must be called from within a context that already holds the lock.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue.

Returns:
- (any): The highest-priority item.

Signals:
- `error` if the queue is empty.
"
  (if (zerop (concur-priority-queue-len queue))
      (error "Cannot pop from an empty priority queue")
    (let* ((heap (concur-priority-queue-heap queue))
           (top (aref heap 0))
           (new-len (1- (concur-priority-queue-len queue))))
      (aset heap 0 (aref heap new-len))
      (aset heap new-len nil)
      (setf (concur-priority-queue-len queue) new-len)
      (when (> new-len 0)
        (concur--priority-queue-heapify-down queue 0))
      top)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur-priority-queue-create (&key (comparator #'<) (initial-capacity 32))
  "Create and return a new empty, thread-safe `concur-priority-queue`.

Arguments:
- `:COMPARATOR` (function, optional): A function `(A B)` that returns non-nil
  if A has higher priority than B. Defaults to `<` (a min-heap).
- `:INITIAL-CAPACITY` (integer, optional): The initial size of the internal
  heap vector. Defaults to 32.

Returns:
- `(concur-priority-queue)`: A new priority queue instance.

Signals:
- `error` if `COMPARATOR` is not a function or `INITIAL-CAPACITY` is not a
  positive integer.
"
  (unless (functionp comparator) (error "Comparator must be a function"))
  (unless (and (integerp initial-capacity) (> initial-capacity 0))
    (error "Initial capacity must be a positive integer"))
  (let* ((name (format "pq-lock-%S" (gensym)))
         (queue (%%make-priority-queue
                 :heap (make-vector initial-capacity nil)
                 :comparator comparator
                 :lock (concur:make-lock name))))
    (concur-log :debug nil "Created priority queue with capacity %d."
                 initial-capacity)
    queue))

;;;###autoload
(defsubst concur:priority-queue-length (queue)
  "Return the number of items in the priority `QUEUE`. O(1) complexity.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to inspect.

Returns:
- (integer): The number of items in the queue.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
"
  (concur--validate-queue queue 'concur:priority-queue-length)
  (concur-priority-queue-len queue))

;;;###autoload
(defsubst concur:priority-queue-empty-p (queue)
  "Return non-nil if the priority `QUEUE` is empty. O(1) complexity.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to inspect.

Returns:
- (boolean): `t` if the queue is empty, `nil` otherwise.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
"
  (concur--validate-queue queue 'concur:priority-queue-empty-p)
  (zerop (concur-priority-queue-len queue)))

;;;###autoload
(defun concur:priority-queue-insert (queue item)
  "Insert `ITEM` into the priority `QUEUE`. O(log n) complexity.
The internal heap array will automatically resize if capacity is exceeded.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to insert into.
- `ITEM` (any): The item to insert.

Returns:
- `ITEM`: The item that was inserted.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
"
  (concur--validate-queue queue 'concur:priority-queue-insert)
  (concur:with-mutex! (concur-priority-queue-lock queue)
    (let* ((len (concur-priority-queue-len queue))
           (capacity (length (concur-priority-queue-heap queue)))
           (heap (concur-priority-queue-heap queue)))
      (when (>= len capacity)
        (let* ((new-capacity (if (zerop capacity) 32 (* 2 capacity)))
               (new-heap (make-vector new-capacity nil)))
          (dotimes (i len) (aset new-heap i (aref heap i)))
          (setq heap (setf (concur-priority-queue-heap queue) new-heap))
          (concur-log :debug nil "Priority queue resized to %d." new-capacity)))
      (let ((idx len))
        (aset heap idx item)
        (cl-incf (concur-priority-queue-len queue))
        (concur--priority-queue-heapify-up queue idx))))
  item)

;;;###autoload
(defun concur:priority-queue-peek (queue)
  "Return the highest-priority item from `QUEUE` without removing it. O(1) complexity.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to inspect.

Returns:
- (any or nil): The highest-priority item, or `nil` if the queue is empty.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
"
  (concur--validate-queue queue 'concur:priority-queue-peek)
  (concur:with-mutex! (concur-priority-queue-lock queue)
    (unless (concur:priority-queue-empty-p queue)
      (aref (concur-priority-queue-heap queue) 0))))

;;;###autoload
(defun concur:priority-queue-pop (queue)
  "Pop (remove and return) the highest-priority item from `QUEUE`. O(log n) complexity.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to pop from.

Returns:
- (any): The highest-priority item.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
- `error` if the queue is empty.
"
  (concur--validate-queue queue 'concur:priority-queue-pop)
  (concur:with-mutex! (concur-priority-queue-lock queue)
    (concur--priority-queue-pop-internal queue)))

;;;###autoload
(defun concur:priority-queue-pop-n (queue n)
  "Remove and return the `N` highest-priority items from `QUEUE`.
Items are returned in priority order.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to pop from.
- `N` (integer): The number of items to pop. Must be non-negative.

Returns:
- (list): A list of the `N` highest-priority items, or fewer if the queue
  contains less than `N` items. Returns `nil` if `N` is 0 or the queue is empty.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
- `error` if `N` is not a non-negative integer.
"
  (concur--validate-queue queue 'concur:priority-queue-pop-n)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (concur:with-mutex! (concur-priority-queue-lock queue)
    (let ((count (min n (concur:priority-queue-length queue))))
      (when (> count 0)
        (cl-loop repeat count collect (concur--priority-queue-pop-internal queue))))))

;;;###autoload
(cl-defun concur:priority-queue-remove (queue item &key (test #'eql))
  "Remove `ITEM` from the priority `QUEUE`. O(n) search + O(log n) removal.
This operation requires searching for the item before removal, hence the O(n) part.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to remove from.
- `ITEM` (any): The item to remove.
- `:TEST` (function, optional): A predicate `(element target-item)` used
  to compare items for equality. Defaults to `eql`.

Returns:
- (boolean): `t` if the item was found and removed, `nil` otherwise.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
"
  (concur--validate-queue queue 'concur:priority-queue-remove)
  (concur:with-mutex! (concur-priority-queue-lock queue)
    (let* ((heap (concur-priority-queue-heap queue))
           (len (concur-priority-queue-len queue))
           (idx (cl-position item heap :end len :test test)))
      (when idx
        (let ((last-idx (1- len)))
          (aset heap idx (aref heap last-idx))
          (aset heap last-idx nil)
          (cl-decf (concur-priority-queue-len queue))
          (when (< idx (1- len))
            (let ((parent-idx (floor (1- idx) 2)))
              ;; Check if heap property is violated upwards or downwards
              (if (and (> idx 0)
                       (funcall (concur-priority-queue-comparator queue)
                                (aref heap idx)
                                (aref heap parent-idx)))
                  (concur--priority-queue-heapify-up queue idx)
                (concur--priority-queue-heapify-down queue idx)))))
        t))))

;;;###autoload
(defun concur:priority-queue-status (queue)
  "Return a snapshot of the `QUEUE`'s current status. O(1) complexity.
This function is `interactive` for easy inspection during development.

Arguments:
- `QUEUE` (concur-priority-queue): The priority queue to inspect.

Returns:
- (plist): A property list containing:
    - `:length` (integer): The current number of items.
    - `:capacity` (integer): The total allocated capacity of the internal heap.
    - `:is-empty` (boolean): `t` if the queue contains no items.

Signals:
- `concur-invalid-priority-queue-error` if `QUEUE` is not a valid object.
"
  (interactive)
  (concur--validate-queue queue 'concur:priority-queue-status)
  (concur:with-mutex! (concur-priority-queue-lock queue)
    `(:length ,(concur-priority-queue-len queue)
      :capacity ,(length (concur-priority-queue-heap queue))
      :is-empty ,(concur:priority-queue-empty-p queue))))

(provide 'concur-priority-queue)
;;; concur-priority-queue.el ends here