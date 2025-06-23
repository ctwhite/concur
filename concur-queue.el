;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-queue.el --- Generic FIFO Queue for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides a generic First-In, First-Out (FIFO) queue
;; implementation built using explicit struct representations for
;; queue nodes and the queue itself. It offers efficient (O(1))
;; enqueueing, dequeueing, and length tracking, suitable for use
;; in asynchronous and concurrent contexts.
;;
;; This queue is designed to be a fundamental, reusable data structure
;; within the Concur library and potentially other Emacs Lisp projects.
;; It forms the basis for various internal queues (e.g., in `concur-stream`,
;; `concur-microtask`, `concur-shell`).

;;; Code:

(require 'cl-lib) ; For cl-defstruct, cl-incf, cl-decf

(require 'concur-log)  ; For concur--log

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures

(eval-and-compile
  (cl-defstruct (concur-queue-node (:constructor %%make-queue-node))
    "Represents a single node in the queue's internal linked list.

  Arguments:
  - `data` (any): The data chunk stored in this node. Defaults to `nil`.
  - `next` (concur-queue-node or nil): Pointer to the next node in the queue.
    Defaults to `nil`."
    (data nil)
    (next nil :type (or concur-queue-node null))))

(eval-and-compile
  (cl-defstruct (concur-queue (:constructor %%make-queue))
    "A generic FIFO queue implementation using explicit head and tail nodes.

  Arguments:
  - `head` (concur-queue-node or nil): The first node in the queue.
    `nil` if empty. Defaults to `nil`.
  - `tail` (concur-queue-node or nil): The last node in the queue.
    `nil` if empty. Defaults to `nil`.
  - `count` (integer): The number of items currently in the queue.
    Provides O(1) length. Defaults to 0."
    (head nil :type (or concur-queue-node null))
    (tail nil :type (or concur-queue-node null))
    (count 0 :type integer)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public Queue API

;;;###autoload
(defun concur-queue-create ()
  "Create a new, empty queue struct.

  Returns:
  - (concur-queue): A new `concur-queue` instance."
  (let ((queue (%%make-queue)))
    (concur--log :debug nil "Created new queue %S." queue)
    queue))

;;;###autoload
(defun concur-queue-empty-p (queue)
  "Return `t` if the `QUEUE` struct is empty. O(1) complexity.

  Arguments:
  - `QUEUE` (concur-queue): The queue struct.

  Returns:
  - (boolean): `t` if the queue is empty, `nil` otherwise."
  (unless (concur-queue-p queue)
    (user-error "concur-queue-empty-p: Invalid queue object: %S" queue))
  (zerop (concur-queue-count queue)))

;;;###autoload
(defun concur-queue-enqueue (queue item)
  "Add `ITEM` to the end of the `QUEUE` struct.
This operation is O(1) (constant time).

  Arguments:
  - `QUEUE` (concur-queue): The queue struct.
  - `ITEM` (any): The item to add.

  Returns:
  - `nil` (side-effect: modifies the queue)."
  (unless (concur-queue-p queue)
    (user-error "concur-queue-enqueue: Invalid queue object: %S" queue))
  (let ((new-node (%%make-queue-node :data item)))
    (if (concur-queue-empty-p queue)
        (setf (concur-queue-head queue) new-node
              (concur-queue-tail queue) new-node)
      (setf (concur-queue-node-next (concur-queue-tail queue)) new-node
            (concur-queue-tail queue) new-node)))
  (cl-incf (concur-queue-count queue))
  (concur--log :debug nil "Enqueued item into queue %S. Length: %d."
               queue (concur-queue-count queue))
  nil)

;;;###autoload
(defun concur-queue-dequeue (queue)
  "Remove and return the first item from the `QUEUE` struct.
This operation is O(1) (constant time).

  Arguments:
  - `QUEUE` (concur-queue): The queue struct.

  Returns:
  - (any or nil): The dequeued item, or `nil` if queue is empty."
  (unless (concur-queue-p queue)
    (user-error "concur-queue-dequeue: Invalid queue object: %S" queue))
  (when-let ((head-node (concur-queue-head queue)))
    (let ((item (concur-queue-node-data head-node)))
      (setf (concur-queue-head queue) (concur-queue-node-next head-node))
      ;; If queue became empty after dequeue, clear tail too.
      (when (zerop (cl-decf (concur-queue-count queue)))
        (setf (concur-queue-tail queue) nil))
      (concur--log :debug nil "Dequeued item from queue %S. Length: %d."
                   queue (concur-queue-count queue))
      item)))

;;;###autoload
(defun concur-queue-peek (queue)
  "Return the first item from the `QUEUE` struct without removing it. O(1).

  Arguments:
  - `QUEUE` (concur-queue): The queue struct.

  Returns:
  - (any or nil): The highest-priority item, or `nil` if the queue is empty."
  (unless (concur-queue-p queue)
    (user-error "concur-queue-peek: Invalid queue object: %S" queue))
  (unless (concur-queue-empty-p queue)
    (concur-queue-node-data (concur-queue-head queue))))

;;;###autoload
(defun concur-queue-length (queue)
  "Return the number of items currently in the `QUEUE` struct.
This operation is O(1) (constant time).

  Arguments:
  - `QUEUE` (concur-queue): The queue struct.

  Returns:
  - (integer): The number of items."
  (unless (concur-queue-p queue)
    (user-error "concur-queue-length: Invalid queue object: %S" queue))
  (concur-queue-count queue))

;;;###autoload
(defun concur-queue-status (queue)
  "Return a snapshot of the `QUEUE`'s current status.

  Arguments:
  - `QUEUE` (concur-queue): The queue instance to inspect.

  Returns:
  - (plist): A property list with queue metrics:
    `:length`: Number of items in the queue.
    `:empty-p`: Whether the queue is empty."
  (interactive)
  (unless (concur-queue-p queue)
    (user-error "concur-queue-status: Invalid queue object: %S" queue))
  `(:length ,(concur-queue-count queue)
    :empty-p ,(concur-queue-empty-p queue)))

(provide 'concur-queue)
;;; concur-queue.el ends here