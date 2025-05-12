;;; concur-priority-queue.el --- Priority queues for concurrent tasks

(require 'cl-lib)
(require 'dash)

(cl-defstruct (concur-priority-queue (:constructor make-concur-priority-queue))
  "A binary heap-based priority queue.

Fields:
  - heap: A vector holding the tasks (or items) in heap order.
  - comparator: A binary function to compare priorities.
  - len: The number of active items in the heap."
  heap
  comparator
  len)

;;;###autoload
(defun concur-priority-queue-create (&optional comparator initial-capacity)
  "Create and return a new empty `concur-priority-queue`.

- COMPARATOR is a function of two arguments A and B, returning non-nil if A
  should be ordered before B. Defaults to `<`.
- INITIAL-CAPACITY is the initial size of the heap vector. Defaults to 32."
  (make-concur-priority-queue
   :heap (make-vector (or initial-capacity 32) nil)
   :comparator (or comparator #'<)
   :len 0))

;;;###autoload
(defun concur-priority-queue-insert (queue item)
  "Insert ITEM into the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    ;; Resize vector if necessary
    (when (>= len (length heap))
      (setf (concur-priority-queue-heap queue)
            (vconcat heap (make-vector (max 1 (length heap)) nil))))

    ;; Insert item and increment length
    (aset heap len item)
    (setf (concur-priority-queue-len queue) (1+ len))
    
    ;; Maintain heap property
    (concur-priority-queue--heapify-up heap len (concur-priority-queue-comparator queue))))

;;;###autoload
(defun concur-priority-queue-pop (queue)
  "Pop the highest-priority item from QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    (if (zerop len)
        nil
      (let* ((top (aref heap 0))
             (last (aref heap (1- len))))
        ;; Swap last item to the root
        (aset heap 0 last)
        (aset heap (1- len) nil)
        (setf (concur-priority-queue-len queue) (1- len))
        
        ;; Re-heapify after pop
        (concur-priority-queue--heapify-down heap 0 (concur-priority-queue-comparator queue))
        top))))

;;;###autoload
(defun concur-priority-queue-pop-n (queue n)
  "Remove the N least-priority tasks from the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (num-to-remove (min n len)))
    (when (> num-to-remove 0)
      ;; Pop the N least-priority items by repeatedly popping
      (dotimes (_ num-to-remove)
        (concur-priority-queue-pop queue)))))

;;;###autoload
(defun concur-priority-queue-remove (queue item)
  "Remove the ITEM from the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (index (cl-position item heap :test 'equal))) ;; Find index of item
    (when index
      (let ((last (aref heap (1- len))))
        ;; Swap with last element and remove it
        (aset heap index last)
        (aset heap (1- len) nil)
        (setf (concur-priority-queue-len queue) (1- len))
        (concur--heapify-down heap index (concur-priority-queue-comparator queue))
        (concur--heapify-up heap index (concur-priority-queue-comparator queue))))))

;;;###autoload
(defun concur-priority-queue-remove-lowest-priority (queue n)
  "Remove the N least-priority items from the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (num-to-remove (min n len)))
    (when (> num-to-remove 0)
      ;; Instead of popping from the end repeatedly, we will directly clear the
      ;; smallest elements towards the bottom of the heap.
      (dotimes (_ num-to-remove)
        (let* ((idx (- len 1))
               (item (aref heap idx)))
          ;; Remove the item by setting it to nil and adjusting the queue
          (aset heap idx nil)
          (setf (concur-priority-queue-len queue) (1- len))
          ;; Restore the heap property after removal
          (concur--heapify-down heap idx (concur-priority-queue-comparator queue)))))))

;;;###autoload
(defun concur-priority-queue-update-priority (queue item new-priority)
  "Update the priority of an ITEM in the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (index (cl-position item heap :test 'equal))) ;; Find the index of the item
    (when index
      (aset heap index new-priority)
      ;; Re-heapify based on the new priority
      (concur--heapify-up heap index (concur-priority-queue-comparator queue))
      (concur--heapify-down heap index (concur-priority-queue-comparator queue)))))

;;;###autoload
(defun concur-priority-queue-clear (queue)
  "Clear all tasks from the priority QUEUE."
  (setf (concur-priority-queue-heap queue) (make-vector 32 nil))
  (setf (concur-priority-queue-len queue) 0))

;;;###autoload
(defun concur-priority-queue-peek-n (queue n)
  "Return the highest-priority N items from the QUEUE without removing them."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (min n (concur-priority-queue-len queue))))
    (cl-subseq heap 0 len)))

;;;###autoload
(defun concur-priority-queue-get-all (queue)
  "Return all tasks in the priority QUEUE, sorted by priority."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    (sort (copy-sequence heap)
          (concur-priority-queue-comparator queue))))

;;;###autoload
(defun concur-priority-queue-iter (queue func)
  "Iterate over each item in the priority QUEUE, applying FUNC."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    (--each heap (funcall func it))))

;;;###autoload
(defsubst concur-priority-queue-length (queue)
  "Return non-nil if the priority QUEUE is empty."
  (concur-priority-queue-len queue))

;;;###autoload
(defsubst concur-priority-queue-empty-p (queue)
  "Return non-nil if the priority QUEUE is empty."
  (= 0 (concur-priority-queue-len queue)))

;;;###autoload
(defun concur-priority-queue-peek (queue)
  "Return the highest-priority item from QUEUE without removing it."
  (unless (concur-priority-queue-empty-p queue)
    (aref (concur-priority-queue-heap queue) 0)))

(defun concur-priority-queue--heapify-up (heap idx comparator)
  "Move the element at IDX up in HEAP using COMPARATOR."
  (while (> idx 0)
    (let* ((parent-idx (floor (1- idx) 2))
           (current (aref heap idx))
           (parent (aref heap parent-idx)))
      (when (funcall comparator parent current)
        (cl-rotatef (aref heap idx) (aref heap parent-idx))
        (setq idx parent-idx))
      (unless (funcall comparator parent current)
        (cl-return)))))

(defun concur-priority-queue--heapify-down (heap idx comparator)
  "Move the element at IDX down in HEAP using COMPARATOR."
  (let ((size (length heap)))
    (while t
      (let* ((left (* 2 idx 1))
             (right (1+ left))
             (largest idx))
        (when (and (< left size)
                   (funcall comparator (aref heap largest) (aref heap left)))
          (setq largest left))
        (when (and (< right size)
                   (funcall comparator (aref heap largest) (aref heap right)))
          (setq largest right))
        (if (= largest idx)
            (cl-return)
          (cl-rotatef (aref heap idx) (aref heap largest))
          (setq idx largest))))))

(provide 'concur-priority-queue)
;;; concur-priority-queue.el ends here