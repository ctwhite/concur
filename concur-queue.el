;;; concur-queue.el --- Thread-Safe FIFO Queue for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This module provides a generic, thread-safe First-In, First-Out (FIFO)
;; queue implementation. It offers efficient (O(1)) enqueueing, dequeueing,
;; and length tracking, making it suitable for use in asynchronous and
;; concurrent contexts.
;;
;; This queue is designed to be a fundamental, reusable data structure
;; within the Concur library. All operations are atomic and safe to call
;; from multiple threads.

;;; Code:

(require 'cl-lib)
(require 'concur-lock)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Forward Declarations

(declare-function concur:make-error "concur-core")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors

(define-error 'concur-queue-error
  "A generic error related to a `concur-queue`."
  'concur-error)

(define-error 'concur-invalid-queue-error
  "An operation was attempted on an invalid queue object."
  'concur-queue-error)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-queue-node (:constructor %%make-queue-node))
  "Represents a single node in the queue's internal linked list."
  data
  (next nil :type (or concur-queue-node null)))

(cl-defstruct (concur-queue (:constructor %%make-queue))
  "A thread-safe FIFO queue using explicit head and tail nodes.

Fields:
- `head` (concur-queue-node): The first node in the queue.
- `tail` (concur-queue-node): The last node in the queue.
- `lock` (concur-lock): A mutex protecting all queue operations.
- `count` (integer): The number of items currently in the queue."
  (head nil :type (or concur-queue-node null))
  (tail nil :type (or concur-queue-node null))
  (lock (concur:make-lock) :type concur-lock-p)
  (count 0 :type integer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-queue (queue function-name)
  "Signal an error if QUEUE is not a `concur-queue`.

Arguments:
- `QUEUE` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
  (unless (eq (type-of queue) 'concur-queue)
    (signal 'concur-invalid-queue-error
            (list (format "%s: Invalid queue object" function-name) queue))))

(defun concur--queue-empty-p-internal (queue)
  "Non-locking version of `concur:queue-empty-p` for internal use.
This must be called from within a context that already holds the queue's lock."
  (zerop (concur-queue-count queue)))

(defun concur--queue-dequeue-internal (queue)
  "Non-locking version of `concur:queue-dequeue` for internal use.
This must be called from within a context that already holds the queue's lock."
  (when-let ((head-node (concur-queue-head queue)))
    (let ((item (concur-queue-node-data head-node)))
      (setf (concur-queue-head queue) (concur-queue-node-next head-node))
      (when (zerop (cl-decf (concur-queue-count queue)))
        (setf (concur-queue-tail queue) nil))
      item)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defun concur-queue-create ()
  "Create a new, empty, thread-safe queue.

Returns:
- (concur-queue): A new `concur-queue` instance."
  (let* ((name (format "queue-lock-%S" (gensym)))
         (queue (%%make-queue :lock (concur:make-lock name))))
    (concur--log :debug nil "Created new queue %S." queue)
    queue))

;;;###autoload
(defun concur:queue-enqueue (queue item)
  "Add `ITEM` to the end of the `QUEUE`. O(1) complexity.
This operation is thread-safe.

Arguments:
- `QUEUE` (concur-queue): The queue instance.
- `ITEM` (any): The item to add.

Returns:
- `nil`.

Signals:
- `concur-invalid-queue-error` if `QUEUE` is not a valid queue."
  ;; (concur--validate-queue queue 'concur:queue-enqueue)
  (concur:with-mutex! (concur-queue-lock queue)
    (let ((new-node (%%make-queue-node :data item)))
      (if (concur--queue-empty-p-internal queue)
          (setf (concur-queue-head queue) new-node
                (concur-queue-tail queue) new-node)
        (setf (concur-queue-node-next (concur-queue-tail queue)) new-node
              (concur-queue-tail queue) new-node)))
    (cl-incf (concur-queue-count queue))))

;;;###autoload
(defun concur:queue-enqueue-front (queue item)
  "Add `ITEM` to the front of the `QUEUE`. O(1) complexity.
This operation is thread-safe.

Arguments:
- `QUEUE` (concur-queue): The queue instance.
- `ITEM` (any): The item to add to the front.

Returns:
- `nil`.

Signals:
- `concur-invalid-queue-error` if `QUEUE` is not a valid queue."
  ;; (concur--validate-queue queue 'concur:queue-enqueue-front)
  (concur:with-mutex! (concur-queue-lock queue)
    (let ((new-node (%%make-queue-node :data item)))
      (if (concur--queue-empty-p-internal queue)
          ;; If queue is empty, new node is both head and tail.
          (setf (concur-queue-head queue) new-node
                (concur-queue-tail queue) new-node)
        ;; Otherwise, link it before the current head.
        (setf (concur-queue-node-next new-node) (concur-queue-head queue)
              (concur-queue-head queue) new-node))
      (cl-incf (concur-queue-count queue)))))

;;;###autoload
(defun concur:queue-dequeue (queue)
  "Remove and return the first item from `QUEUE`. O(1) complexity.
This operation is thread-safe.

Arguments:
- `QUEUE` (concur-queue): The queue instance.

Returns:
- (any or nil): The dequeued item, or `nil` if the queue is empty."
  ;; (concur--validate-queue queue 'concur:queue-dequeue)
  (concur:with-mutex! (concur-queue-lock queue)
    (concur--queue-dequeue-internal queue)))

;;;###autoload
(cl-defun concur:queue-remove (queue item &key (test #'eql))
  "Remove `ITEM` from `QUEUE`. O(n) complexity.
This operation is thread-safe. It traverses the queue to find the
item and removes it.

Arguments:
- `QUEUE` (concur-queue): The queue instance.
- `ITEM` (any): The item to remove.
- `:TEST` (function, optional): The equality test. Defaults to `#'eql`.

Returns:
- `(boolean)`: `t` if the item was found and removed, `nil` otherwise."
  ;; (concur--validate-queue queue 'concur:queue-remove)
  (concur:with-mutex! (concur-queue-lock queue)
    (let ((head (concur-queue-head queue))
          (found nil))
      (cond
       ((null head) nil)
       ((funcall test item (concur-queue-node-data head))
        (concur--queue-dequeue-internal queue)
        t)
       (t
        (let ((prev head) (curr (concur-queue-node-next head)))
          (while (and curr (not found))
            (if (funcall test item (concur-queue-node-data curr))
                (progn
                  (setf found t)
                  (setf (concur-queue-node-next prev) (concur-queue-node-next curr))
                  (when (eq curr (concur-queue-tail queue))
                    (setf (concur-queue-tail queue) prev))
                  (cl-decf (concur-queue-count queue)))
              (setq prev curr curr (concur-queue-node-next curr)))))
        found)))))

;;;###autoload
(defun concur:queue-peek (queue)
  "Return the first item from `QUEUE` without removing it. O(1).
This operation is thread-safe.

Arguments:
- `QUEUE` (concur-queue): The queue instance.

Returns:
- `(any or nil)`: The first item, or `nil` if the queue is empty."
  ;; (concur--validate-queue queue 'concur:queue-peek)
  (concur:with-mutex! (concur-queue-lock queue)
    (when-let ((head (concur-queue-head queue)))
      (concur-queue-node-data head))))

;;;###autoload
(defun concur:queue-drain (queue)
  "Remove and return all items from `QUEUE` as a list.
This empties the queue. This operation is thread-safe.

Arguments:
- `QUEUE` (concur-queue): The queue instance.

Returns:
- (list): A list of all items that were in the queue."
  ;; (concur--validate-queue queue 'concur:queue-drain)
  (concur:with-mutex! (concur-queue-lock queue)
    (let (items)
      (while (not (concur--queue-empty-p-internal queue))
        (push (concur--queue-dequeue-internal queue) items))
      (nreverse items))))

;;;###autoload
(defun concur:queue-length (queue)
  "Return the number of items in `QUEUE`. O(1) complexity.

Arguments:
- `QUEUE` (concur-queue): The queue instance.

Returns:
- `(integer)`: The number of items."
  ;; (concur--validate-queue queue 'concur:queue-length)
  (concur:with-mutex! (concur-queue-lock queue)
    (concur-queue-count queue)))

;;;###autoload
(defun concur:queue-empty-p (queue)
  "Return `t` if `QUEUE` is empty. O(1) complexity.

Arguments:
- `QUEUE` (concur-queue): The queue instance.

Returns:
- `(boolean)`: `t` if the queue is empty, `nil` otherwise."
  ;; (concur--validate-queue queue 'concur:queue-empty-p)
  (concur:with-mutex! (concur-queue-lock queue)
    (zerop (concur-queue-count queue))))

;;;###autoload
(defun concur:queue-status (queue)
  "Return a snapshot of the `QUEUE`'s current status.

Arguments:
- `QUEUE` (concur-queue): The queue to inspect.

Returns:
- (plist): A property list with queue metrics."
  (interactive)
  ;; (concur--validate-queue queue 'concur:queue-status)
  (concur:with-mutex! (concur-queue-lock queue)
    `(:length ,(concur-queue-count queue)
      :is-empty ,(zerop (concur-queue-count queue)))))

(provide 'concur-queue)
;;; concur-queue.el ends here