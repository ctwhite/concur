;;; concur-priority-queue.el --- Priority Queue for Concurrent Task Scheduling -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; This file provides a priority queue implementation for concurrent task scheduling.
;; The priority queue can be used to manage tasks based on their priority levels,
;; ensuring that high-priority tasks are executed before lower-priority ones.
;;
;; Functions include task insertion, removal, and priority-based retrieval. The
;; queue is designed to support efficient scheduling and task management for the
;; concur scheduler system.
;;
;; Features:
;; - Task insertion based on priority level
;; - Efficient priority-based retrieval
;; - Support for task cancellation and asynchronous processing
;;
;; Usage:
;; The priority queue can be integrated into a larger concurrency system where
;; tasks are scheduled based on their priority. Tasks are represented as structs
;; and inserted into the queue for processing.
;;
;;; Code:

(require 'cl-lib)
(require 'ht)
(require 'dash)
(require 'scribe)

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
(cl-defun concur-priority-queue-create (&key comparator initial-capacity)
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
  (let* ((old-heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (heap (if (>= len (length old-heap))
                   ;; Resize heap and update queue
                   (let ((new-heap (vconcat old-heap (make-vector (max 1 (length old-heap)) nil))))
                     (setf (concur-priority-queue-heap queue) new-heap)
                     new-heap)
                 old-heap)))
    ;; Insert item
    (aset heap len item)
    (setf (concur-priority-queue-len queue) (1+ len))

    ;; Re-heapify
    (concur-priority-queue--heapify-up heap len (concur-priority-queue-comparator queue))))

;;;###autoload
(defun concur-priority-queue-pop (queue)
  "Pop the highest-priority item from QUEUE."
  (log! "concur-priority-queue-pop")
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue)))
    (if (zerop len)
        nil
      (let* ((top (aref heap 0))
             (last (aref heap (1- len))))
        ;; Replace root with last element
        (aset heap 0 last)
        ;; Remove last element
        (aset heap (1- len) nil)
        ;; Decrease length
        (setf (concur-priority-queue-len queue) (1- len))
        ;; Re-heapify
        (concur-priority-queue--heapify-down
           heap 0 
           (concur-priority-queue-len queue)
           (concur-priority-queue-comparator queue))
        ;; Return previous root
        top))))

;;;###autoload
(defun concur-priority-queue-remove (queue item)
  "Remove the ITEM from the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (index (cl-position item heap :test #'equal :end len))) ; restrict to actual contents
    (when index
      (let* ((last-idx (1- len))
             (last (aref heap last-idx))
             (comparator (concur-priority-queue-comparator queue)))
        ;; Swap and remove
        (aset heap index last)
        (aset heap last-idx nil)
        (setf (concur-priority-queue-len queue) last-idx)

        ;; Maintain heap invariant
        (cond
         ((and (> index 0)
               (funcall comparator (aref heap (floor (1- index) 2)) (aref heap index)))
          ;; Heapify up if parent is less priority
          (concur-priority-queue--heapify-up heap index comparator))
         (t
          ;; Otherwise heapify down
          (concur-priority-queue--heapify-down heap index comparator)))))))

;;;###autoload
(defun concur-priority-queue-update (queue item new-priority)
  "Update the priority of ITEM in the priority QUEUE to NEW-PRIORITY."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (index (cl-position item heap :test #'equal :end len)))
    (when index
      (let* ((comparator (concur-priority-queue-comparator queue))
             (old-priority (aref heap index)))
        (aset heap index new-priority)
        (cond
         ((funcall comparator old-priority new-priority)
          ;; New priority is greater (i.e., item should go down in a max-heap)
          (concur-priority-queue--heapify-down heap index comparator))
         ((funcall comparator new-priority old-priority)
          ;; New priority is smaller (i.e., item should go up in a min-heap)
          (concur-priority-queue--heapify-up heap index comparator))
         ;; Else no need to reheapify if priorities are equivalent
         )))))

;;;###autoload
(defun concur-priority-queue-pop-n (queue n)
  "Remove the N least-priority tasks from the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (num-to-remove (min n len)))
    (when (> num-to-remove 0)
      ;; Efficiently pop the N least-priority items by adjusting the heap.
      (dotimes (_ num-to-remove)
        (let* ((last-item (aref heap (1- len))))
          ;; Move the last item to the top
          (aset heap 0 last-item)
          (aset heap (1- len) nil)
          (setf (concur-priority-queue-len queue) (1- len))
          ;; Re-heapify down after moving the last item to the top
          (concur-priority-queue--heapify-down heap 0 (concur-priority-queue-comparator queue)))))))

;;;###autoload
(defun concur-priority-queue-remove-n (queue n)
  "Remove the N least-priority items from the priority QUEUE."
  (let* ((heap (concur-priority-queue-heap queue))
         (len (concur-priority-queue-len queue))
         (num-to-remove (min n len)))
    (when (> num-to-remove 0)
      ;; Directly remove the N least-priority items towards the bottom of the heap.
      (dotimes (_ num-to-remove)
        (let* ((idx (- len 1))  ;; Index of the least-priority item
               (item (aref heap idx)))
          ;; Swap the item with the last item in the heap and nullify the last position
          (aset heap idx nil)
          (setf (concur-priority-queue-len queue) (1- len))
          ;; Restore the heap property by heapifying down the swapped item
          (concur-priority-queue--heapify-down heap idx (concur-priority-queue-comparator queue)))))))

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
(defsubst concur-priority-queue-empty? (queue)
  "Return non-nil if the priority QUEUE is empty."
  (= 0 (concur-priority-queue-len queue)))

;;;###autoload
(defun concur-priority-queue-peek (queue)
  "Return the highest-priority item from QUEUE without removing it."
  (unless (concur-priority-queue-empty? queue)
    (aref (concur-priority-queue-heap queue) 0)))

;;;###autoload
(defun concur-priority-queue--heapify-up (heap idx comparator)
  "Move the element at IDX up in HEAP using COMPARATOR."
  (catch 'done
    (while (> idx 0)
      (let* ((parent-idx (floor (- idx 1) 2))  ;; Fix parent-idx calculation
             (current (aref heap idx))
             (parent (aref heap parent-idx)))
        (if (funcall comparator parent current)
            (progn
              (cl-rotatef (aref heap idx) (aref heap parent-idx))
              (setq idx parent-idx))
          ;; Throw 'done to exit the loop when heap property is satisfied
          (throw 'done nil))))))

;;;###autoload
(defun concur-priority-queue--heapify-down (heap idx len comparator)
  "Move the element at IDX down in HEAP using COMPARATOR. LEN is active heap size."
  (log! "concur-priority-queue--heapify-down")
  (catch 'done
    (while t
      (let* ((left (1+ (* 2 idx)))
             (right (1+ left))
             (largest idx))
        (when (and (< left len)
                   (funcall comparator (aref heap left) (aref heap largest)))
          (setq largest left))
        (when (and (< right len)
                   (funcall comparator (aref heap right) (aref heap largest)))
          (setq largest right))
        (if (= largest idx)
            ;; Exit loop when heap property is satisfied
            (throw 'done nil)
          (cl-rotatef (aref heap idx) (aref heap largest))
          (setq idx largest))))))
          
(provide 'concur-priority-queue)
;;; concur-priority-queue.el ends here