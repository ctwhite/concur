# Concur.el

> A suite of composable concurrency primitives for modern Emacs Lisp.

**Concur.el** provides a powerful set of tools to simplify asynchronous programming in Emacs. Inspired by patterns from modern languages, it helps you manage complex, non-blocking workflows with promises, futures, and high-level async utilities, making your code more readable, robust, and maintainable.

## Key Features

* **Promises & Futures**: A complete implementation for managing asynchronous results.

* **High-Level Async API**: Use `concur:async!` to run tasks in deferred, delayed, background process, or native thread modes.

* **Cooperative Await**: `concur:await` non-blockingly suspends when used inside `defasync!` and blockingly (but cooperatively) waits for a promise to settle when used in normal functions.

* **Ergonomic Chaining**: Write clean, sequential-looking async code with `concur:let-promise*` (sequential), `concur:let-promise` (parallel), and the powerful `concur:chain` macro.

* **Async Process Execution**: Easily run and pipe external commands with `concur:command` and `concur:pipe!`.

* **Cancellation**: Gracefully cancel long-running operations with `concur-cancel-token`.

* **Debugging**: Enhanced error handling with asynchronous stack traces to pinpoint failures in background tasks.

* **Lifecycle Hooks**: Monitor and trace async operations for better observability.

## Installation

