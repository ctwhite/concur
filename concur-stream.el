;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; concur-stream.el --- Asynchronous Data Streams for Concur -*- lexical-binding: t; -*-

;;; Commentary:

;; This file provides an asynchronous data stream primitive, `concur-stream`.
;; It acts as a non-blocking, promise-based, thread-safe queue designed to
;; facilitate communication between concurrent operations, particularly for
;; streaming the output of one process to the input of another.
;;
;; Key features include:
;; - **Backpressure**: Writers implicitly block (by returning a promise)
;;   when the stream's internal buffer is full, ensuring memory safety.
;; - **Asynchronous Reads**: Readers can initiate a read operation and
;;   asynchronously wait for data to arrive without blocking Emacs.
;; - **Thread-Safety**: All internal state is protected by a `concur-lock`
;;   to ensure safe concurrent access.
;; - **Error Propagation**: Errors can be explicitly injected into the
;;   stream, causing all pending and future operations to reject with the
;;   specified error.
;; - **End-of-File Signaling**: Streams can be explicitly closed, signaling
;;   an end-of-file condition to all readers.

;;; Code:

(require 'cl-lib)        ; For cl-loop, cl-find-if, etc.

(require 'concur-core)   ; Core Concur promises and futures
(require 'concur-lock)   ; For stream internal mutex
(require 'concur-chain)  ; For promise chaining
(require 'concur-queue)  ; For internal buffer and waiter queues

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data Structures & Errors

(define-error 'concur-stream-closed-error
  "Attempted to write to a closed stream." 'concur-error)
(define-error 'concur-stream-full-error
  "Attempted to write to a full stream buffer." 'concur-error)
(define-error 'concur-stream-errored-error
  "Stream has been put into an error state." 'concur-error)

(cl-defstruct (concur-stream (:constructor %%make-concur-stream))
  "Represents an asynchronous, buffered data stream.

  Arguments:
  - `name` (string): A unique or descriptive name for the stream.
  - `buffer` (concur-queue): Internal FIFO queue of data chunks written
    but not yet read. Initialized to a new `concur-queue`.
  - `max-buffer-size` (integer): Maximum chunks the buffer can hold.
    If 0, the buffer is unbounded. Defaults to 0.
  - `waiters` (concur-queue): Queue of `(resolve . reject)` pairs for
    pending read operations that are waiting for data to be written.
    Initialized to a new `concur-queue`.
  - `writers-waiting` (concur-queue): Queue of promises for write operations
    that are currently blocked due to a full buffer (backpressure).
    Initialized to a new `concur-queue`.
  - `lock` (concur-lock): A mutex protecting the stream's internal state
    from concurrent access. Initialized to a new `concur-lock`.
  - `closed-p` (boolean): `t` if the stream has been explicitly closed,
    signaling an end-of-file. Defaults to `nil`.
  - `error` (concur-error or nil): The `concur-error` object if the stream
    has been explicitly put into an error state. Defaults to `nil`."
  (name nil :type string)
  (buffer nil :type (or null (satisfies concur-queue-p)))
  (max-buffer-size 0 :type integer)
  (waiters nil :type (or null (satisfies concur-queue-p)))
  (writers-waiting nil :type (or null (satisfies concur-queue-p)))
  (lock nil :type (or null (satisfies concur-lock-p)))
  (closed-p nil :type boolean)
  (error nil :type (or null (satisfies concur-error-p))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API

;;;###autoload
(cl-defun concur:stream-create (&key (name (format "stream-%S" (gensym)))
                                  (max-buffer-size 0) (mode :thread))
  "Create and return a new empty `concur-stream`.

  Arguments:
  - `:name` (string, optional): A unique or descriptive name for the stream.
    Defaults to a generated name.
  - `:MAX-BUFFER-SIZE` (integer, optional): Maximum chunks the stream buffer can
    hold. If 0 (default), the buffer is unbounded.
  - `:MODE` (symbol, optional): Concurrency mode for the internal `lock`.
    Defaults to `:thread` for robust safety.

  Returns:
  - (concur-stream): A new stream object."
  (%%make-concur-stream
   :name name
   :buffer (concur-queue-create)
   :max-buffer-size max-buffer-size
   :waiters (concur-queue-create)
   :writers-waiting (concur-queue-create)
   :lock (concur:make-lock (format "stream-lock-%s" name) :mode mode)))

;;;###autoload
(defun concur:stream-write (stream chunk)
  "Write a `CHUNK` of data to the `STREAM`.
If readers are waiting, it fulfills one of their read promises. Otherwise,
the chunk is buffered. If the buffer is full, this function returns a promise
that resolves when space becomes available (backpressure).

  Arguments:
  - `STREAM` (concur-stream): The stream to write to.
  - `CHUNK` (any): The data chunk to write.

  Returns:
  - (concur-promise or t): A `concur-promise` if writing is blocked by
    backpressure, or `t` if the chunk was written immediately.
    Signals a `concur-stream-closed-error` or `concur-stream-errored-error`
    if the stream is closed or in an error state."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-write: Invalid stream object: %S" stream))
  (concur:with-mutex! (concur-stream-lock stream)
    (cond
     ((concur-stream-error stream)
      (signal 'concur-stream-errored-error
              (list (concur-stream-error stream))))
     ((concur-stream-closed-p stream)
      (signal 'concur-stream-closed-error
              (list (concur:make-error :type :stream-closed
                                       :message "Cannot write to closed stream"
                                       :promise (concur:make-promise))))) ; Dummy promise
     ;; If readers are waiting, fulfill one directly.
     ((not (concur-queue-empty-p (concur-stream-waiters stream)))
      (let ((resolve-fn (car (concur-queue-dequeue (concur-stream-waiters stream)))))
        (funcall resolve-fn chunk))
      t) ; Return t for immediate success
     ;; If buffer is full, apply backpressure.
     ((and (> (concur-stream-max-buffer-size stream) 0)
           (>= (concur-queue-length (concur-stream-buffer stream))
               (concur-stream-max-buffer-size stream)))
      (let ((p (concur:make-promise)))
        (concur-queue-enqueue (concur-stream-writers-waiting stream) p)
        p))
     ;; Otherwise, add chunk to buffer.
     (t (concur-queue-enqueue (concur-stream-buffer stream) chunk)
        t)))) ; Return t for immediate success

;;;###autoload
(defun concur:stream-close (stream)
  "Close the `STREAM`, signaling an end-of-file condition.
This resolves any pending read promises with the special value `:eof`.
Further writes to the stream will signal a `concur-stream-closed-error`.

  Arguments:
  - `STREAM` (concur-stream): The stream to close.

  Returns:
  - `nil` (side-effect: closes stream, resolves waiters)."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-close: Invalid stream object: %S" stream))
  (concur:with-mutex! (concur-stream-lock stream)
    (unless (or (concur-stream-closed-p stream) (concur-stream-error stream))
      (setf (concur-stream-closed-p stream) t)
      ;; Resolve all waiting readers with :eof.
      (while-let ((waiter (concur-queue-dequeue (concur-stream-waiters stream))))
        (funcall (car waiter) :eof))
      ;; Reject all writers waiting for space.
      (while-let ((writer (concur-queue-dequeue
                           (concur-stream-writers-waiting stream))))
        (concur:reject writer (concur:make-error :type :stream-closed
                                                 :message "Stream closed"))))))

;;;###autoload
(defun concur:stream-error (stream error-obj)
  "Put the `STREAM` into an error state.
This immediately rejects all pending read and write promises with `ERROR-OBJ`.
Further reads/writes will also be rejected with this error.

  Arguments:
  - `STREAM` (concur-stream): The stream to put into an error state.
  - `ERROR-OBJ` (concur-error): The structured `concur-error` to propagate.

  Returns:
  - `nil` (side-effect: sets error state, rejects promises)."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-error: Invalid stream object: %S" stream))
  (unless (concur-error-p error-obj) ; Basic check for proper error object
    (user-error "concur:stream-error: ERROR-OBJ must be a concur-error struct: %S"
                error-obj))
  (concur:with-mutex! (concur-stream-lock stream)
    (unless (or (concur-stream-closed-p stream) (concur-stream-error stream))
      (setf (concur-stream-error stream) error-obj)
      ;; Reject all waiting readers.
      (while-let ((waiter (concur-queue-dequeue (concur-stream-waiters stream))))
        (funcall (cdr waiter) error-obj))
      ;; Reject all writers waiting for space.
      (while-let ((writer (concur-queue-dequeue
                           (concur-stream-writers-waiting stream))))
        (concur:reject writer error-obj)))))

;;;###autoload
(defun concur:stream-read (stream)
  "Read the next chunk of data from the `STREAM`.
This operation is asynchronous and returns a promise. If data is
available, the promise is resolved immediately. Otherwise, it is
resolved when a new chunk is written or the stream is closed/errored.

  Arguments:
  - `STREAM` (concur-stream): The stream to read from.

  Returns:
  - (concur-promise): A promise that resolves with the next data chunk,
    `:eof` if the stream is closed, or rejects if the stream is in an
    error state."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-read: Invalid stream object: %S" stream))
  (concur:with-executor (lambda (resolve reject)
    (concur:with-mutex! (concur-stream-lock stream)
      (cond
       ;; If stream has errored, reject immediately.
       ((concur-stream-error stream)
        (funcall reject (concur-stream-error stream)))
       ;; If data is in the buffer, resolve immediately.
       ((not (concur-queue-empty-p (concur-stream-buffer stream)))
        (let ((chunk (concur-queue-dequeue (concur-stream-buffer stream))))
          (funcall resolve chunk)
          ;; If a writer was waiting for space, unblock it.
          (when-let ((writer (concur-queue-dequeue
                              (concur-stream-writers-waiting stream))))
            (concur:resolve writer t))))
       ;; If stream is closed and buffer is empty, resolve with :eof.
       ((concur-stream-closed-p stream)
        (funcall resolve :eof))
       ;; Otherwise, queue the resolver functions to wait for data.
       (t (concur-queue-enqueue (concur-stream-waiters stream)
                                 (cons resolve reject))))))))

;;;###autoload
(cl-defun concur:stream-for-each (stream callback &key cancel-token)
  "Apply `CALLBACK` to each chunk of data from `STREAM` as it arrives.
This is a memory-efficient way to process a stream's entire content.
It repeatedly reads from the stream and executes the callback for each
data chunk until the stream is closed or an error occurs.

  Arguments:
  - `STREAM` (concur-stream): The stream to process.
  - `CALLBACK` (function): A function of one argument, called with each
    data chunk.
  - `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to
    cancel the processing loop prematurely.

  Returns:
  - (concur-promise): A promise that resolves with `t` when the entire
    stream has been processed successfully, or rejects on error or
    cancellation."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-for-each: Invalid stream object: %S" stream))
  (unless (functionp callback)
    (user-error "concur:stream-for-each: CALLBACK must be a function: %S"
                callback))
  (concur:with-executor (lambda (resolve reject)
    (cl-labels
        ((read-loop ()
           (if (and cancel-token
                    (concur:cancel-token-cancelled-p cancel-token))
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
  - (concur-promise): A promise resolving to a list of all chunks."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-drain: Invalid stream object: %S" stream))
  (let ((chunks '()))
    (concur:then (concur:stream-for-each stream (lambda (chunk) (push chunk chunks)))
                 (lambda (_) (nreverse chunks)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API: Introspection

;;;###autoload
(defun concur:stream-is-closed-p (stream)
  "Return `t` if the `STREAM` has been closed.

  Arguments:
  - `STREAM` (concur-stream): The stream to inspect.

  Returns:
  - (boolean): `t` if closed, `nil` otherwise."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-is-closed-p: Invalid stream object: %S" stream))
  (concur-stream-closed-p stream))

;;;###autoload
(defun concur:stream-is-errored-p (stream)
  "Return `t` if the `STREAM` is in an error state.

  Arguments:
  - `STREAM` (concur-stream): The stream to inspect.

  Returns:
  - (boolean): `t` if errored, `nil` otherwise."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-is-errored-p: Invalid stream object: %S" stream))
  (not (null (concur-stream-error stream))))

;;;###autoload
(defun concur:stream-get-error (stream)
  "Return the `concur-error` object if the `STREAM` is in an error state.

  Arguments:
  - `STREAM` (concur-stream): The stream to inspect.

  Returns:
  - (concur-error or nil): The error object, or `nil`."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-get-error: Invalid stream object: %S" stream))
  (concur-stream-error stream))

;;;###autoload
(defun concur:stream-status (stream)
  "Return a snapshot of the `STREAM`'s current status.

  Arguments:
  - `STREAM` (concur-stream): The stream to inspect.

  Returns:
  - (plist): A property list with stream metrics:
    `:name`: Name of the stream.
    `:buffer-length`: Number of chunks currently in the buffer.
    `:max-buffer-size`: Maximum buffer size (0 for unbounded).
    `:pending-reads`: Number of readers waiting for data.
    `:blocked-writes`: Number of writers blocked by backpressure.
    `:closed-p`: Whether the stream is closed.
    `:errored-p`: Whether the stream is in an error state.
    `:error-object`: The `concur-error` object if errored."
  (unless (concur-stream-p stream)
    (user-error "concur:stream-status: Invalid stream object: %S" stream))
  (concur:with-mutex! (concur-stream-lock stream)
    `(:name ,(concur-stream-name stream)
      :buffer-length ,(concur-queue-length (concur-stream-buffer stream))
      :max-buffer-size ,(concur-stream-max-buffer-size stream)
      :pending-reads ,(concur-queue-length (concur-stream-waiters stream))
      :blocked-writes ,(concur-queue-length
                        (concur-stream-writers-waiting stream))
      :closed-p ,(concur-stream-closed-p stream)
      :errored-p ,(concur:stream-is-errored-p stream)
      :error-object ,(concur-stream-error stream))))

(provide 'concur-stream)
;;; concur-stream.el ends here