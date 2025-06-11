# Concur.el

> A suite of composable concurrency primitives for modern Emacs Lisp.

**Concur.el** provides a powerful set of tools to simplify asynchronous programming in Emacs. Inspired by patterns from modern languages, it helps you manage complex, non-blocking workflows with promises, futures, and high-level async utilities, making your code more readable, robust, and maintainable.

## Key Features

* **Promises & Futures**: A complete implementation for managing asynchronous results.

* **High-Level Async API**: Use `concur:async!` to run tasks in deferred, delayed, background process, or native thread modes.

* **Cooperative Await**: Block until a result is ready without freezing Emacs entirely using `concur:await!`.

* **Ergonomic Chaining**: Write clean, sequential-looking async code with `concur:let-promise*` (sequential), `concur:let-promise` (parallel), and `concur:chain`.

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

The heart of the library is the `concur:async!` / `concur:await!` pattern.

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
   'thread ;; Run this in a background OS thread
   (format "fetch-%s" username)))

;; Await the result of the async operation
(let ((result (concur:await! (fetch-user-data "alice") :timeout 5)))
  (message "Result: %s" result))
;; => Displays "Result: Data for alice" after 1 second.

;; Handle an error from a rejected promise
(condition-case err
    (concur:await! (fetch-user-data "error") :timeout 5)
  (error (message "Caught expected error: %s" (cadr err))))
;; => Displays "Caught expected error: User not found"
```

## Declarative Async with `let-promise`

For more complex workflows, the `let-promise` macros let you write clean, sequential-looking code that is actually asynchronous under the hood.

### `concur:let-promise*` (Sequential)

Each binding waits for the previous one to complete. This is perfect for dependent operations.

```emacs-lisp
(concur:let-promise*
    ((user-id (concur:async! (lambda () (sleep-for 0.5) "user-123")))
     (posts   (concur:async! (lambda ()
                              (message "Fetching posts for %s" user-id)
                              (sleep-for 0.5)
                              '("Post 1" "Post 2"))))
     (post-count (length posts)))

  ;; This body only runs after both promises have resolved sequentially.
  (message "User %s has %d posts." user-id post-count))
;; Total execution time: ~1.0 second
```

### `concur:let-promise` (Parallel)

All bindings are executed concurrently. This is ideal for independent setup tasks.

```emacs-lisp
(concur:let-promise
    ((user-settings (concur:async! (lambda () (sleep-for 1) "Settings Loaded")))
     (theme-data    (concur:async! (lambda () (sleep-for 0.7) "Theme Loaded"))))

  ;; This body runs after both promises resolve.
  (message "Setup complete: %s, %s" user-settings theme-data))
;; Total execution time: ~1.0 second (the duration of the longest task)
```

## Advanced Chaining with `concur:chain`

For fine-grained control over promise pipelines, `concur:chain` and `concur:chain-when` provide a powerful threading macro inspired by functional programming.

### `concur:chain`

Threads a promise through a series of steps. The special variable `<>` holds the resolved value of the previous step, and `<!>` holds the error in a `:catch` block.

```emacs-lisp
(concur:chain (concur:async! (lambda () 10) 'deferred)
  :then (lambda ()
          (message "Step 1: Received %d" <>)
          (+ <> 5))
  :then (lambda ()
          (message "Step 2: Received %d" <>)
          ;; Return another promise
          (concur:async! (lambda () (* <> 2)) 'deferred))
  :then (lambda ()
          (message "Step 3: Final value is %d" <>)
          (if (> <> 40)
              (error "Value too large")
            (format "Final result: %d" <>)))
  :catch (lambda ()
           (message "An error occurred: %S" <!>)))
```

### `concur:chain-when`

This variant is identical to `concur:chain`, but it **short-circuits** the chain if any `:then` step resolves to `nil`. Subsequent `:then` steps are skipped, and control jumps to the next `:catch` or `:finally` block.

```emacs-lisp
(concur:chain-when (concur:resolved! "some-value")
  :then (lambda ()
          (message "This step will run.")
          ;; This resolves to nil, so the next :then is skipped
          nil)
  :then (lambda ()
          (message "This step will NOT run.")
          "unreachable")
  :finally (lambda ()
             (message "Finally block always runs.")))

;; The final promise resolves to `nil` (the value that caused the short-circuit).
```

## Parallel & Sequential Mapping

Easily apply an asynchronous function over a list of items.

* **`concur:sequence!`**: Processes items one by one.

* **`concur:parallel!`**: Processes all items at once.

```emacs-lisp
(defun process-item-async (item)
  (concur:async! (lambda () (sleep-for 0.2) (format "Processed %s" item)) 'thread))

;; Run in parallel
(let ((results (concur:await! (concur:parallel! '("A" "B" "C") #'process-item-async))))
  (message "Parallel results: %S" results))
;; => Takes ~0.2 seconds total.

;; Run in sequence
(let ((results (concur:await! (concur:sequence! '("A" "B" "C") #'process-item-async))))
  (message "Sequential results: %S" results))
;; => Takes ~0.6 seconds total.
```

## Contributing

Contributions are welcome! Please feel free to open an issue or pull request on GitHub.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
