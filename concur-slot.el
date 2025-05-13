;;; concur-slot.el --- Async slot resolution via promises and futures -*- lexical-binding: t; -*-
;;
;;; Commentary:
;; Provides lazy async slot initialization for EIEIO objects using concur's
;; promise and future system. This is a reusable layer for lazy-loading slot
;; values on demand.
;;
;;; Code:

(require 'cl-lib)
(require 'concur-future)
(require 'concur-promise)
(require 'dash)
(require 'ht)
(require 'scribe)

;;;###autoload
(cl-defstruct
    (concur-lazy-opts
     (:constructor concur-lazy-opts-create)
     (:documentation
      "A struct holding configuration options for lazy/eager evaluation or resource fetching.

Slots:
- AUTO-FETCH: Whether to automatically fetch or compute the value when accessed.
- TIMEOUT: Maximum time (in seconds) to wait for a fetch or evaluation before giving up.
- RETRY: Number of retry attempts if the fetch or evaluation fails.
- LOGGER: Optional logging function called with messages for debug or audit purposes."))

  auto-fetch  ;; boolean: auto-fetch on demand
  timeout     ;; number: timeout in seconds
  retry       ;; integer: retry attempts on failure
  logger)     ;; function: logger callback (string -> nil)

;;;###autoload
(defun concur-lazy-opts-create-defaults (options)
  "Create a `concur-lazy-opts' struct from OPTIONS with defaults applied.
OPTIONS can be either a lambda expression or a plist."
  (let ((opts (if (functionp options)
                  (funcall options)  ;; Call the lambda to evaluate it
                options)))  ;; Otherwise, treat it as a plist
    (concur-lazy-opts-create
     :auto-fetch (if (plist-member opts :auto-fetch)
                     (plist-get opts :auto-fetch)
                   t)
     :timeout (plist-get opts :timeout)
     :retry  (plist-get opts :retry)
     :logger (plist-get opts :logger))))

;;;###autoload
(defun concur-expand-placeholders (form &optional replacements)
  "Expand placeholders in FORM.
Supports <> for the first argument, <cb> for the callback, <1>, <2>, etc for indexed args.
REPLACEMENTS is an optional list of cons cells for custom placeholder replacements."
  (let ((replacements (or replacements '())))
    ;; Helper function to walk the form and replace placeholders
    (cl-labels ((walk (x)
                     (cond
                      ((stringp x)
                       (cond
                        ((string= x "<>") 'args)  ;; Replace <> with the first argument (args)
                        (t (or (cdr (assoc x replacements)) x))))  ;; Replace from replacements list

                      ((symbolp x) 
                       (or (cdr (assoc (symbol-name x) replacements)) x)) ;; Replace symbols
                      
                      ((consp x)
                       (cons (walk (car x)) (walk (cdr x))))  ;; Recurse for cons cells

                      (t x))))  ;; Base case

      ;; Walk the form and expand placeholders
      (let ((expanded (walk form)))

        ;; Generate the dynamic argument list based on form
        (let ((args (->> form
                         (-flatten)
                         (--filter (string-match-p "^<" (if (stringp it) it (symbol-name it))))
                         (-distinct))))
          `(lambda ,args
             ;; Bind args dynamically
             (let ((args (list ,@args)))  
               ,expanded)))))))

(cl-defmacro concur-generic-accessor! (field &optional type)
  "Define a named generic getter/setter for FIELD in struct TYPE.
Checks that TYPE is a known `cl-defstruct` and FIELD is a valid slot."
 (let* ((type-symbol (or type 'generic))
         (type-name (symbol-name type-symbol))
         (field-name (symbol-name field))
         (getter (intern (format "%s-%s" type-name field-name)))
         (setter (intern (format "setf-%s-%s" type-name field-name))))
    `(progn
       (cl-defun ,getter (obj)
         ,(format "Return the value of slot '%s' in struct of type '%s'." field-name type-name)
         (cl-struct-slot-value ',type-symbol ',field obj))

       (cl-defun ,setter (obj val)
         ,(format "Set the value of slot '%s' in struct of type '%s'." field-name type-name)
         (setf (cl-struct-slot-value ',type-symbol ',field obj) val)))))

(cl-defmacro concur-lazy! (slot body &key type)
  "Define a lazy accessor for SLOT using BODY, optionally for a given TYPE.

If the field SLOT has already been computed (i.e. non-nil), return the cached value.
Otherwise, evaluate BODY, cache its result in the struct slot, and return the result.

Arguments:
- SLOT: The slot name (symbol) in the struct.
- BODY: A function body that computes the value, with support for placeholder syntax like `<>`.
- :type: Optional struct type symbol. If not provided, defaults to 'generic.

This macro expands placeholders in BODY (e.g., `<>`) to refer to the object instance."
  (let* ((type-sym (or (and type (if (eq (car-safe type) 'quote) (cadr type) type)) 'generic)) 
         (getter (intern (format "%s-%s" type-sym slot)))  
         (setter (intern (format "setf-%s-%s" type-sym slot))) 
         (expanded-body (concur-expand-placeholders body)))
    ;; Macro expansion
    `(progn
       ;; Define the getter function for the slot
       (defun ,getter (obj)
         (let ((existing-value (cl-struct-slot-value ',type-sym ',slot obj))) 
           (if existing-value
               existing-value 
             ;; No value found: calculate and set the value
             (let ((value (funcall ,expanded-body obj)))  
               (setf (cl-struct-slot-value ',type-sym ',slot obj) value)  ;; Store the result
               value)))))))

(cl-defmacro concur-lazy-async! (slot fn &key type options constructor)
  "Define a lazy asynchronous accessor for SLOT using FN on TYPE instances.

This macro sets up a getter, optional setter, and eager initializer for a lazily
computed slot in a structured object (e.g., `cl-defstruct`). The actual computation
is deferred and asynchronous, triggered via a user-defined callback-style function FN.

FN should be a callback-based function body, written with placeholder syntax:
  - `<>` expands to the object.
  - `<cb>` or `<callback>` expands to the callback lambda to be called with the result.

Arguments:
- SLOT: The struct slot symbol to lazily populate.
- FN: A function body (with placeholders) of the form (OBJ CALLBACK) that computes the slot.
- :type: The struct or class type symbol. Defaults to `'generic`.
- :options: A `concur-lazy-opts` object or an alist to configure auto-fetch and other behaviors.
- :constructor: Optional constructor function symbol (e.g., `make-foo`). Default: `make-TYPE`.

This defines:
- `TYPE-SLOT`: Asynchronous lazy accessor that fetches/caches the value.
- `setf-TYPE-SLOT`: Optional setter if one does not exist.
- `TYPE-init-SLOT`: Eager initialization trigger for the slot.
- Hooks into the constructor (once) to auto-fetch the slot after creation."
  (let* ((type (or type 'generic))
         (getter (intern (format "%s-%s" type slot)))
         (setter (intern (format "setf-%s-%s" type slot)))
         (initfn (intern (format "%s-init-%s" type slot)))
         (init-method (intern (format "%s--lazy-init-%s" type slot)))
         (constructor (or constructor (intern (format "make-%s" type))))
         ;; Use consistent symbols for runtime args
         (obj 'obj)
         (callback 'callback)
         (opts-sym (gensym "opts"))
         (replacements `((<> . ,obj)
                         (<cb> . ,callback)
                         (<callback> . ,callback)))
         (fn-body (concur-expand-placeholders fn replacements)))
    `(progn
       ;; Async getter
       (defun ,getter (,obj)
         ,(format "Lazily retrieve slot `%s` for object of type `%s`." slot type)
         (let* ((,opts-sym (if (concur-lazy-opts-p ,options)
                               ,options
                             (concur-lazy-opts-create-defaults ,options))))
           (lazy--await-slot! ,obj ',slot ,opts-sym ',fn-body
                              (lambda (resolved-value)
                                (setf (slot-value ,obj ',slot) resolved-value)))))

       ;; Setter
       (unless (fboundp ',setter)
         (cl-defun ,setter (val ,obj)
           ,(format "Set slot `%s` on object of type `%s`." slot type)
           (setf (slot-value ,obj ',slot) val)))

       ;; Manual eager init function
       (defun ,initfn (,obj)
         ,(format "Manually trigger lazy fetch for slot `%s` on type `%s`." slot type)
         (let ((,opts-sym (if (concur-lazy-opts-p ,options)
                              ,options
                            (concur-lazy-opts-create-defaults ,options))))
           (when (concur-lazy-opts-auto-fetch ,opts-sym)
             (lazy--maybe-init-slot ,obj ',slot ,opts-sym ',fn-body
                                    (lambda (resolved-value)
                                      (setf (slot-value ,obj ',slot) resolved-value))))))

       ;; Hook into constructor for structs
       (unless (get ',type ',init-method)
         (advice-add #',constructor :filter-return
                     (lambda (obj)
                       (funcall #',initfn obj)
                       obj))
         (put ',type ',init-method t)))))

(cl-defmacro concur-lazy-slot! (slot type expr &key async auto-fetch options)
  "Define a lazy accessor for SLOT in a `cl-defstruct` of TYPE.

This wraps either `concur-lazy!` (for sync) or `concur-lazy-async!` (for async) accessor creation,
optionally supporting extra `:auto-fetch` behavior and merged `:options`.

Arguments:
- SLOT: The struct slot to define an accessor for.
- TYPE: The struct type symbol.
- EXPR: A function or body computing the value lazily.
- :async: If non-nil, defines an async accessor via `concur-lazy-async!`.
- :auto-fetch: Optional property passed to async fetchers.
- :options: Extra keyword arguments passed to the underlying fetch logic."
  (let* ((type-sym (or type 'generic))
         ;; Wrap options if :auto-fetch is provided.
         (options-arg (when auto-fetch
                        (if options  
                            `(lambda () (append '(:auto-fetch ,auto-fetch) ,options))
                          `(lambda () '(:auto-fetch ,auto-fetch))))))  ;; Handle nil options
    (if async
        ;; Delegate to async accessor macro
        `(concur-lazy-async! ,slot ,expr 
          :type ,type-sym 
          ,@(when options-arg `(:options ,options-arg))) 
       ;; Otherwise, define standard sync lazy accessor          
      `(concur-lazy! ,slot ,expr :type ,type-sym))))

(defmacro concur-lazy-safe-sync! (slot type fn)
  "Define a safe synchronous accessor for SLOT in TYPE using FN.
Checks struct type and slot validity, and returns nil if result is 'unset.

Arguments:
- SLOT: Slot name to define the accessor for.
- TYPE: Struct type symbol.
- FN: Expression to compute the slot value, may use `<>` for object."
  (let* ((fn-name (intern (format "%s-%s" type slot)))
         (predicate (intern (format "%s-p" type)))
         (obj (gensym "obj"))
         (replacements `(( "<>" . ,obj)))
         (fn-expanded (concur-expand-placeholders fn replacements)))
    `(defun ,fn-name (,obj)
       (unless (,predicate ,obj)
         (error "[lazy-safe-sync!] Invalid object type: expected %s, got %s"
                ',type (type-of ,obj)))
       (let ((val ,fn-expanded))
         (if (eq val 'unset)
             nil
           val)))))

(defmacro concur-accessors! (&rest args)
  "Define a set of accessor functions for a struct TYPE.

This macro supports four kinds of accessors:

  - :eager      Define standard eager accessors that retrieve values already stored in the struct.
  - :async      Define asynchronous lazy accessors using `define-lazy-slot!` with :async t.
  - :sync       Define synchronous lazy accessors using `define-lazy-slot!`.
  - :safe-sync  Define synchronous accessors wrapped with `lazy-safe-sync!`, ensuring safer evaluation.

Each accessor group accepts a list of field specifications:
  - For :eager: a list of field names (symbols).
  - For :async and :sync: a list of (NAME BODY &optional PROPERTIES), where BODY is the expression to compute the value.
    Async fields support an optional :auto-fetch property to indicate whether to trigger computation eagerly.
  - For :safe-sync: a list of (NAME BODY) forms.

Additionally, this macro auto-generates a fallback TYPE-get function if one does not already exist.
The generated getter attempts to use a slot-specific accessor if defined, and falls back to direct slot lookup."
  (declare (indent defun))
  (let* ((type (plist-get args :type))
         (eager (plist-get args :eager))
         (async (plist-get args :async))
         (sync (plist-get args :sync))
         (safe-sync (plist-get args :safe-sync))
         (type-name (symbol-name type))
         (type-predicate (intern (format "%s-p" type-name)))
         (type-getter (intern (format "%s-get" type-name)))
         forms)

    ;; Auto-generate a fallback -get method if it doesn't exist
    (unless (fboundp type-getter)
      (push
      `(defun ,type-getter (instance slot)
          (unless (,type-predicate instance)
            (error "[generic!] Invalid object type: expected %s, got %s"
                  ',type (type-of instance)))
          (let ((accessor (intern (format "%s-%s" ',type slot))))
            (if (fboundp accessor)
                (funcall accessor instance)
              (cl-struct-slot-value ',type slot instance))))
      forms))

    ;; Eager accessors using define-generic-accessor!
    (dolist (field eager)
      (let ((fn-name (intern (format "%s-%s" type-name field))))
        (push
         `(concur-generic-accessor! ,field ,type)
         forms)))

    ;; Async accessors using define-lazy-slot! for async
    (dolist (field async)
      (let* ((name (nth 0 field))
             (body (nth 1 field))
             (props (nthcdr 2 field))
             (auto-fetch (plist-get props :auto-fetch)))
        (push
         `(concur-lazy-slot! ,name ,type ,body
            :async t
            ,@(when auto-fetch `(:auto-fetch ,auto-fetch)))
         forms)))

    ;; Sync accessors using define-lazy-slot! for sync
    (dolist (field sync)
      (let* ((name (nth 0 field))
             (body (nth 1 field)))
        (push
         `(concur-lazy-slot! ,name ,type ,body)
         forms)))

    ;; Safe sync accessors
    (dolist (field safe-sync)
      (let* ((name (nth 0 field))
            (body (nth 1 field)))
        (push
        `(concur-lazy-safe-sync! ,name ,type ,body)
        forms)))

    `(progn ,@(nreverse forms))))

(defun lazy--maybe-init-slot (obj slot opts fn-body callback)
  "Initialize lazy SLOT on OBJ using FN-BODY and OPTS.

FN-BODY is a callback-style thunk that takes (OBJ CALLBACK), which will be
wrapped into a `concur-promise`. This function returns either the resulting
promise (if auto-fetch is enabled), or a function to force the future on demand.

OPT fields supported:
- `:auto-fetch`    — immediately trigger the promise.
- `:timeout`       — timeout the promise after N seconds.
- `:retry`         — retry the promise with optional interval/limit/test.

The future is stored in SLOT and will be resolved or deferred accordingly.

CALLBACK is passed to the FN-BODY if used interactively or eagerly."
  (unless (and obj slot fn-body)
    (error "lazy--maybe-init-slot: must provide OBJ, SLOT, and FN-BODY"))

  (let* ((thunk (lambda ()
                  (concur-promise-from-callback
                   (lambda (cb) (funcall fn-body obj cb)))))
         (promise (when (concur-lazy-opts-auto-fetch opts)
                    (funcall thunk)))

         ;; Retry logic
         (retry-options (concur-lazy-opts-retry opts))
         (promise (if (and retry-options promise)
                      (concur-promise-retry
                       (lambda () promise)
                       :interval (plist-get retry-options :interval)
                       :limit    (plist-get retry-options :limit)
                       :test     (plist-get retry-options :test))
                    promise))

         ;; Timeout logic
         (timeout (concur-lazy-opts-timeout opts))
         (promise (if (and timeout promise)
                      (concur-promise-timeout promise timeout)
                    promise))

         ;; Wrap in a future
         (future (concur-future-create
                  :thunk thunk
                  :promise promise
                  :evaluated? (concur-lazy-opts-auto-fetch opts))))

    (setf (slot-value obj slot) future)

    (when (concur-lazy-opts-auto-fetch opts)
      (log! "Slot `%s` on `%s` initialized with auto-fetch." slot obj))

    (or promise
        ;; Return a forceable thunk if auto-fetch is off
        (lambda () (concur-future-force future)))))

(defun lazy--await-slot! (obj slot opts fn-body callback)
  "Synchronously fetch or return cached value of OBJ's SLOT via FN-BODY and CALLBACK.

This function inspects the current state of SLOT:
- If already resolved: return the value.
- If a future and auto-fetch is enabled: force and await the promise.
- If uninitialized: invoke `lazy--maybe-init-slot` and possibly force it.

If AUTO-FETCH is disabled, this will only initialize the slot and return a deferred value (future or thunk).

OPT supports `:auto-fetch`, `:retry`, `:timeout`, etc."
  (unless (and obj slot fn-body)
    (error "lazy--await-slot!: must provide OBJ, SLOT, and FN-BODY"))

  (let* ((val (slot-value obj slot))
         (auto-fetch (concur-lazy-opts-auto-fetch opts)))

    (cond
     ;; Already resolved (primitive or cached)
     ((and val
           (not (concur-future-p val))
           (not (concur-promise-p val)))
        (log! "Slot `%s` on `%s` already resolved to: %s" slot obj val)
      val)

     ;; Slot holds a future — attempt resolution
     ((and (concur-future-p val) auto-fetch)
      (let ((promise (concur-future-force val)))
        (cond
         ((concur-promise-p promise)
          (let ((resolved (concur-promise-await promise)))
            (setf (slot-value obj slot) resolved)
            (log! "Slot `%s` on `%s` auto-fetched to: %s" slot obj resolved)
            resolved))
         (t
            (log! "Slot `%s` on `%s` held a non-promise future: %S" slot obj promise)
          val))))

     ;; Otherwise: initialize it lazily
     (t
      (let ((result (lazy--maybe-init-slot obj slot opts fn-body callback)))
        (cond
         ((and auto-fetch (concur-promise-p result))
          (let ((resolved (concur-promise-await result)))
            (setf (slot-value obj slot) resolved)
            (log! "Slot `%s` on `%s` post-init resolved to: %s" slot obj resolved)
            resolved))

         ;; If result is primitive or already resolved
         ((and auto-fetch result)
          (setf (slot-value obj slot) result)
          (log! "Slot `%s` on `%s` post-init returned non-promise: %s" slot obj result)
          result)

         ;; Lazy mode (no fetch)
         (t
          (log! "Slot `%s` on `%s` initialized for deferred resolution." slot obj)
          (slot-value obj slot))))))))

(provide 'concur-slot)
;;; concur-slot.el ends here
