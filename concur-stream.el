;;; concur-stream.el --- Asynchronous Data Streams for Concur -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This file provides an asynchronous data stream primitive, `concur-stream`.
;; It acts as a non-blocking, promise-based, thread-safe queue designed to
;; facilitate communication between concurrent operations.
;;
;; Key features include:
;; - Backpressure: Writers can be blocked (by returning a promise) when a
;;   stream's buffer is full, ensuring memory safety.
;; - Asynchronous, Cancellable Reads: Readers can `await` data without blocking,
;;   and these pending reads can be cancelled.
;; - Thread-Safety: All internal state is protected by a `concur-lock`.
;; - Rich Combinators: A suite of functions like `map`, `filter`, `take`, and
;;   `drop` allow for declarative, memory-efficient data processing pipelines.

;;; Code:

(require 'cl-lib)
(require 'concur-core)
(require 'concur-chain)
(require 'concur-lock)
(require 'concur-queue)
(require 'concur-cancel)
(require 'concur-log)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Errors & Customization

(define-error 'concur-stream-error
  "A generic error related to a `concur-stream`."
  'concur-error)
(define-error 'concur-invalid-stream-error
  "An operation was attempted on an invalid stream object."
  'concur-stream-error)
(define-error 'concur-stream-closed-error
  "Attempted to operate on a closed stream." 'concur-stream-error)
(define-error 'concur-stream-errored-error
  "Stream has been put into an error state." 'concur-stream-error)

(defcustom concur-stream-write-errors-async nil
  "If non-nil, `concur:stream-write` returns a rejected promise on error.
If `nil` (the default), it signals a synchronous Lisp error when
attempting to write to a closed or errored stream."
  :type 'boolean
  :group 'concur)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Data Structures

(cl-defstruct (concur-stream (:constructor %%make-stream) (:copier nil))
  "Represents an asynchronous, buffered data stream.

Fields:
- `name` (string): A unique or descriptive name for the stream.
- `buffer` (concur-queue): Internal FIFO queue of data chunks.
- `max-buffer-size` (integer): Max chunks the buffer can hold (0 is unbounded).
- `waiters` (concur-queue): Queue of promises for pending read operations.
- `writers-waiting` (concur-queue): Queue of promises for pending write ops.
- `lock` (concur-lock): A mutex protecting the stream's internal state.
- `closed-p` (boolean): `t` if the stream has been closed (EOF).
- `error` (concur-error): The error if the stream is in an error state."
  (name nil :type string)
  (buffer nil :type concur-queue)
  (max-buffer-size 0 :type integer)
  (waiters nil :type concur-queue)
  (writers-waiting nil :type concur-queue)
  (lock nil :type concur-lock)
  (closed-p nil :type boolean)
  (error nil :type (or null concur-error)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-stream (stream function-name)
  "Signal an error if STREAM is not a `concur-stream`.

Arguments:
- `STREAM` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not valid.
"
  (unless (concur-stream-p stream)
    (signal 'concur-invalid-stream-error
            (list (format "%s: Invalid stream object" function-name) stream))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Construction & Core Operations

;;;###autoload
(cl-defun concur:stream-create (&key (name (format "stream-%S" (gensym)))
                                    (max-buffer-size 0) (mode :thread))
  "Create and return a new empty `concur-stream`.

Arguments:
- `:NAME` (string, optional): A descriptive name for debugging.
- `:MAX-BUFFER-SIZE` (integer, optional): Maximum chunks the buffer can
  hold before applying backpressure. If 0 (default), the buffer is unbounded.
- `:MODE` (symbol, optional): Concurrency mode for the internal lock.
  Defaults to `:thread` for robust safety.

Returns:
- `(concur-stream)`: A new stream object.

Signals:
- `error` if `MAX-BUFFER-SIZE` is negative.
"
  (unless (>= max-buffer-size 0)
    (error "MAX-BUFFER-SIZE must be non-negative: %S" max-buffer-size))
  (%%make-stream
   :name name
   :buffer (concur-queue-create)
   :max-buffer-size max-buffer-size
   :waiters (concur-queue-create)
   :writers-waiting (concur-queue-create)
   :lock (concur:make-lock (format "stream-lock-%s" name) :mode mode)))

;;;###autoload
(cl-defun concur:stream-write (stream chunk &key cancel-token)
  "Write a `CHUNK` of data to the `STREAM`.
If the stream's internal buffer is full (`max-buffer-size` is set),
this operation may return a promise that resolves when space becomes
available (backpressure). This implements a non-blocking write.

Arguments:
- `STREAM` (concur-stream): The stream to write to.
- `CHUNK` (any): The data chunk to write.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel a
  write operation that is blocked by backpressure.

Returns:
- `t` if the write completed immediately (data added to buffer or read by a waiter).
- `(concur-promise)`: A promise that resolves with `t` when the write
  eventually completes (e.g., when backpressure is relieved).
- `(concur-promise)`: A rejected promise if `concur-stream-write-errors-async`
  is non-nil and an error occurs (e.g., stream is closed or errored).

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
- `concur-stream-closed-error` if attempting to write to a closed stream
  and `concur-stream-write-errors-async` is `nil`.
- `concur-stream-errored-error` if attempting to write to an errored stream
  and `concur-stream-write-errors-async` is `nil`.
"
  (concur--validate-stream stream 'concur:stream-write)
  (let (read-waiter-promise write-promise err)
    (concur:with-mutex! (concur-stream-lock stream)
      ;; The stream's state (error, closed, buffer status) is protected
      ;; by `concur-stream-lock` to ensure thread-safe operations.
      (cond
       ((setq err (concur-stream-error stream))
        ;; If the stream is already in an error state, subsequent writes
        ;; should also indicate an error.
        (let ((err-obj (concur:make-error :type 'concur-stream-errored-error
                                          :message "Cannot write to an errored stream."
                                          :cause err)))
          (if concur-stream-write-errors-async
              (setq write-promise (concur:rejected! err-obj))
            (signal (car err-obj) (cdr err-obj)))))
       ((concur-stream-closed-p stream)
        ;; If the stream is closed, no more writes are allowed.
        (let ((err-obj (concur:make-error :type 'concur-stream-closed-error
                                          :message "Cannot write to a closed stream.")))
          (if concur-stream-write-errors-async
              (setq write-promise (concur:rejected! err-obj))
            (signal (car err-obj) (cdr err-obj)))))
       ((not (concur:queue-empty-p (concur-stream-waiters stream)))
        ;; **Producer-Consumer Hand-off:**
        ;; If there's a reader waiting (promise in `waiters` queue),
        ;; hand off the chunk directly to that reader's promise.
        ;; This avoids buffering and ensures immediate consumption.
        (setq read-waiter-promise
              (concur:queue-dequeue (concur-stream-waiters stream))))
       ((and (> (concur-stream-max-buffer-size stream) 0)
             (>= (concur:queue-length (concur-stream-buffer stream))
                 (concur-stream-max-buffer-size stream)))
        ;; **Backpressure Mechanism:**
        ;; If a `max-buffer-size` is defined and the buffer is full,
        ;; the writer's operation (this `stream-write` call) cannot complete
        ;; immediately. It returns a promise that will resolve later when a
        ;; reader consumes a chunk and makes space.
        (setq write-promise (concur:make-promise
                             :cancel-token cancel-token
                             :name "stream-write-blocked"))
        (concur:queue-enqueue (concur-stream-writers-waiting stream)
                              write-promise))
       (t
        ;; Default case: no waiting readers, buffer not full.
        ;; Add chunk to the internal buffer for later consumption.
        (concur:queue-enqueue (concur-stream-buffer stream) chunk))))
    ;; Outside the lock, resolve the waiting reader's promise if a direct
    ;; hand-off occurred. This is asynchronous, preventing deadlocks.
    (when read-waiter-promise (concur:resolve read-waiter-promise chunk))
    (or write-promise t)))

;;;###autoload
(cl-defun concur:stream-read (stream &key cancel-token)
  "Read the next chunk of data from `STREAM`, returning a promise.
If the stream's buffer is empty, the returned promise will remain pending
until data is written or the stream is closed/errored.

Arguments:
- `STREAM` (concur-stream): The stream to read from.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel a
  read operation that is waiting for data. If canceled, the promise
  is rejected with a `concur-cancel-error`.

Returns:
- `(concur-promise)`: A promise that resolves with the next data chunk.
  - Resolves to the keyword `:eof` if the stream is closed and no more
    data is available.
  - Rejects with a `concur-stream-errored-error` if the stream is in
    an error state.
  - Rejects with a `concur-cancel-error` if the read operation is cancelled.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-read)
  (let ((read-promise (concur:make-promise
                       :cancel-token cancel-token :name "stream-read")))
    ;; Set up cancellation for this specific read promise.
    ;; If the `cancel-token` is signaled, and this `read-promise` is still
    ;; waiting in the `waiters` queue, it will be removed.
    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (concur:with-mutex! (concur-stream-lock stream)
           (when (concur:pending-p read-promise) ; Only remove if still pending
             (concur:queue-remove (concur-stream-waiters stream)
                                  read-promise))))))
    (let (writer-to-resolve)
      (concur:with-mutex! (concur-stream-lock stream)
        ;; All checks and state modifications are within the lock.
        (cond
         ((concur-stream-error stream)
          ;; If stream is already errored, immediately reject the read promise.
          (concur:reject read-promise (concur-stream-error stream)))
         ((not (concur:queue-empty-p (concur-stream-buffer stream)))
          ;; Data available in buffer, resolve the read promise immediately.
          (let ((chunk (concur:queue-dequeue (concur-stream-buffer stream))))
            (concur:resolve read-promise chunk)
            ;; **Backpressure Relief:**
            ;; If there are writers waiting (blocked on `stream-write`),
            ;; dequeue one of their promises and signal it to continue.
            (setq writer-to-resolve
                  (concur:queue-dequeue (concur-stream-writers-waiting stream)))))
         ((concur-stream-closed-p stream)
          ;; Stream is closed and its buffer is empty, signal end-of-file.
          (concur:resolve read-promise :eof))
         (t
          ;; No data in buffer and stream is not closed/errored.
          ;; Enqueue this read promise to wait for data.
          (concur:queue-enqueue (concur-stream-waiters stream) read-promise))))
      ;; Outside the lock, resolve the waiting writer's promise if space was
      ;; freed up. This is asynchronous and prevents deadlocks.
      (when writer-to-resolve (concur:resolve writer-to-resolve t)))
    read-promise))

;;;###autoload
(defun concur:stream-close (stream)
  "Close `STREAM`, signaling an end-of-file (EOF) condition.
Any pending read operations will resolve with `:eof`. Any blocked write
operations will be rejected. Subsequent write operations will fail.

Arguments:
- `STREAM` (concur-stream): The stream to close.

Returns:
- `nil`.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-close)
  (let (waiters-to-resolve writers-to-reject)
    (concur:with-mutex! (concur-stream-lock stream)
      ;; All state modifications and queue draining happen under the lock.
      ;; This prevents race conditions with concurrent reads/writes.
      (unless (or (concur-stream-closed-p stream) (concur-stream-error stream))
        (setf (concur-stream-closed-p stream) t)
        ;; Drain all waiting readers and writers.
        ;; Their promises will be resolved/rejected outside the lock.
        (setq waiters-to-resolve (concur:queue-drain
                                  (concur-stream-waiters stream)))
        (setq writers-to-reject (concur:queue-drain
                                 (concur-stream-writers-waiting stream)))))
    ;; Resolve/reject promises outside the lock to prevent re-entrancy issues
    ;; and potential deadlocks if callbacks trigger further stream ops.
    (dolist (p waiters-to-resolve) (concur:resolve p :eof))
    (let ((err (concur:make-error :type 'concur-stream-closed-error
                                  :message "Stream closed during write.")))
      (dolist (p writers-to-reject) (concur:reject p err)))))

;;;###autoload
(defun concur:stream-error (stream error-obj)
  "Put `STREAM` into an error state, propagating `ERROR-OBJ`.
Any pending read or blocked write operations will be rejected with `ERROR-OBJ`.
Subsequent operations on the stream will fail or propagate this error.

Arguments:
- `STREAM` (concur-stream): The stream to put into an error state.
- `ERROR-OBJ` (concur-error): The error object to propagate.

Returns:
- `nil`.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
- `error` if `ERROR-OBJ` is not a `concur-error` struct.
"
  (concur--validate-stream stream 'concur:stream-error)
  (unless (concur-error-p error-obj) (error "ERROR-OBJ must be a concur-error struct"))
  (let (waiters-to-reject writers-to-reject)
    (concur:with-mutex! (concur-stream-lock stream)
      ;; State modification and queue draining under lock.
      (unless (or (concur-stream-closed-p stream) (concur-stream-error stream))
        (setf (concur-stream-error stream) error-obj)
        ;; Drain all waiting readers and writers.
        (setq waiters-to-reject (concur:queue-drain
                                 (concur-stream-waiters stream)))
        (setq writers-to-reject (concur:queue-drain
                                 (concur-stream-writers-waiting stream)))))
    ;; Reject promises outside the lock.
    (dolist (p waiters-to-reject) (concur:reject p error-obj))
    (dolist (p writers-to-reject) (concur:reject p error-obj))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Stream Constructors & Processors

;;;###autoload
(defun concur:stream-from-list (list)
  "Create a new stream and write all items from `LIST` to it.
The returned stream will be closed after all items are written.
This is a convenient way to convert static data into a stream that
can then be processed asynchronously.

Arguments:
- `LIST` (list): A list of items to write to the new stream.

Returns:
- `(concur-stream)`: A new stream containing the items from the list.
"
  (let ((stream (concur:stream-create)))
    (dolist (item list) (concur:stream-write stream item))
    (concur:stream-close stream)
    stream))

;;;###autoload
(cl-defun concur:stream-for-each (stream callback &key cancel-token)
  "Apply `CALLBACK` to each chunk of data from `STREAM` as it arrives.
This function asynchronously processes stream data without buffering
the entire stream, making it suitable for large or infinite streams.
The processing is sequential, ensuring chunks are handled in order.

Arguments:
- `STREAM` (concur-stream): The stream to process.
- `CALLBACK` (function): A function `(lambda (chunk))` called for each item.
  It can return a value or a promise. If it returns a promise, the next
  `CALLBACK` invocation will wait for that promise to resolve.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel the
  processing loop prematurely.

Returns:
- `(concur-promise)`: A promise that resolves when the entire stream has
  been processed (i.e., `:eof` is reached), or rejects on error or
  cancellation.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
- `error` if `CALLBACK` is not a function.
"
  (concur--validate-stream stream 'concur:stream-for-each)
  (unless (functionp callback) (error "CALLBACK must be a function: %S" callback))
  (cl-labels
      ((read-loop ()
         (if (and cancel-token (concur:cancel-token-cancelled-p cancel-token))
             (concur:rejected! (concur:make-error :type 'concur-cancel-error
                                                  :message "Stream for-each cancelled."))
           (concur:then
            (concur:stream-read stream :cancel-token cancel-token)
            (lambda (chunk)
              (if (eq chunk :eof)
                  t ; Stream drained, resolve outer promise
                (condition-case err
                    ;; Call the user's callback. If it returns a promise, chain it.
                    ;; This ensures sequential processing: the next `read-loop`
                    ;; iteration won't start until `callback`'s result promise settles.
                    (concur:then (funcall callback chunk)
                                 (lambda (_) (read-loop))) ; Continue loop after callback finishes
                  (error (concur:rejected!
                          (concur:make-error :type :callback-error
                                             :message (format "Stream for-each callback failed: %S" err)
                                             :cause err))))))
            (lambda (err) (concur:rejected! err))))))
    (read-loop)))

;;;###autoload
(defun concur:stream-drain (stream)
  "Read all data from `STREAM` until closed, returning a list of all chunks.
This function collects all stream data into memory, so it is
memory-intensive for large streams.

Arguments:
- `STREAM` (concur-stream): The stream to drain.

Returns:
- `(concur-promise)`: A promise that resolves to a list of all chunks
  collected from the stream. Rejects if the stream errors.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-drain)
  (cl-labels
      ((drain-loop (acc)
         (concur:then
          (concur:stream-read stream)
          (lambda (chunk)
            (if (eq chunk :eof)
                (nreverse acc) ; Stream drained, return accumulated list (reversed from consing)
              (drain-loop (cons chunk acc)))) ; Accumulate chunk and continue the loop
          (lambda (err) (concur:rejected! err)))))
    (drain-loop '())))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Stream Combinators

(defun concur--stream-combinator-helper (source-stream processor-fn)
  "Internal helper to create a derived stream from a source stream.
Applies `PROCESSOR-FN` to each chunk of the `SOURCE-STREAM` and
writes results to the destination stream. Manages closing/erroring
of the destination stream based on the source stream's lifecycle.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `PROCESSOR-FN` (function): A function `(lambda (chunk dest-stream))`
  that processes a chunk and writes results to the destination stream.

Returns:
- `(concur-stream)`: The new, derived stream.
"
  (let ((dest-stream (concur:stream-create)))
    ;; Use `concur:stream-for-each` to process the source stream chunk by chunk.
    ;; The finalization of `dest-stream` depends on the outcome of `stream-for-each`.
    (concur:chain (concur:stream-for-each
                   source-stream
                   (lambda (chunk) (funcall processor-fn chunk dest-stream)))
      (:finally (lambda () (concur:stream-close dest-stream))) ; Close destination when source is done
      (:catch (lambda (err) (concur:stream-error dest-stream err)))) ; Error destination if source errors
    dest-stream))

;;;###autoload
(defun concur:stream-map (source-stream map-fn)
  "Create a new stream by applying an async `MAP-FN` to each item.
The `MAP-FN` is applied to each chunk from `SOURCE-STREAM`, and its
results are emitted as chunks in the new stream.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `MAP-FN` (function): An async function `(lambda (chunk))` that returns a
  value or a promise for a value. The next chunk will be processed
  only after the promise returned by `MAP-FN` for the current chunk resolves.

Returns:
- `(concur-stream)`: A new stream containing the mapped items.
"
  (concur--validate-stream source-stream 'concur:stream-map)
  (concur--stream-combinator-helper
   source-stream
   (lambda (chunk dest-stream)
     (concur:then (funcall map-fn chunk)
                  (lambda (mapped-chunk)
                    (concur:stream-write dest-stream mapped-chunk))))))

;;;###autoload
(defun concur:stream-filter (source-stream predicate-fn)
  "Create a new stream containing only items that satisfy `PREDICATE-FN`.
`PREDICATE-FN` is applied to each chunk, and only chunks for which
it returns a truthy value (or a promise resolving to a truthy value)
are emitted into the new stream.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `PREDICATE-FN` (function): An async function `(lambda (chunk))` that
  returns a boolean value or a promise for one.

Returns:
- `(concur-stream)`: A new stream containing only the filtered items.
"
  (concur--validate-stream source-stream 'concur:stream-filter)
  (concur--stream-combinator-helper
   source-stream
   (lambda (chunk dest-stream)
     (concur:then (funcall predicate-fn chunk)
                  (lambda (should-keep)
                    (when should-keep
                      (concur:stream-write dest-stream chunk)))))))

;;;###autoload
(defun concur:stream-take (source-stream n)
  "Create a new stream that emits only the first `N` items from source.
The new stream will be closed immediately after `N` items have been emitted,
even if the `SOURCE-STREAM` still has more data.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `N` (integer): The non-negative number of items to take.

Returns:
- `(concur-stream)`: A new stream containing at most `N` items.

Signals:
- `error` if `N` is not a non-negative integer.
"
  (concur--validate-stream source-stream 'concur:stream-take)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (if (= n 0) ; If N is 0, return an already closed, empty stream
      (let ((s (concur:stream-create))) (concur:stream-close s) s)
    (let ((dest-stream (concur:stream-create)) (counter 0))
      (cl-labels ((take-loop ()
                    (if (>= counter n)
                        ;; If N items taken, close destination and resolve loop promise.
                        (progn (concur:stream-close dest-stream)
                               (concur:resolved! t))
                      ;; Otherwise, read next chunk from source stream.
                      (concur:then
                       (concur:stream-read source-stream)
                       (lambda (chunk)
                         (if (eq chunk :eof)
                             ;; Source stream ended before N items were taken, close destination.
                             (progn (concur:stream-close dest-stream) t)
                           ;; Process chunk, increment counter, and continue the loop.
                           (cl-incf counter)
                           (concur:then (concur:stream-write dest-stream chunk)
                                        #'take-loop)))))))
        (concur:chain (take-loop)
          (:catch (lambda (err) (concur:stream-error dest-stream err))))
        dest-stream))))

;;;###autoload
(defun concur:stream-take-while (source-stream predicate-fn)
  "Create a new stream that emits items as long as `PREDICATE-FN` is true.
The new stream is closed as soon as the `PREDICATE-FN` returns false
(or a promise resolving to false) for any item, or when `SOURCE-STREAM` ends.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `PREDICATE-FN` (function): An async function `(lambda (chunk))` that
  returns a promise for a boolean.

Returns:
- `(concur-stream)`: A new stream.
"
  (concur--validate-stream source-stream 'concur:stream-take-while)
  (let ((dest-stream (concur:stream-create)))
    (cl-labels ((take-loop ()
                  (concur:then
                   (concur:stream-read source-stream)
                   (lambda (chunk)
                     (if (eq chunk :eof)
                         ;; Source stream ended, close destination.
                         (progn (concur:stream-close dest-stream) t)
                       (concur:then (funcall predicate-fn chunk)
                                    (lambda (should-continue)
                                      (if should-continue
                                          ;; Predicate true, write chunk and continue loop.
                                          (concur:then (concur:stream-write
                                                        dest-stream chunk)
                                                       #'take-loop)
                                        ;; Predicate false, close destination and stop processing.
                                        (progn (concur:stream-close dest-stream)
                                               t)))))))))
      (concur:chain (take-loop)
        (:catch (lambda (err) (concur:stream-error dest-stream err))))
      dest-stream)))

;;;###autoload
(defun concur:stream-drop (source-stream n)
  "Create a new stream that skips the first `N` items from `SOURCE-STREAM`.
All subsequent items from the source stream will be emitted into the new stream.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `N` (integer): The non-negative number of items to drop.

Returns:
- `(concur-stream)`: A new stream that starts after the first `N` items.

Signals:
- `error` if `N` is not a non-negative integer.
"
  (concur--validate-stream source-stream 'concur:stream-drop)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (if (= n 0) source-stream ; If N is 0, return the original stream directly.
    (let ((dest-stream (concur:stream-create)) (counter 0))
      (concur:chain (concur:stream-for-each
                     source-stream
                     (lambda (chunk)
                       (if (< counter n)
                           (cl-incf counter) ; Drop item by incrementing counter.
                         (concur:stream-write dest-stream chunk)))) ; Emit item to destination.
        (:finally (lambda () (concur:stream-close dest-stream))) ; Close destination when source is done.
        (:catch (lambda (err) (concur:stream-error dest-stream err)))) ; Error destination if source errors.
      dest-stream)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun concur:stream-is-closed-p (stream)
  "Return `t` if `STREAM` has been closed.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- `t` if closed, `nil` otherwise.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-is-closed-p)
  (concur-stream-closed-p stream))

;;;###autoload
(defun concur:stream-is-errored-p (stream)
  "Return `t` if `STREAM` is in an error state.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- `t` if errored, `nil` otherwise.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-is-errored-p)
  (not (null (concur-stream-error stream))))

;;;###autoload
(defun concur:stream-get-error (stream)
  "Return the `concur-error` object if `STREAM` is in an error state.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- The `concur-error` object, or `nil` if the stream is not in an error state.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-get-error)
  (concur-stream-error stream))

;;;###autoload
(defun concur:stream-status (stream)
  "Return a snapshot of the `STREAM`'s current status.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- `(plist)`: A property list with stream metrics:
    - `:name` (string): The name of the stream.
    - `:buffer-length` (integer): Number of chunks currently buffered.
    - `:max-buffer-size` (integer): Configured maximum buffer size (0 for unbounded).
    - `:pending-reads` (integer): Number of readers waiting for data.
    - `:blocked-writes` (integer): Number of writers waiting for buffer space.
    - `:closed-p` (boolean): `t` if the stream is closed.
    - `:errored-p` (boolean): `t` if the stream is in an error state.
    - `:error-object` (concur-error or nil): The error if the stream is errored.

Signals:
- `concur-invalid-stream-error` if `STREAM` is not a valid object.
"
  (concur--validate-stream stream 'concur:stream-status)
  (concur:with-mutex! (concur-stream-lock stream)
    `(:name ,(concur-stream-name stream)
      :buffer-length ,(concur:queue-length (concur-stream-buffer stream))
      :max-buffer-size ,(concur-stream-max-buffer-size stream)
      :pending-reads ,(concur:queue-length (concur-stream-waiters stream))
      :blocked-writes ,(concur:queue-length
                        (concur-stream-writers-waiting stream))
      :closed-p ,(concur-stream-closed-p stream)
      :errored-p ,(concur:stream-is-errored-p stream)
      :error-object ,(concur-stream-error stream))))

(provide 'concur-stream)
;;; concur-stream.el ends here