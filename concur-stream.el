;;; concur-stream.el --- Asynchronous Data Streams for Concur -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;; This file provides an asynchronous data stream primitive, `concur-stream`.
;; It acts as a non-blocking, promise-based, thread-safe queue. It is
;; designed to facilitate communication between concurrent operations,
;; particularly for streaming the output of one process to the input of another.
;;
;; Key features include backpressure (writers block when the buffer is full)
;; and asynchronous reads (readers wait for data to arrive).

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-lock)
(require 'concur-chain)
(require 'concur-queue)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures & Errors

(define-error 'concur-stream-closed-error
  "Attempted to write to a closed stream." 'concur-error)
(define-error 'concur-stream-full-error
  "Attempted to write to a full stream buffer." 'concur-error)
(define-error 'concur-stream-errored-error
  "Stream has been put into an error state." 'concur-error)

(cl-defstruct (concur-stream (:constructor %%make-concur-stream))
  "Represents an asynchronous, buffered data stream.

Fields:
- `buffer` (concur-queue): Internal FIFO queue of data chunks written but not yet read.
- `max-buffer-size` (integer): Maximum chunks the buffer can hold. 0 is unbounded.
- `waiters` (concur-queue): Queue of `(resolve . reject)` pairs for pending reads.
- `writers-waiting` (concur-queue): Queue of promises for writes blocked by a
  full buffer (backpressure).
- `lock` (concur-lock): A mutex protecting the stream's internal state.
- `closed-p` (boolean): `t` if the stream has been explicitly closed.
- `error` (concur-error or nil): The error object if the stream is in an error state."
  (buffer (concur-queue-create))
  (max-buffer-size 0 :type integer)
  (waiters (concur-queue-create))
  (writers-waiting (concur-queue-create))
  (lock (concur:make-lock "stream-lock" :mode :thread))
  (closed-p nil :type boolean)
  (error nil :type (or null (satisfies consp)))) ; `concur-error` is a plist

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(cl-defun concur:stream-create (&key (max-buffer-size 0) (mode :thread))
  "Create and return a new empty `concur-stream`.

Arguments:
- `:MAX-BUFFER-SIZE` (integer, optional): Max chunks the stream buffer can
  hold. If 0 (default), the buffer is unbounded.
- `:MODE` (symbol, optional): Concurrency mode for the internal `lock`.
  Defaults to `:thread` for robust safety.

Returns:
  (concur-stream) A new stream object."
  (%%make-concur-stream
   :max-buffer-size max-buffer-size
   :lock (concur:make-lock (format "stream-lock-%s" (sxhash (current-time)))
                           :mode mode)))

;;;###autoload
(defun concur:stream-write (stream chunk)
  "Write a `CHUNK` to the `STREAM`.
If readers are waiting, it fulfills one of their read promises. Otherwise,
the chunk is buffered. If the buffer is full, this function returns a promise
that resolves when space becomes available (backpressure).

Arguments:
- `STREAM` (concur-stream): The stream to write to.
- `CHUNK` (any): The data chunk to write.

Returns:
  (concur-promise or nil) A promise if writing is blocked by backpressure,
  otherwise `nil`. Signals an error if stream is closed or errored."
  (concur:with-mutex! (concur-stream-lock stream)
    (cond
     ((concur-stream-error stream) (signal 'concur-stream-errored-error
                                           (list (concur-stream-error stream))))
     ((concur-stream-closed-p stream) (signal 'concur-stream-closed-error
                                              (list "Cannot write to closed stream")))
     ;; If readers are waiting, fulfill one directly.
     ((not (concur-queue-empty-p (concur-stream-waiters stream)))
      (let ((resolve-fn (car (concur-queue-dequeue (concur-stream-waiters stream)))))
        (funcall resolve-fn chunk))
      nil)
     ;; If buffer is full, apply backpressure.
     ((and (> (concur-stream-max-buffer-size stream) 0)
           (>= (concur-queue-length (concur-stream-buffer stream))
               (concur-stream-max-buffer-size stream)))
      (let ((p (concur:make-promise)))
        (concur-queue-enqueue (concur-stream-writers-waiting stream) p)
        p))
     ;; Otherwise, add chunk to buffer.
     (t (concur-queue-enqueue (concur-stream-buffer stream) chunk)
        nil))))

;;;###autoload
(defun concur:stream-close (stream)
  "Close the `STREAM`, signaling an end-of-file condition.
This resolves any pending read promises with the special value `:eof`.
Further writes to the stream will signal an error.

Arguments:
- `STREAM` (concur-stream): The stream to close."
  (concur:with-mutex! (concur-stream-lock stream)
    (unless (or (concur-stream-closed-p stream) (concur-stream-error stream))
      (setf (concur-stream-closed-p stream) t)
      ;; Resolve all waiting readers with :eof.
      (while-let ((waiter (concur-queue-dequeue (concur-stream-waiters stream))))
        (funcall (car waiter) :eof))
      ;; Reject all writers waiting for space.
      (while-let ((writer (concur-queue-dequeue
                           (concur-stream-writers-waiting stream))))
        (concur:reject writer (concur:make-error :type :stream-closed))))))

;;;###autoload
(defun concur:stream-error (stream error-obj)
  "Put the `STREAM` into an error state.
This immediately rejects all pending read and write promises with `ERROR-OBJ`.
Further reads/writes will also be rejected with this error.

Arguments:
- `STREAM` (concur-stream): The stream to put into an error state.
- `ERROR-OBJ` (concur-error): The structured `concur-error` to propagate."
  (unless (consp error-obj) ; Basic check for plist-like structure
    (error "concur:stream-error: ERROR-OBJ must be a concur-error struct."))
  (concur:with-mutex! (concur-stream-lock stream)
    (unless (or (concur-stream-closed-p stream) (concur-stream-error stream))
      (setf (concur-stream-error stream) error-obj)
      (while-let ((waiter (concur-queue-dequeue (concur-stream-waiters stream))))
        (funcall (cdr waiter) error-obj))
      (while-let ((writer (concur-queue-dequeue
                           (concur-stream-writers-waiting stream))))
        (concur:reject writer error-obj))))))

;;;###autoload
(defun concur:stream-read (stream)
  "Read the next chunk of data from the `STREAM`.
This operation is asynchronous and returns a promise. If data is
available, the promise is resolved immediately. Otherwise, it is
resolved when a new chunk is written or the stream is closed/errored.

Arguments:
- `STREAM` (concur-stream): The stream to read from.

Returns:
  (concur-promise) A promise that resolves with the next data chunk,
  `:eof` if the stream is closed, or rejects if the stream is in an error state."
  (concur:with-executor (lambda (resolve reject)
    (concur:with-mutex! (concur-stream-lock stream)
      (cond
       ;; If stream has errored, reject immediately.
       ((concur-stream-error stream) (funcall reject (concur-stream-error stream)))
       ;; If data is in the buffer, resolve immediately.
       ((not (concur-queue-empty-p (concur-stream-buffer stream)))
        (let ((chunk (concur-queue-dequeue (concur-stream-buffer stream))))
          (funcall resolve chunk)
          ;; If a writer was waiting for space, unblock it.
          (when-let ((writer (concur-queue-dequeue
                              (concur-stream-writers-waiting stream))))
            (concur:resolve writer t))))
       ;; If stream is closed and buffer is empty, resolve with :eof.
       ((concur-stream-closed-p stream) (funcall resolve :eof))
       ;; Otherwise, queue the resolver functions to wait for data.
       (t (concur-queue-enqueue (concur-stream-waiters stream)
                                 (cons resolve reject))))))))

;;;###autoload
(cl-defun concur:stream-for-each (stream callback &key cancel-token)
  "Apply `CALLBACK` to each chunk of data from `STREAM` as it arrives.
This is a memory-efficient way to process a stream's entire
content. It repeatedly reads from the stream and executes the
callback for each data chunk until the stream is closed or an
error occurs.

Arguments:
- `STREAM` (concur-stream): The stream to process.
- `CALLBACK` (function): A function of one argument, called with each data chunk.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to
  cancel the processing loop prematurely.

Returns:
  (concur-promise) A promise that resolves with `t` when the entire stream
  has been processed successfully, or rejects on error or cancellation."
  (concur:with-executor (lambda (resolve reject)
    (cl-labels
        ((read-loop ()
           (if (and cancel-token (concur:cancel-token-cancelled-p cancel-token))
               (funcall reject (concur:make-error :type :cancelled))
             (concur:then
              (concur:stream-read stream)
              ;; on-resolved from stream-read
              (lambda (chunk)
                (if (eq chunk :eof)
                    (funcall resolve t) ; End of stream, success.
                  (condition-case err
                      (progn (funcall callback chunk) (read-loop))
                    (error (funcall reject (concur:make-error
                                            :type :callback-error :cause err))))))
              ;; on-rejected from stream-read
              #'reject))))
      (read-loop)))))

;;;###autoload
(defun concur:stream-drain (stream)
  "Read all data from `STREAM` until it closes, returning a promise for a list.
This is memory-intensive for large streams. For processing items
as they arrive, use `concur:stream-for-each`.

Arguments:
- `STREAM` (concur-stream): The stream to drain.

Returns:
  (concur-promise) A promise resolving to a list of all chunks."
  (let ((chunks '()))
    (concur:then (concur:stream-for-each stream (lambda (chunk) (push chunk chunks)))
                 (lambda (_) (nreverse chunks)))))

(provide 'concur-stream)
;;; concur-stream.el ends here