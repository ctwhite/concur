;;; concur-queue.el --- Generic FIFO Queue for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides a generic First-In, First-Out (FIFO) queue
;; implementation built using explicit struct representations for
;; queue nodes and the queue itself. It offers efficient (O(1))
;; enqueueing, dequeueing, and length tracking, suitable for use
;; in asynchronous and concurrent contexts.

;;; Code:

(require 'cl-lib) 

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(eval-and-compile
  (cl-defstruct (concur-queue-node (:constructor %%make-queue-node))
    "Represents a single node in the queue's internal linked list.

Fields:
- `data` (any): The data chunk stored in this node.
- `next` (`concur-queue-node` or `nil`): Pointer to the next node in the queue."
    (data nil)
    (next nil :type (or concur-queue-node null))))

(eval-and-compile
  (cl-defstruct (concur-queue (:constructor %%make-queue))
    "A generic FIFO queue implementation using explicit head and tail nodes.

Fields:
- `head` (`concur-queue-node` or `nil`): The first node in the queue. `nil` if empty.
- `tail` (`concur-queue-node` or `nil`): The last node in the queue. `nil` if empty.
- `count` (integer): The number of items currently in the queue. Provides O(1) length."
    (head nil :type (or concur-queue-node null))
    (tail nil :type (or concur-queue-node null))
    (count 0 :type integer)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public Queue API

;;;###autoload
(defun concur-queue-create ()
  "Create a new, empty queue struct.
Returns: (`concur-queue`)"
  (%%make-queue))

;;;###autoload
(defun concur-queue-empty-p (queue)
  "Return `t` if the `QUEUE` struct is empty.
Arguments:
- `QUEUE` (`concur-queue`): The queue struct.
Returns: (boolean)"
  (zerop (concur-queue-count queue)))

;;;###autoload
(defun concur-queue-enqueue (queue item)
  "Add `ITEM` to the end of the `QUEUE` struct.
Arguments:
- `QUEUE` (`concur-queue`): The queue struct.
- `ITEM` (any): The item to add.
Returns: nil."
  (let ((new-node (%%make-queue-node :data item)))
    (if (concur-queue-empty-p queue)
        (setf (concur-queue-head queue) new-node
              (concur-queue-tail queue) new-node)
      (setf (concur-queue-node-next (concur-queue-tail queue)) new-node
            (concur-queue-tail queue) new-node)))
  (cl-incf (concur-queue-count queue)) ; Increment count
  nil) 

;;;###autoload
(defun concur-queue-dequeue (queue)
  "Remove and return the first item from the `QUEUE` struct.
Arguments:
- `QUEUE` (`concur-queue`): The queue struct.
Returns: (any or `nil`) The dequeued item, or `nil` if queue is empty."
  (when-let ((head-node (concur-queue-head queue)))
    (let ((item (concur-queue-node-data head-node)))
      (setf (concur-queue-head queue) (concur-queue-node-next head-node))
      (when (concur-queue-empty-p queue) ; If queue is now empty
        (setf (concur-queue-tail queue) nil)) ; Clear tail too
      (cl-decf (concur-queue-count queue)) ; Decrement count
      item)))

;;;###autoload
(defun concur-queue-peek (queue)
  "Return the first item from the `QUEUE` struct without removing it.
Arguments:
- `QUEUE` (`concur-queue`): The queue struct.
Returns: (any or `nil`) The item, or `nil` if queue is empty."
  (when-let ((head-node (concur-queue-head queue)))
    (concur-queue-node-data head-node)))

;;;###autoload
(defun concur-queue-count (queue)
  "Return the number of items currently in the `QUEUE` struct.
Arguments:
- `QUEUE` (`concur-queue`): The queue struct.
Returns: (integer) The number of items."
  (concur-queue-count queue)) ; Directly return the count slot

(provide 'concur-queue)
;;; concur-queue.el ends here