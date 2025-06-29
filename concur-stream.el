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
  name buffer (max-buffer-size 0) waiters writers-waiting lock
  (closed-p nil) (error nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Internal Helpers

(defun concur--validate-stream (stream function-name)
  "Signal an error if STREAM is not a `concur-stream`.

Arguments:
- `STREAM` (any): The object to validate.
- `FUNCTION-NAME` (symbol): The name of the calling function for the error."
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
- `(concur-stream)`: A new stream object."
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

Arguments:
- `STREAM` (concur-stream): The stream to write to.
- `CHUNK` (any): The data chunk to write.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel a
  write operation that is blocked by backpressure.

Returns:
- (concur-promise or t): Returns `t` if the write completed immediately.
  Returns a promise that resolves with `t` when the write eventually
  completes, if backpressure is applied. Returns a rejected promise on
  error if `concur-stream-write-errors-async` is non-nil.

Signals:
- `concur-stream-closed-error` or `concur-stream-errored-error` if
  `concur-stream-write-errors-async` is nil."
  (concur--validate-stream stream 'concur:stream-write)
  (let (resolve-fn write-promise err)
    (concur:with-mutex! (concur-stream-lock stream)
      (cond
       ((setq err (concur-stream-error stream))
        (let ((err-obj (concur:make-error
                        :type 'concur-stream-errored-error
                        :cause err)))
          (if concur-stream-write-errors-async
              (setq write-promise (concur:rejected! err-obj))
            (signal (car err-obj) (cdr err-obj)))))
       ((concur-stream-closed-p stream)
        (let ((err-obj (concur:make-error
                        :type 'concur-stream-closed-error
                        :message "Cannot write to a closed stream")))
          (if concur-stream-write-errors-async
              (setq write-promise (concur:rejected! err-obj))
            (signal (car err-obj) (cdr err-obj)))))
       ((not (concur-queue-empty-p (concur-stream-waiters stream)))
        (setq resolve-fn (concur-queue-dequeue (concur-stream-waiters stream))))
       ((and (> (concur-stream-max-buffer-size stream) 0)
             (>= (concur-queue-length (concur-stream-buffer stream))
                 (concur-stream-max-buffer-size stream)))
        (setq write-promise (concur:make-promise :cancel-token cancel-token
                                                 :name "stream-write-blocked"))
        (concur-queue-enqueue (concur-stream-writers-waiting stream)
                              write-promise))
       (t (concur-queue-enqueue (concur-stream-buffer stream) chunk))))
    (when resolve-fn (funcall resolve-fn chunk))
    (or write-promise t)))

;;;###autoload
(cl-defun concur:stream-read (stream &key cancel-token)
  "Read the next chunk of data from `STREAM`, returning a promise.

Arguments:
- `STREAM` (concur-stream): The stream to read from.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel a
  read operation that is waiting for data.

Returns:
- `(concur-promise)`: A promise that resolves with the next data chunk,
  the keyword `:eof` if the stream is closed, or rejects on error."
  (concur--validate-stream stream 'concur:stream-read)
  (let ((read-promise (concur:make-promise :cancel-token cancel-token
                                           :name "stream-read")))
    (when cancel-token
      (concur:cancel-token-add-callback
       cancel-token
       (lambda ()
         (concur:with-mutex! (concur-stream-lock stream)
           (concur-queue-remove (concur-stream-waiters stream) read-promise)))))
    (let (writer-to-resolve)
      (concur:with-mutex! (concur-stream-lock stream)
        (cond
         ((concur-stream-error stream)
          (concur:reject read-promise (concur-stream-error stream)))
         ((not (concur-queue-empty-p (concur-stream-buffer stream)))
          (let ((chunk (concur-queue-dequeue (concur-stream-buffer stream))))
            (concur:resolve read-promise chunk)
            (setq writer-to-resolve
                  (concur-queue-dequeue
                   (concur-stream-writers-waiting stream)))))
         ((concur-stream-closed-p stream) (concur:resolve read-promise :eof))
         (t (concur-queue-enqueue (concur-stream-waiters stream) read-promise))))
      (when writer-to-resolve (concur:resolve writer-to-resolve t)))
    read-promise))

;;;###autoload
(defun concur:stream-close (stream)
  "Close `STREAM`, signaling an end-of-file (EOF) condition.
This is an idempotent operation.

Arguments:
- `STREAM` (concur-stream): The stream to close.

Returns:
- `nil`."
  (concur--validate-stream stream 'concur:stream-close)
  (let (waiters-to-resolve writers-to-reject)
    (concur:with-mutex! (concur-stream-lock stream)
      (unless (or (concur-stream-closed-p stream)
                  (concur-stream-error stream))
        (setf (concur-stream-closed-p stream) t)
        (setq waiters-to-resolve
              (concur-queue-drain (concur-stream-waiters stream)))
        (setq writers-to-reject
              (concur-queue-drain (concur-stream-writers-waiting stream)))))
    (dolist (p waiters-to-resolve) (concur:resolve p :eof))
    (let ((err (concur:make-error :type 'concur-stream-closed-error
                                  :message "Stream closed during write.")))
      (dolist (p writers-to-reject) (concur:reject p err)))))

;;;###autoload
(defun concur:stream-error (stream error-obj)
  "Put `STREAM` into an error state, propagating `ERROR-OBJ`.
This is an idempotent operation.

Arguments:
- `STREAM` (concur-stream): The stream to put into an error state.
- `ERROR-OBJ` (concur-error): The structured error to propagate.

Returns:
- `nil`."
  (concur--validate-stream stream 'concur:stream-error)
  (unless (concur-error-p error-obj)
    (error "ERROR-OBJ must be a concur-error struct: %S" error-obj))
  (let (waiters-to-reject writers-to-reject)
    (concur:with-mutex! (concur-stream-lock stream)
      (unless (or (concur-stream-closed-p stream)
                  (concur-stream-error stream))
        (setf (concur-stream-error stream) error-obj)
        (setq waiters-to-reject
              (concur-queue-drain (concur-stream-waiters stream)))
        (setq writers-to-reject
              (concur-queue-drain (concur-stream-writers-waiting stream)))))
    (dolist (p waiters-to-reject) (concur:reject p error-obj))
    (dolist (p writers-to-reject) (concur:reject p error-obj))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Stream Constructors & Processors

;;;###autoload
(defun concur:stream-from-list (list)
  "Create a new stream and write all items from `LIST` to it.
The returned stream will be closed after all items are written.

Arguments:
- `LIST` (list): A list of items to write to the new stream.

Returns:
- `(concur-stream)`: A new stream containing the items from the list."
  (let ((stream (concur:stream-create)))
    (dolist (item list) (concur:stream-write stream item))
    (concur:stream-close stream)
    stream))

;;;###autoload
(cl-defun concur:stream-for-each (stream callback &key cancel-token)
  "Apply `CALLBACK` to each chunk of data from `STREAM` as it arrives.

Arguments:
- `STREAM` (concur-stream): The stream to process.
- `CALLBACK` (function): A function `(lambda (chunk))` called for each item.
- `:CANCEL-TOKEN` (concur-cancel-token, optional): A token to cancel the
  processing loop prematurely.

Returns:
- `(concur-promise)`: A promise that resolves when the entire stream has
  been processed, or rejects on error or cancellation."
  (concur--validate-stream stream 'concur:stream-for-each)
  (unless (functionp callback) (error "CALLBACK must be a function: %S" callback))
  (cl-labels
      ((read-loop ()
         (if (and cancel-token (concur:cancel-token-cancelled-p cancel-token))
             (concur:rejected! (concur:make-error :type 'concur-cancel-error))
           (concur:then
            (concur:stream-read stream :cancel-token cancel-token)
            (lambda (chunk)
              (if (eq chunk :eof)
                  t
                (condition-case err
                    (progn (funcall callback chunk) (read-loop))
                  (error (concur:rejected!
                          (concur:make-error :type :callback-error :cause err))))))
            (lambda (err) (concur:rejected! err))))))
    (read-loop)))

;;;###autoload
(defun concur:stream-drain (stream)
  "Read all data from `STREAM` until closed, returning a list of all chunks.
This function is memory-intensive for large streams.

Arguments:
- `STREAM` (concur-stream): The stream to drain.

Returns:
- `(concur-promise)`: A promise that resolves to a list of all chunks."
  (concur--validate-stream stream 'concur:stream-drain)
  (cl-labels
      ((drain-loop (acc)
         (concur:then
          (concur:stream-read stream)
          (lambda (chunk)
            (if (eq chunk :eof)
                (nreverse acc)
              (drain-loop (cons chunk acc))))
          (lambda (err) (concur:rejected! err)))))
    (drain-loop '())))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Stream Combinators

(defun concur--stream-combinator-helper (source-stream processor-fn)
  "Internal helper to create a derived stream from a source stream.
Applies `PROCESSOR-FN` to each chunk of the `SOURCE-STREAM`.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `PROCESSOR-FN` (function): A function `(lambda (chunk dest-stream))` that
  processes a chunk and writes results to the destination stream.

Returns:
- `(concur-stream)`: The new, derived stream."
  (let ((dest-stream (concur:stream-create)))
    (concur:chain (concur:stream-for-each
                   source-stream
                   (lambda (chunk) (funcall processor-fn chunk dest-stream)))
      (:finally (lambda () (concur:stream-close dest-stream)))
      (:catch (lambda (err) (concur:stream-error dest-stream err))))
    dest-stream))

;;;###autoload
(defun concur:stream-map (source-stream map-fn)
  "Create a new stream by applying an async `MAP-FN` to each item.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `MAP-FN` (function): An async function `(lambda (chunk))` that returns a
  value or a promise for a value.

Returns:
- `(concur-stream)`: A new stream containing the mapped items."
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

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `PREDICATE-FN` (function): An async function `(lambda (chunk))` that
  returns a boolean value or a promise for one.

Returns:
- `(concur-stream)`: A new stream containing only the filtered items."
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
The new stream will be closed after `N` items have been emitted.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `N` (integer): The non-negative number of items to take.

Returns:
- `(concur-stream)`: A new stream containing at most `N` items."
  (concur--validate-stream source-stream 'concur:stream-take)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (if (= n 0)
      (let ((s (concur:stream-create))) (concur:stream-close s) s)
    (let ((dest-stream (concur:stream-create)) (counter 0))
      (cl-labels ((take-loop ()
                    (if (>= counter n)
                        (progn (concur:stream-close dest-stream)
                               (concur:resolved! t))
                      (concur:then
                       (concur:stream-read source-stream)
                       (lambda (chunk)
                         (if (eq chunk :eof)
                             (progn (concur:stream-close dest-stream) t)
                           (cl-incf counter)
                           (concur:then (concur:stream-write dest-stream chunk)
                                        #'take-loop)))))))
        (concur:chain (take-loop)
          (:catch (lambda (err) (concur:stream-error dest-stream err))))
        dest-stream))))

;;;###autoload
(defun concur:stream-take-while (source-stream predicate-fn)
  "Create a new stream that emits items as long as `PREDICATE-FN` is true.
The new stream is closed as soon as the predicate returns false.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `PREDICATE-FN` (function): An async function `(lambda (chunk))` that
  returns a promise for a boolean.

Returns:
- `(concur-stream)`: A new stream."
  (concur--validate-stream source-stream 'concur:stream-take-while)
  (let ((dest-stream (concur:stream-create)))
    (cl-labels ((take-loop ()
                  (concur:then
                   (concur:stream-read source-stream)
                   (lambda (chunk)
                     (if (eq chunk :eof)
                         (progn (concur:stream-close dest-stream) t)
                       (concur:then (funcall predicate-fn chunk)
                                    (lambda (should-continue)
                                      (if should-continue
                                          (concur:then (concur:stream-write
                                                        dest-stream chunk)
                                                       #'take-loop)
                                        (progn (concur:stream-close dest-stream)
                                               t)))))))))
      (concur:chain (take-loop)
        (:catch (lambda (err) (concur:stream-error dest-stream err))))
      dest-stream)))

;;;###autoload
(defun concur:stream-drop (source-stream n)
  "Create a new stream that skips the first `N` items from source.
All subsequent items from the source stream will be emitted.

Arguments:
- `SOURCE-STREAM` (concur-stream): The stream to read from.
- `N` (integer): The non-negative number of items to drop.

Returns:
- `(concur-stream)`: A new stream that starts after the first `N` items."
  (concur--validate-stream source-stream 'concur:stream-drop)
  (unless (and (integerp n) (>= n 0)) (error "N must be a non-negative integer"))
  (if (= n 0) source-stream
    (let ((dest-stream (concur:stream-create)) (counter 0))
      (concur:chain (concur:stream-for-each
                     source-stream
                     (lambda (chunk)
                       (if (< counter n)
                           (cl-incf counter)
                         (concur:stream-write dest-stream chunk))))
        (:finally (lambda () (concur:stream-close dest-stream)))
        (:catch (lambda (err) (concur:stream-error dest-stream err))))
      dest-stream)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API: Introspection

;;;###autoload
(defun concur:stream-is-closed-p (stream)
  "Return `t` if `STREAM` has been closed.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- `t` if closed, `nil` otherwise."
  (concur--validate-stream stream 'concur:stream-is-closed-p)
  (concur-stream-closed-p stream))

;;;###autoload
(defun concur:stream-is-errored-p (stream)
  "Return `t` if `STREAM` is in an error state.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- `t` if errored, `nil` otherwise."
  (concur--validate-stream stream 'concur:stream-is-errored-p)
  (not (null (concur-stream-error stream))))

;;;###autoload
(defun concur:stream-get-error (stream)
  "Return the `concur-error` object if `STREAM` is in an error state.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- The `concur-error` object, or `nil`."
  (concur--validate-stream stream 'concur:stream-get-error)
  (concur-stream-error stream))

;;;###autoload
(defun concur:stream-status (stream)
  "Return a snapshot of the `STREAM`'s current status.

Arguments:
- `STREAM` (concur-stream): The stream to inspect.

Returns:
- (plist): A property list with stream metrics."
  (concur--validate-stream stream 'concur:stream-status)
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