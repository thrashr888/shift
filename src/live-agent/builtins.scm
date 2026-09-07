(define-module (live-agent builtins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (enabled-builtins builtin-enabled? builtin-ref))

;; Process-owned configuration, never a binding in the live Scheme image.
;; No discovery, package manager, registration callbacks, or dependency graph.
(define enabled-builtins
  (let* ((raw (getenv "SHIFT_BUILTINS"))
         (names (if raw
                    (map string->symbol
                         (filter (lambda (s) (not (string-null? s)))
                                 (map string-trim-both (string-split raw #\,))))
                    '(ollama openai claude tracing mcp coding))))
    (unless (every (lambda (name) (memq name '(ollama openai claude tracing mcp coding))) names)
      (error "unknown built-in in SHIFT_BUILTINS" raw))
    (delete-duplicates names)))

(define (builtin-enabled? name) (if (memq name enabled-builtins) #t #f))

(define (builtin-ref name binding)
  (unless (builtin-enabled? name)
    (error "built-in is disabled; enable it in SHIFT_BUILTINS" name))
  (module-ref (resolve-interface (list 'shift name)) binding))
