;;; concur-priority-queue.el --- Priority Queue for Concurrent Task Scheduling -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a priority queue implementation for concurrent
;; task scheduling, based on a binary min-heap. The priority queue
;; can be used to manage tasks based on their priority levels,
;; ensuring that high-priority tasks are executed before
;; lower-priority ones according to a defined comparator.
;;
;; Functions include task insertion, removal, and priority-based
;; retrieval. The queue is designed to support efficient scheduling
;; and task management for concurrent systems.
;;
;; Features:
;; - Task insertion based on priority level.
;; - Efficient priority-based retrieval (O(log n) for insert/pop).
;; - Support for dynamic resizing of the underlying heap.
;;
;; Usage:
;; The priority queue can be integrated into a larger concurrency
;; system where tasks are scheduled based on their priority. Tasks
;; are represented as items (often structs or plists) and inserted
;; into the queue for processing.
;;
;; Example:
;;   (require 'concur-priority-queue)
;;   (let ((pq (concur-priority-queue-create :comparator #'<))) ; Min-heap
;;     (concur-priority-queue-insert pq 3)
;;     (concur-priority-queue-insert pq 1)
;;     (concur-priority-queue-insert pq 2)
;;     (concur-priority-queue-peek pq)) ; => 1
;;
;;; Code:

(require 'cl-lib)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Struct Definition

(cl-defstruct (concur-priority-queue
               (:constructor nil) ; No default constructor
               (:constructor concur-priority-queue--create
                             (&key heap comparator len initial-capacity))
               (:predicate concur-priority-queue-p))
  "A binary heap-based priority queue implementation.

Fields:
- `heap` (vector): A vector holding the tasks (or items) in heap order.
  The root of the heap (highest priority item) is at index 0.
- `comparator` (function): A binary function `(fn A B)` that returns non-nil
  if `A` has higher priority than `B`. For a min-heap, this is typically `<`;
  for a max-heap, it is `>`.
- `len` (integer): The current number of active items in the heap.
  The heap vector may be larger; items beyond this length are unused.
- `initial-capacity` (integer): The initial allocated size of the heap vector.
  This is used as a base for resizing when the heap becomes full."
  (heap (make-vector 32 nil) :type vector)
  comparator
  (len 0 :type integer)
  (initial-capacity 32 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Heap Helper Functions

(defun concur-priority-queue--heapify-up (heap idx comparator)
  "Move the element at IDX up in HEAP to maintain the heap property.

Arguments:
- HEAP (vector): The heap vector.
- IDX (integer): The index of the element to sift up.
- COMPARATOR (function): The queue's comparator function.

Returns:
- nil. Modifies `HEAP` in-place."
  (catch 'done
    (while (> idx 0)
      (let* ((parent-idx (floor (1- idx) 2))
             (current (aref heap idx))
             (parent (aref heap parent-idx)))
        ;; If the parent has higher (or equal) priority than the current item,
        ;; the heap property is satisfied at this level, and we can stop.
        (if (funcall comparator parent current)
            (throw 'done nil)
          ;; Otherwise, swap the item with its parent and continue sifting up.
          (cl-rotatef (aref heap idx) (aref heap parent-idx))
          (setq idx parent-idx))))))

(defun concur-priority-queue--heapify-down (heap idx len comparator)
  "Move the element at IDX down in HEAP to maintain the heap property.

Arguments:
- HEAP (vector): The heap vector.
- IDX (integer): The index of the element to sift down.
- LEN (integer): The current active length of the heap.
- COMPARATOR (function): The queue's comparator function.

Returns:
- nil. Modifies `HEAP` in-place."
  (catch 'done
    (while t
      (let* ((left-child-idx (1+ (* 2 idx)))
             (right-child-idx (1+ left-child-idx))
             ;; Assume the current node has the highest priority for now.
             (highest_priority_idx idx))
        ;; Find the actual highest priority element among the node and its children.
        (when (and (< left-child-idx len)
                   (funcall comparator (aref heap left-child-idx) (aref heap highest_priority_idx)))
          (setq highest_priority_idx left-child-idx))
        (when (and (< right-child-idx len)
                   (funcall comparator (aref heap right-child-idx) (aref heap highest_priority_idx)))
          (setq highest_priority_idx right-child-idx))

        ;; If the current node is already the highest priority, we are done.
        (if (= highest_priority_idx idx)
            (throw 'done nil)
          ;; Otherwise, swap with the highest-priority child and continue sifting down.
          (cl-rotatef (aref heap idx) (aref heap highest_priority_idx))
          (setq idx highest_priority_idx))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Constructors and Basic Accessors

;;;###autoload
(cl-defun concur-priority-queue-create (&key comparator initial-capacity)
  "Create and return a new empty `concur-priority-queue`.

Arguments:
- `comparator` (function, optional): A function of two arguments `(A B)`
  that returns non-nil if `A` should be ordered before (has higher
  priority than) `B`. Defaults to `<` (creating a min-heap).
- `initial-capacity` (integer, optional): The initial size of the heap
  vector. Defaults to 32.

Returns:
- (`concur-priority-queue`): A new `concur-priority-queue` instance.

Example:
  (concur-priority-queue-create :comparator #'>) ; Creates a max-heap
  (concur-priority-queue-create) ; Creates a min-heap by default"
  (let ((capacity (or initial-capacity 32)))
    (concur-priority-queue--create
     :heap (make-vector capacity nil)
     :comparator (or comparator #'<)
     :len 0
     :initial-capacity capacity)))

;;;###autoload
(defsubst concur-priority-queue-length (queue)
  "Return the number of items in the priority QUEUE.

Arguments:
- `queue` (`concur-priority-queue`): The priority queue instance.

Returns:
- (integer): The number of items in the queue."
  (concur-priority-queue-len queue))

;;;###autoload
(defsubst concur-priority-queue-empty-p (queue)
  "Return non-nil if the priority QUEUE is empty.

Arguments:
- `queue` (`concur-priority-queue`): The priority queue instance.

Returns:
- (boolean): `t` if the queue is empty, nil otherwise."
  (= 0 (concur-priority-queue-len queue)))

;;;###autoload
(defun concur-priority-queue-clear (queue)
  "Clear all items from the priority QUEUE.

This resets the queue to its initial empty state but preserves its
initial capacity and comparator.

Arguments:
- `queue` (`concur-priority-queue`): The priority queue instance.

Returns:
- nil. Modifies the queue in-place."
  (setf (concur-priority-queue-heap queue)
        (make-vector (concur-priority-queue-initial-capacity queue) nil))
  (setf (concur-priority-queue-len queue) 0))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Core Queue Operations

;;;###autoload
(defun concur-priority-queue-insert (queue item)
  "Insert `ITEM` into the priority `QUEUE`.

The item is inserted at the end of the heap, and then `heapify-up`
is called to maintain the heap property. If the underlying vector
is full, it is resized to double its current capacity.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.
- `item` (any): The item to insert.

Returns:
- nil. Modifies the queue in-place."
  (let* ((old-heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (capacity (length old-heap)))
    ;; Check if resizing is needed.
    (when (>= len capacity)
      (let* ((new-capacity (if (zerop capacity) 32 (* 2 capacity)))
             (new-heap (make-vector new-capacity nil)))
        ;; Copy old elements to the new, larger heap.
        (dotimes (i len) (aset new-heap i (aref old-heap i)))
        (setf (concur-priority-queue-heap queue) new-heap)))
    ;; Now, perform the insertion.
    (let ((heap (concur-priority-queue-heap queue)))
      (aset heap len item) ; Place new item at the end.
      (cl-incf (concur-priority-queue-len queue)) ; Increment length.
      ;; Restore heap property by sifting the new item up.
      (concur-priority-queue--heapify-up heap len (concur-priority-queue-comparator queue)))))

;;;###autoload
(defun concur-priority-queue-pop (queue)
  "Pop the highest-priority item from `QUEUE` and return it.

The highest-priority item (the root of the heap) is removed.
The last item in the heap is moved to the root, and then `heapify-down`
is called from the root to restore the heap property.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.

Returns:
- (any): The highest-priority item in the queue.

Signals:
- (error): If the queue is empty."
  (if (concur-priority-queue-empty-p queue)
      (error "Priority queue is empty")
    (let* ((heap (concur-priority-queue-heap queue))
           (len (concur-priority-queue-len queue))
           (top (aref heap 0))
           (new-len (1- len)))
      ;; Move the last item to the root.
      (aset heap 0 (aref heap new-len))
      (aset heap new-len nil) ; Clear the old last position for GC.
      (setf (concur-priority-queue-len queue) new-len)
      ;; Restore heap property from the root if the queue is not empty.
      (when (> new-len 0)
        (concur-priority-queue--heapify-down
         heap 0 new-len
         (concur-priority-queue-comparator queue)))
      top)))

;;;###autoload
(defun concur-priority-queue-pop-n (queue n)
  "Remove and return the N highest-priority tasks from the `QUEUE`.

This function repeatedly calls `concur-priority-queue-pop` N times.
If N is greater than the number of items currently in the queue,
all remaining items are removed and returned.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.
- `n` (integer): The number of items to remove.

Returns:
- (list): A list of the N highest-priority items removed, sorted from
  highest priority to lowest. Returns an empty list if the queue is
  empty or `n` is non-positive."
  (when (and (> n 0) (not (concur-priority-queue-empty-p queue)))
    (let* ((len (concur-priority-queue-len queue))
           (num-to-remove (min n len))
           (popped-items '()))
      (dotimes (_ num-to-remove)
        (push (concur-priority-queue-pop queue) popped-items))
      (nreverse popped-items))))

;;;###autoload
(defun concur-priority-queue-remove (queue item)
  "Remove the first occurrence of `ITEM` from the priority `QUEUE`.

This operation has a time complexity of O(n) due to the search for the
item, followed by an O(log n) heap adjustment.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.
- `item` (any): The item to remove. Comparison is done using `equal`.

Returns:
- (boolean): `t` if the item was found and removed, nil otherwise."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (index (cl-position item heap :test #'equal :end len)))
    (when index
      (let* ((last-idx (1- len))
             (last-item (aref heap last-idx))
             (comparator (concur-priority-queue-comparator queue)))
        ;; Replace the item to be removed with the last item in the heap.
        (aset heap index last-item)
        (aset heap last-idx nil)
        (setf (concur-priority-queue-len queue) last-idx)
        ;; The moved item might need to be sifted up or down to restore the heap property.
        (when (< index last-idx)
          ;; If the moved item is higher priority than its new parent, sift up.
          (if (and (> index 0)
                   (funcall comparator (aref heap index) (aref heap (floor (1- index) 2))))
              (concur-priority-queue--heapify-up heap index comparator)
            ;; Otherwise, sift it down.
            (concur-priority-queue--heapify-down heap index last-idx comparator)))
        t))))

;;;###autoload
(defun concur-priority-queue-update (queue item new-priority-item)
  "Update the priority of `ITEM` in the `QUEUE` to `NEW-PRIORITY-ITEM`.

This finds `ITEM`, replaces it with `NEW-PRIORITY-ITEM`, and re-heapifies.
This operation is O(n) due to the search.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.
- `item` (any): The item whose priority should be updated. Comparison is
  done using `equal`.
- `new-priority-item` (any): The new item that represents the updated priority.
  This is used directly as the new item in the heap.

Returns:
- (boolean): `t` if the item was found and updated, nil otherwise."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (index (cl-position item heap :test #'equal :end len)))
    (when index
      (let ((comparator (concur-priority-queue-comparator queue))
            (old-item (aref heap index)))
        ;; Update the item in-place.
        (aset heap index new-priority-item)
        ;; Re-heapify based on whether the new priority is higher or lower.
        (if (funcall comparator new-priority-item old-item)
            ;; New priority is higher (e.g., smaller number), sift up.
            (concur-priority-queue--heapify-up heap index comparator)
          ;; New priority is lower or the same, sift down.
          (concur-priority-queue--heapify-down heap index len comparator)))
      t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Utility Operations

;;;###autoload
(defun concur-priority-queue-peek (queue)
  "Return the highest-priority item from `QUEUE` without removing it.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.

Returns:
- (any or nil): The highest-priority item, or nil if the queue is empty."
  (if (concur-priority-queue-empty-p queue)
      nil
    (aref (concur-priority-queue-heap queue) 0)))

;;;###autoload
(defun concur-priority-queue-peek-n (queue n)
  "Return the N highest-priority items from `QUEUE` without removing them.
The returned list is not guaranteed to be sorted.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.
- `n` (integer): The number of items to peek.

Returns:
- (list): A list of up to N items. Returns an empty list if the
  queue is empty or `n` is non-positive."
  (if (or (<= n 0) (concur-priority-queue-empty-p queue))
      '()
    (cl-subseq (concur-priority-queue-heap queue)
               0 (min n (concur-priority-queue-len queue)))))

;;;###autoload
(defun concur-priority-queue-get-all (queue)
  "Return all items in the priority `QUEUE`, sorted by priority.

This function creates a new sorted list of all items. It does not
modify the queue itself.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.

Returns:
- (list): A list of all items, sorted from highest priority to lowest."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    (if (zerop len)
        '()
      (sort (cl-subseq heap 0 len) (concur-priority-queue-comparator queue)))))

;;;###autoload
(defun concur-priority-queue-iter (queue func)
  "Iterate over each item in the `QUEUE`, applying `FUNC`.
The items are visited in heap order, not priority order.

Arguments:
- `queue` (`concur-priority-queue`): The queue instance.
- `func` (function): A function of one argument to call on each item.

Returns:
- nil."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    (dotimes (i len)
      (funcall func (aref heap i)))))

(provide 'concur-priority-queue)
;;; concur-priority-queue.el ends here