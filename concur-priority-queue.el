;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-priority-queue.el --- Priority Queue for Concurrent Task Scheduling -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides a priority queue implementation based on a binary min-heap.
;; It can be used to manage items based on priority levels, ensuring that
;; high-priority items are processed first according to a defined comparator.
;;
;; Features:
;; - Efficient priority-based retrieval (O(log n) for insert/pop).
;; - Support for dynamic resizing of the underlying heap vector.
;; - Flexible comparator to support min-heap (default) or max-heap.

;;; Code:

(require 'cl-lib) ; For cl-defstruct, cl-incf, cl-decf, cl-rotatef, cl-loop
(require 'concur-log)  ; For concur--log

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures

(eval-and-compile
  (cl-defstruct (concur-priority-queue
                 (:constructor %%make-concur-priority-queue))
    "A binary heap-based priority queue implementation.

  Arguments:
  - `heap` (vector): A vector holding items in heap order. The root
    (highest priority item) is at index 0. Defaults to a new vector.
  - `comparator` (function): A binary function `(fn A B)` that returns non-nil
    if `A` has higher priority than `B`. For a min-heap, this is `<`.
    Defaults to `<`.
  - `len` (integer): The current number of active items in the heap.
    Defaults to 0.
  - `initial-capacity` (integer): The initial size of the heap vector.
    Defaults to 32."
    (heap (make-vector 32 nil) :type vector)
    (comparator #'< :type function)
    (len 0 :type integer)
    (initial-capacity 32 :type integer)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Heap Helper Functions

(defun concur-priority-queue--heapify-up (queue idx)
  "Move the element at IDX up in the heap to maintain the heap property.
This is used after insertion to bubble an item up to its correct position.

  Arguments:
  - `queue` (concur-priority-queue): The priority queue instance.
  - `idx` (integer): The index of the element to move up.

  Returns:
  - `nil` (side-effect: modifies the heap vector)."
  (let ((heap (concur-priority-queue-heap queue))
        (comparator (concur-priority-queue-comparator queue)))
    (catch 'done
      (while (> idx 0)
        (let* ((parent-idx (floor (1- idx) 2))
               (current (aref heap idx))
               (parent (aref heap parent-idx)))
          ;; If parent has higher priority than current, heap property is met.
          (if (funcall comparator parent current)
              (throw 'done nil)
            ;; Otherwise, swap current with parent and continue bubbling up.
            (cl-rotatef (aref heap idx) (aref heap parent-idx))
            (setq idx parent-idx)))))))

(defun concur-priority-queue--heapify-down (queue idx)
  "Move the element at IDX down in the heap to maintain the heap property.
This is used after removal (specifically, moving the last item to the
root) to bubble an item down to its correct position.

  Arguments:
  - `queue` (concur-priority-queue): The priority queue instance.
  - `idx` (integer): The index of the element to move down.

  Returns:
  - `nil` (side-effect: modifies the heap vector)."
  (let ((heap (concur-priority-queue-heap queue))
        (len (concur-priority-queue-len queue))
        (comparator (concur-priority-queue-comparator queue)))
    (catch 'done
      (while t
        (let* ((left (1+ (* 2 idx)))
               (right (1+ left))
               (highest idx)) ; Assume current is highest priority initially.
          ;; Check if left child has higher priority.
          (when (and (< left len) (funcall comparator (aref heap left)
                                           (aref heap highest)))
            (setq highest left))
          ;; Check if right child has higher priority.
          (when (and (< right len) (funcall comparator (aref heap right)
                                            (aref heap highest)))
            (setq highest right))
          ;; If current is still highest priority, heap property is met.
          (if (= highest idx)
              (throw 'done nil)
            ;; Otherwise, swap current with the highest priority child.
            (cl-rotatef (aref heap idx) (aref heap highest))
            (setq idx highest)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(cl-defun concur-priority-queue-create (&key (comparator #'<) (initial-capacity 32))
  "Create and return a new empty `concur-priority-queue`.

  Arguments:
  - `:comparator` (function, optional): A function `(A B)` that returns
    non-nil if A has higher priority than B. Defaults to `<` (a min-heap).
  - `:initial-capacity` (integer, optional): The initial size of the heap
    vector. Must be a positive integer. Defaults to 32.

  Returns:
  - (concur-priority-queue): A new priority queue instance."
  (unless (functionp comparator)
    (user-error "concur-priority-queue-create: :comparator must be a function: %S"
                comparator))
  (unless (and (integerp initial-capacity) (> initial-capacity 0))
    (user-error "concur-priority-queue-create: :initial-capacity must be a \
                 positive integer: %S" initial-capacity))
  (let ((queue (%%make-concur-priority-queue
                :heap (make-vector initial-capacity nil)
                :comparator comparator
                :len 0
                :initial-capacity initial-capacity)))
    (concur--log :debug nil "Created priority queue %S with capacity %d."
                 queue initial-capacity)
    queue))

;;;###autoload
(defsubst concur-priority-queue-length (queue)
  "Return the number of items in the priority QUEUE. O(1) complexity."
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-length: Invalid queue object: %S" queue))
  (concur-priority-queue-len queue))

;;;###autoload
(defsubst concur-priority-queue-empty-p (queue)
  "Return non-nil if the priority QUEUE is empty. O(1) complexity."
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-empty-p: Invalid queue object: %S" queue))
  (zerop (concur-priority-queue-len queue)))

;;;###autoload
(defun concur-priority-queue-insert (queue item)
  "Insert `ITEM` into the priority `QUEUE`. O(log n) complexity.
If the underlying vector is full, it is dynamically resized (doubled).

  Arguments:
  - `QUEUE` (concur-priority-queue): The queue instance.
  - `ITEM` (any): The item to insert.

  Returns:
  - (any): The `ITEM` that was inserted."
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-insert: Invalid queue object: %S" queue))
  (let* ((len (concur-priority-queue-len queue))
         (capacity (length (concur-priority-queue-heap queue))))
    ;; Resize if the heap vector is full.
    (when (>= len capacity)
      (let* ((new-capacity (if (zerop capacity) 32 (* 2 capacity)))
             (new-heap (make-vector new-capacity nil)))
        (dotimes (i len)
          (aset new-heap i (aref (concur-priority-queue-heap queue) i)))
        (setf (concur-priority-queue-heap queue) new-heap)
        (concur--log :debug nil "Priority queue resized to capacity %d."
                     new-capacity))))
  (let ((heap (concur-priority-queue-heap queue))
        (idx (concur-priority-queue-len queue)))
    (aset heap idx item) ; Add item to the end of the heap.
    (cl-incf (concur-priority-queue-len queue))
    (concur-priority-queue--heapify-up queue idx) ; Bubble it up.
    (concur--log :debug nil "Inserted item into priority queue. Length: %d."
                 (concur-priority-queue-len queue))
    item))

;;;###autoload
(defun concur-priority-queue-pop (queue)
  "Pop the highest-priority item from `QUEUE`. O(log n) complexity.

  Arguments:
  - `QUEUE` (concur-priority-queue): The queue instance.

  Returns:
  - (any): The highest-priority item in the queue.

  Signals:
  - `user-error`: If the queue is empty."
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-pop: Invalid queue object: %S" queue))
  (if (concur-priority-queue-empty-p queue)
      (user-error "concur-priority-queue-pop: Priority queue is empty.")
    (let* ((heap (concur-priority-queue-heap queue))
           (len (concur-priority-queue-len queue))
           (top (aref heap 0)) ; Highest priority item is at the root (index 0).
           (new-len (1- len)))
      (aset heap 0 (aref heap new-len)) ; Move last item to root.
      (aset heap new-len nil) ; Clear the old last position.
      (setf (concur-priority-queue-len queue) new-len)
      (when (> new-len 0) ; Only heapify down if there are other elements.
        (concur-priority-queue--heapify-down queue 0))
      (concur--log :debug nil "Popped item from priority queue. Length: %d."
                   (concur-priority-queue-len queue))
      top)))

;;;###autoload
(defun concur-priority-queue-pop-n (queue n)
  "Remove and return the N highest-priority items from `QUEUE`.
The returned list is sorted by priority.

  Arguments:
  - `QUEUE` (concur-priority-queue): The queue instance.
  - `n` (integer): The number of items to remove.

  Returns:
  - (list): A list of the N highest-priority items removed, sorted by priority.

  Signals:
  - `user-error`: If `QUEUE` is not a `concur-priority-queue` or `n` is negative."
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-pop-n: Invalid queue object: %S" queue))
  (unless (and (integerp n) (>= n 0))
    (user-error "concur-priority-queue-pop-n: N must be a non-negative integer: %S" n))
  (let ((count (min n (concur-priority-queue-len queue))))
    (when (> count 0)
      (concur--log :debug nil "Popping %d items from priority queue." count)
      (cl-loop repeat count collect (concur-priority-queue-pop queue)))))

;;;###autoload
(defun concur-priority-queue-peek (queue)
  "Return the highest-priority item from `QUEUE` without removing it. O(1).

  Arguments:
  - `QUEUE` (concur-priority-queue): The queue instance.

  Returns:
  - (any or nil): The highest-priority item, or `nil` if the queue is empty."
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-peek: Invalid queue object: %S" queue))
  (unless (concur-priority-queue-empty-p queue)
    (aref (concur-priority-queue-heap queue) 0)))

;;;###autoload
(cl-defun concur-priority-queue-status (queue)
  "Return a snapshot of the `QUEUE`'s current status.

  Arguments:
  - `QUEUE` (concur-priority-queue): The priority queue instance to inspect.

  Returns:
  - (plist): A property list with queue metrics:
    `:length`: Number of items in the queue.
    `:capacity`: Current allocated capacity of the underlying vector.
    `:comparator`: The comparator function used (symbol).
    `:empty-p`: Whether the queue is empty."
  (interactive)
  (unless (concur-priority-queue-p queue)
    (user-error "concur-priority-queue-status: Invalid queue object: %S" queue))
  `(:length ,(concur-priority-queue-len queue)
    :capacity ,(length (concur-priority-queue-heap queue))
    :comparator ,(concur-priority-queue-comparator queue)
    :empty-p ,(concur-priority-queue-empty-p queue)))

(provide 'concur-priority-queue)
;;; concur-priority-queue.el ends here