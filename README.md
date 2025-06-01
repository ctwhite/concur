# concur.el - Asynchronous Programming Utilities for Emacs Lisp

`concur.el` is a suite of Emacs Lisp libraries designed to simplify asynchronous programming, manage external processes, and orchestrate concurrent tasks within Emacs. It provides a robust Promise implementation and higher-level utilities for common asynchronous workflows.

## Overview

The `concur.el` ecosystem aims to bring modern asynchronous patterns to Emacs Lisp, making it easier to write non-blocking code, manage external commands, and compose complex sequences of operations that may involve delays or external I/O.

Key modules include:

* **`concur-promise.el`**: The core of the ecosystem. It provides:
  * A lightweight yet comprehensive **Promise implementation** (`concur:make-promise`, `concur:with-executor`, `concur:resolve`, `concur:reject`, etc.).
  * Powerful **promise chaining macros**: `concur:chain` (formerly `concur->`) and `concur:chain-when` (formerly `concur-?>`) with a rich set of clauses and syntactic sugar for building readable asynchronous pipelines.
  * **Promise composition utilities**: `concur:all`, `concur:race`, `concur:any`, `concur:all-settled`.
    * Helper functions for common async patterns: `concur:delay`, `concur:timeout`, `concur:retry`, `concur:map-series`, `concur:map-parallel`, `concur:defer`.
    * Integration with `concur-cancel.el` for **cancellation support**.

* **`concur-exec.el`** (formerly `concur-proc.el`): For running external OS commands asynchronously.
  * `concur:process`: A low-level function to start an external process and get a promise that resolves with detailed results (stdout, stderr, exit code).
  * `concur:command`: A higher-level convenience function that takes a command string (or list), handles argument parsing, and returns a promise typically resolving with the command's stdout.
  * `concur:define-command!`: A macro to easily define new, reusable interactive or non-interactive Emacs commands that execute external programs asynchronously.
  * `concur-pipe!`: A macro to chain multiple asynchronous commands, piping the stdout of one to the stdin of the next, similar to shell pipes.

* **`concur-cancel.el`** (Assumed Dependency): Provides cancellation token support, allowing for cooperative cancellation of asynchronous operations.

* **`concur-future.el`** (Mentioned as part of the ecosystem): Provides further utilities for managing future-like computations.

## Installation

Typically, you would add `concur.el` (and its constituent files like `concur-promise.el`, `concur-exec.el`) to your Emacs load path and require the main library or specific modules as needed.

Example using `use-package` (if `concur.el` were a package providing all features):

```elisp
(use-package concur
  :ensure t ; Or :straight t, or other package manager configuration
  :config
  ;; Your configurations or keybindings
  )
```

Ensure `concur-promise.el`, `concur-exec.el`, and `concur-cancel.el` are correctly loaded.

## Core Concepts

### Promises (`concur-promise.el`)

A promise represents the eventual result of an asynchronous operation. It can be in one of three states:

* **Pending**: The initial state; the operation has not yet completed.
* **Fulfilled (Resolved)**: The operation completed successfully, and the promise has a resulting value.
* **Rejected**: The operation failed, and the promise has a reason for the failure (an error).

You can create promises using:

* `(concur:make-promise)`: For an empty promise you resolve/reject later.
* `(concur:with-executor (lambda (resolve reject) ...))`: To start an async task immediately.
* `(concur:resolved! value)`: For an already resolved promise.
* `(concur:rejected! error)`: For an already rejected promise.

### Chaining Macros: `concur:chain` and `concur:chain-when`

These macros are the primary way to build readable asynchronous workflows. They take an initial promise-producing expression and a series of steps.

```elisp
(concur:chain (initial-promise-producing-form)
  ;; Step 1: Direct form, uses <> as resolved value from initial promise
  (process-value <>)

  ;; Step 2: Use :then for more complex logic
  :then ((let ((processed-data <>)) ; <> is result of (process-value <>)
           (another-async-op processed-data))) ; This should return a promise

  ;; Step 3: Handle potential errors from any preceding step
  :catch ((log! :error "Chain failed: %S" <!>) ; <!> is the error object
          "Recovered Value") ; The catch block can resolve the chain

  ;; Step 4: Always run this, regardless of success or failure
  :finally ((message "Chain finished.")))
```

**Placeholders:**

* `<>`: In `:then` handlers or direct forms, this is bound to the resolved value of the preceding promise.
* `<!>`: In `:catch` handlers (or the rejection part of a `:then` clause), this is bound to the error/rejection reason.

**Supported Clauses (for `concur:chain` and `concur:chain-when`):**

* **Direct Form `FORM`**: Implicitly a `:then` step. `(lambda (<>) FORM)`.
* **`:then ON-RESOLVED-FORMS`** or **`:then (ON-RESOLVED-FORMS ON-REJECTED-FORMS)`**:
    Explicit success and optional failure handlers.
* **`:catch HANDLER-FORM-OR-FORMS`**: Handles rejections from any prior step.
* **`:finally HANDLER-FORM-OR-FORMS`**: Always executes.
* **`:let BINDINGS`**: `(let* BINDINGS ...)` wraps the rest of the chain.
* **`:if TEST-FORM` / `:when TEST-FORM` / `:guard TEST-FORM`**:
    Continues if `TEST-FORM` (evaluating `<>`) is true, else rejects.
