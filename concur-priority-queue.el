;;; concur-priority-queue.el --- Priority Queue for Concurrent Task Scheduling -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a priority queue implementation based on a binary min-heap.
;; It can be used to manage items based on priority levels, ensuring that
;; high-priority items are processed first according to a defined comparator.
;;
;; Features:
;; - Efficient priority-based retrieval (O(log n) for insert/pop).
;; - Support for dynamic resizing of the underlying heap vector.
;;
;; Example:
;; (let ((pq (concur-priority-queue-create :comparator #'<))) ; Min-heap
;;   (concur-priority-queue-insert pq 3)
;;   (concur-priority-queue-insert pq 1)
;;   (concur-priority-queue-peek pq)) ; => 1

;;; Code:

(require 'cl-lib)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (concur-priority-queue
               (:constructor %%make-concur-priority-queue))
  "A binary heap-based priority queue implementation.

Fields:
- `heap` (vector): A vector holding items in heap order. The root
  (highest priority item) is at index 0.
- `comparator` (function): A binary function `(fn A B)` that returns non-nil
  if `A` has higher priority than `B`. For a min-heap, this is `<`.
- `len` (integer): The current number of active items in the heap.
- `initial-capacity` (integer): The initial size of the heap vector."
  (heap (make-vector 32 nil) :type vector)
  (comparator #'< :type function)
  (len 0 :type integer)
  (initial-capacity 32 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Heap Helper Functions

(defun concur-priority-queue--heapify-up (queue idx)
  "Move the element at IDX up in the heap to maintain the heap property."
  (let ((heap (concur-priority-queue-heap queue))
        (comparator (concur-priority-queue-comparator queue)))
    (catch 'done
      (while (> idx 0)
        (let* ((parent-idx (floor (1- idx) 2))
               (current (aref heap idx))
               (parent (aref heap parent-idx)))
          (if (funcall comparator parent current)
              (throw 'done nil)
            (cl-rotatef (aref heap idx) (aref heap parent-idx))
            (setq idx parent-idx)))))))

(defun concur-priority-queue--heapify-down (queue idx)
  "Move the element at IDX down in the heap to maintain the heap property."
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
          (if (= highest idx)
              (throw 'done nil)
            (cl-rotatef (aref heap idx) (aref heap highest))
            (setq idx highest)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur-priority-queue-create (&key (comparator #'<) (initial-capacity 32))
  "Create and return a new empty `concur-priority-queue`.

Arguments:
- `:comparator` (function, optional): A function `(A B)` that returns
  non-nil if A has higher priority than B. Defaults to `<` (a min-heap).
- `:initial-capacity` (integer, optional): The initial size of the heap vector.

Returns:
  (concur-priority-queue) A new priority queue instance."
  (%%make-concur-priority-queue
   :heap (make-vector initial-capacity nil)
   :comparator comparator
   :len 0
   :initial-capacity initial-capacity))

;;;###autoload
(defsubst concur-priority-queue-length (queue)
  "Return the number of items in the priority QUEUE. O(1) complexity."
  (concur-priority-queue-len queue))

;;;###autoload
(defsubst concur-priority-queue-empty-p (queue)
  "Return non-nil if the priority QUEUE is empty."
  (zerop (concur-priority-queue-len queue)))

;;;###autoload
(defun concur-priority-queue-insert (queue item)
  "Insert `ITEM` into the priority `QUEUE`. O(log n) complexity.
If the underlying vector is full, it is resized.

Arguments:
- `QUEUE` (concur-priority-queue): The queue instance.
- `ITEM` (any): The item to insert.

Returns:
  The `ITEM` that was inserted."
  (let* ((len (concur-priority-queue-len queue))
         (capacity (length (concur-priority-queue-heap queue))))
    (when (>= len capacity)
      (let* ((new-capacity (if (zerop capacity) 32 (* 2 capacity)))
             (new-heap (make-vector new-capacity nil)))
        (dotimes (i len) (aset new-heap i
                               (aref (concur-priority-queue-heap queue) i)))
        (setf (concur-priority-queue-heap queue) new-heap))))
  (let ((heap (concur-priority-queue-heap queue))
        (idx (concur-priority-queue-len queue)))
    (aset heap idx item)
    (cl-incf (concur-priority-queue-len queue))
    (concur-priority-queue--heapify-up queue idx)
    item))

;;;###autoload
(defun concur-priority-queue-pop (queue)
  "Pop the highest-priority item from `QUEUE`. O(log n) complexity.

Arguments:
- `QUEUE` (concur-priority-queue): The queue instance.

Returns:
  (any) The highest-priority item in the queue. Signals an error if empty."
  (if (concur-priority-queue-empty-p queue)
      (error "Priority queue is empty")
    (let* ((heap (concur-priority-queue-heap queue))
           (len (concur-priority-queue-len queue))
           (top (aref heap 0))
           (new-len (1- len)))
      (aset heap 0 (aref heap new-len))
      (aset heap new-len nil)
      (setf (concur-priority-queue-len queue) new-len)
      (when (> new-len 0)
        (concur-priority-queue--heapify-down queue 0))
      top)))

;;;###autoload
(defun concur-priority-queue-pop-n (queue n)
  "Remove and return the N highest-priority items from `QUEUE`.

Arguments:
- `QUEUE` (concur-priority-queue): The queue instance.
- `n` (integer): The number of items to remove.

Returns:
  (list) A list of the N highest-priority items removed, sorted by priority."
  (let ((count (min n (concur-priority-queue-len queue))))
    (when (> count 0)
      (cl-loop repeat count collect (concur-priority-queue-pop queue)))))

;;;###autoload
(defun concur-priority-queue-peek (queue)
  "Return the highest-priority item from `QUEUE` without removing it. O(1).

Arguments:
- `QUEUE` (concur-priority-queue): The queue instance.

Returns:
  (any or nil) The highest-priority item, or `nil` if the queue is empty."
  (unless (concur-priority-queue-empty-p queue)
    (aref (concur-priority-queue-heap queue) 0)))

(provide 'concur-priority-queue)
;;; concur-priority-queue.el ends here