The recommended way to install is from [MELPA](https://melpa.org/).

With `use-package`:

```emacs-lisp
(use-package concur
  :ensure t)
```

Or with `package.el`:

1. `M-x` package-install

2. `concur`

## Quick Start: The Core API

The heart of the library is the `concur:async!` / `concur:await` pattern.

```emacs-lisp
(defun fetch-user-data (username)
  "Simulates a network request to fetch user data."
  (concur:async!
   (lambda ()
     (message "Fetching data for %s..." username)
     (sleep-for 1) ; Simulate network latency
     (if (string-equal username "error")
         (error "User not found")
       (format "Data for %s" username)))
   'deferred ;; Run this in a deferred Emacs job (non-blocking)
   (format "fetch-%s" username)))

;; Await the result of the async operation (concur:await takes a promise form)
(let ((result (concur:await (fetch-user-data "alice") :timeout 5)))
  (message "Result: %s" result))
;; => Displays "Result: Data for alice" after 1 second.

;; Handle an error from a rejected promise
(condition-case err
    (concur:await (fetch-user-data "error") :timeout 5)
  (error (message "Caught expected error: %s" (cadr err))))
;; => Displays "Caught expected error: User not found"
```

## Declarative Async with `let-promise`

For more complex workflows, the `let-promise` macros let you write clean, sequential-looking code that is actually asynchronous under the hood.

### `concur:let-promise*` (Sequential)

Each binding waits for the previous one to complete. This is perfect for dependent operations.

```emacs-lisp
(concur:let-promise*
    ((user-id (concur:async! (lambda () (sleep-for 0.5) "user-123") 'deferred))
     (posts   (concur:async! (lambda ()
                               (message "Fetching posts for %s" user-id)
                               (sleep-for 0.5)
                               '("Post 1" "Post 2")) 'deferred))
     (post-count (length posts)))

  ;; This body only runs after both promises have resolved sequentially.
  (message "User %s has %d posts." user-id post-count))
;; Total execution time: ~1.0 second
```

### `concur:let-promise` (Parallel)

All bindings are executed concurrently. This is ideal for independent setup tasks.

```emacs-lisp
(concur:let-promise
    ((user-settings (concur:async! (lambda () (sleep-for 1) "Settings Loaded") 'deferred))
     (theme-data    (concur:async! (lambda () (sleep-for 0.7) "Theme Loaded") 'deferred)))

  ;; This body runs after both promises resolve.
  (message "Setup complete: %s, %s" user-settings theme-data))
;; Total execution time: ~1.0 second (duration of the longest task)
```

## Advanced Chaining with `concur:chain`

For fine-grained control over promise pipelines, `concur:chain` and `concur:chain-when` provide a powerful threading macro inspired by functional programming.

### `concur:chain`

Threads a promise through a series of steps. The special variable `<>` holds the resolved value of the previous step, and `<!>` holds the error in a `:catch` block.

```emacs-lisp
(concur:chain (concur:async! (lambda () 10) 'deferred)
  (:then (lambda ()
           (message "Step 1: Received %d" <>)
           (+ <> 5)))
  (:then (lambda ()
           (message "Step 2: Received %d" <>)
           ;; Return another promise, which the chain will wait for
           (concur:async! (lambda () (* <> 2)) 'deferred)))
  (:then (lambda ()
           (message "Step 3: Final value is %d" <>)
           (if (> <> 40)
               (error "Value too large")
             (format "Final result: %d" <>))))
  (:let ((my-local-var "A local value")))
  (:then (lambda ()
           (message "Step 4: Inside let. Local var: %S. Final value: %S" my-local-var <>)
           (format "Final result after let: %d" <>)))
  (:catch (lambda ()
            (message "An error occurred: %S" <!>)))
  (:finally (lambda ()
              (message "Finally block always runs."))))
;; This chain will eventually resolve with "Final result after let: 40".
```

### `concur:chain-when`

This variant is identical to `concur:chain`, but it **short-circuits** the chain if any **`then` step** resolves to `nil`. Subsequent `then` steps (defined with `(:then (lambda ...))` or as bare `(lambda ...)` forms) are skipped, and control jumps to the next `:catch` or `:finally` block.

```emacs-lisp
(concur:chain-when (concur:resolved! "initial-value")
  (:then (lambda ()
           (message "Step A: This runs (input: %S)" <>)
           ;; Resolving to nil will short-circuit subsequent :then steps
           nil))
  (:then (lambda ()
           (message "Step B: This will NOT run.")
           "unreachable"))
  (:then (lambda ()
           (message "Step C: This explicit :then WILL run (input: %S)." <>)
           "explicit-then-result"))
  (:then (lambda ()
           (message "Step D: This will NOT run (input: %S)." <>)
           "unreachable-again"))
  (:catch (lambda ()
            (message "Step E: Caught error: %S (will not be called unless previous step errors)" <!>)))
  (:finally (lambda ()
              (message "Step F: Finally block always runs."))))

;; The final promise from this chain will resolve to "explicit-then-result"
;; (the value of the last executed step before the chain completes).
```

## Parallel & Sequential Mapping

Easily apply an asynchronous function over a list of items.

* **`concur:sequence!`**: Processes items one by one.

* **`concur:parallel!`**: Processes all items at once.

```emacs-lisp
(defun process-item-async (item)
  (concur:async! (lambda () (sleep-for 0.2) (format "Processed %s" item)) 'deferred))

;; Run in parallel
(let ((results (concur:await (concur:parallel! '("A" "B" "C") #'process-item-async))))
  (message "Parallel results: %S" results))
;; => Takes ~0.2 seconds total.

;; Run in sequence
(let ((results (concur:await (concur:sequence! '("A" "B" "C") #'process-item-async))))
  (message "Sequential results: %S" results))
;; => Takes ~0.6 seconds total.
```

## `concur:command` & `concur:pipe!`

Run external processes asynchronously with promise-based results.

```emacs-lisp
;; Simple command execution
(let ((output (concur:await (concur:command "echo" :args '("Hello World") :die-on-error t))))
  (message "Command Output: %S" output))
;; => Displays "Command Output: \"Hello World\""

;; Piping commands (stdout of one becomes stdin of next)
(let ((result (concur:await (concur:pipe!
                             '("echo" "one\\ntwo\\nthree")
                             '("grep" "two")
                             '("wc" "-l")))))
  (message "Pipe result: %S" result))
;; => Displays "Pipe result: \"1\""
```

## Contributing

Contributions are welcome! Please feel free to open an issue or pull request on GitHub.