* **`:assert TEST-FORM "ERROR-MESSAGE"`**: Errors if `TEST-FORM` is false.
* **`:tap SIDE-EFFECT-FORM-OR-FORMS`**: Executes for side effects, passes `<>` through.
* **`:all LIST-OF-PROMISES`**: Replaces current promise with `(concur:all ...)`.
* **`:race LIST-OF-PROMISES`**: Replaces current promise with `(concur:race ...)`.

**Syntactic Sugar (expanded into canonical clauses):**

* **`:map FORM`**: If `<>` is a list, applies `(lambda (item) (let ((<> item)) FORM))` to each item. If `<>` is not a list, applies `(lambda (<>) FORM)` to `<>`. Result is a new list or single transformed value.
* **`:filter PREDICATE-FORM`**: If `<>` is a list, filters it using `PREDICATE-FORM`. If `<>` is not a list and predicate fails, rejects.
* **`:each FORM`**: Like `:map` but for side-effects (transformed to `:tap`).
* **`:reduce (INIT-FORM BODY-LAMBDA)`**: If `<>` is a list, reduces it. `BODY-LAMBDA` is `(lambda (acc item) ...)`.
* **`:sleep MILLISECONDS`**: Delays the chain, then passes original `<>` through.
* **`:log`**: Logs current `<>` with a default message.
* **`:log "MESSAGE"`** or **`:log MESSAGE-FORM`**: Logs `MESSAGE` (or evaluated `MESSAGE-FORM`) followed by `<>`.
* **`:log "FORMAT-STRING" &rest ARGS`**: Logs using `FORMAT-STRING` and `ARGS`, appending `<>` to the format arguments.
* **`:retry N BODY-FORM`**: Retries the promise-returning `BODY-FORM` up to `N` times.

**`concur:chain-when`**: Similar to `concur:chain`, but if any step (not `:catch` or `:finally`) resolves to `nil`, subsequent data-processing steps are skipped, and the chain resolves with `nil`.

## Usage Examples

### Basic Promise Chaining

```elisp
(require 'concur-promise)

(defun my-async-task (input)
  (concur:with-executor
   (lambda (resolve reject)
     (run-at-time 0.1 nil ; Simulate async work
                  (if (> input 0)
                      (funcall resolve (* input 2))
                    (funcall reject "Input must be positive"))))))

(concur:chain (my-async-task 10) ; Initial promise
              ;; Step 1: Direct form, <> will be 20
              (message "First result: %S" <>)
              (+ <> 5) ; Result of this form (25) is passed to next

              ;; Step 2: :then clause
              :then ((message "Second result: %S" <>) ; <> is 25
                     (concat "Final: " (number-to-string <>)))

              ;; Step 3: :catch for any errors above
              :catch ((message "Error occurred: %S" <!>)
                      "Error handled, default value returned")

              ;; Step 4: :finally always runs
              :finally (message "Promise chain finished."))

;; To get the final result (e.g., for testing or top-level):
;; (concur:await (the-whole-concur:chain-form-above))
```

### Running External Commands (`concur-exec.el`)

```elisp
(require 'concur-exec)

;; Example 1: Simple command, get stdout
(concur:chain (concur:command "ls -l /tmp")
              :then (message "ls output:\n%s" <>))

;; Example 2: Command with input and error handling
(concur:chain
    (concur:command "grep 'error'"
                         :input-string "line1\nline with error\nline3"
                         :die-on-error t) ; concur:command will error if grep exits non-zero
  :then (message "Grep found:\n%s" <>)
  :catch (message "Grep failed or found nothing. Error: %S" <!>))

;; Example 3: Using the concur:define-command! macro
(concur:define-command! my-git-status (dir)
  "Get git status for DIR asynchronously."
  (interactive "DDirectory: ") ; Makes M-x my-git-status interactive
  "git status -s" ; Command string
  :cwd dir
  :die-on-error nil) ; Don't signal Emacs error, just let promise reject

(concur:chain (my-git-status "~/projects/my-repo")
              :then (message "Git Status:\n%s" <>)
              :catch (message "Git status failed: %S" <!>))

;; Example 4: Piping commands
(concur:chain
    (concur-pipe!
     "ls -1 /usr/bin"
     '("grep" "emacs") ; Command as a list
     "wc -l")
  :then ((message "Number of emacs related files in /usr/bin: %s" (s-trim <>))))
```

### Using Sugar Keywords with `concur:chain`

```elisp
(concur:chain (concur:resolved! '(1 2 3 4 5))
              :filter (oddp <>)      ; <> is item, result: (1 3 5)
              :map (* <> 10)         ; <> is item, result: (10 30 50)
              :reduce (0 (lambda (acc item) (+ acc item))) ; result: 90
              :sleep 500             ; Waits 500ms, <> is still 90
              :log "Final sum after sleep" ; Logs "Final sum after sleep: 90"
              :then ((message "All done! Result: %S" <>)))
```

## API Reference

Please refer to the docstrings and commentaries within the individual files for detailed API documentation:

* `concur-promise.el`: For core promise functions and the `concur:chain`/`concur:chain-when` macros.
* `concur-exec.el`: For `concur:process`, `concur:command`, `concur:define-command!`, and `concur-pipe!`.
* `concur-cancel.el`: For cancellation token functionality.
