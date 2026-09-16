(define-module (live-agent policy)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:export (mcp-tool-hints tool-decision run-argv-of run-allowed?))
;; No live-image binding can override this decision. Three modes: manual asks
;; before each tool except allowlisted runs, plan permits reads only, and
;; autopilot runs everything without asking. Nothing infers approval.
(define (run-argv-of arguments)
  (let ((value (json-object-ref arguments "argv" #f)))
    (if (and (json-array? value) (every string? (json-array-items value)))
        (json-array-items value)
        '())))
;; Exact leading-element match: ("cargo" "test") allows ("cargo" "test" "--" "x")
;; and never ("cargo" "publish").
(define (run-allowed? argv prefixes)
  (and (pair? argv)
       (any (lambda (prefix)
              (and (<= (length prefix) (length argv))
                   (equal? prefix (take argv (length prefix)))))
            prefixes)))
;; MCP tools carry the server's own hints; the runtime installs a lookup
;; returning ((read-only . bool) (destructive . bool) (open-world . bool)) or #f.
(define mcp-tool-hints (make-parameter (lambda (name) #f)))
(define (mcp-tool-name? name) (and (string? name) (string-contains name "__") #t))
;; sandboxed? says the run would execute inside the agentkernel sandbox, which
;; is its own boundary: manual and autopilot let it run without asking or judging.
(define* (tool-decision mode name arguments #:optional (run-allow '()) (mcp-allow '()) (sandboxed? #f))
  (let ((read-only? (or (member name '("read" "rg" "traces" "recall" "status" "diff" "skill" "job" "tool_search" "spawn"))
                        (and (mcp-tool-name? name)
                             (let ((hints ((mcp-tool-hints) name)))
                               (and hints (assq-ref hints 'read-only)
                                    (not (assq-ref hints 'destructive)) (not (assq-ref hints 'open-world)))))
                        (and (string=? name "ui") (equal? (json-object-ref arguments "action" "get") "get"))
                        (and (string=? name "extension")
                             (equal? (json-object-ref arguments "action" #f) "list"))))
        (allowed-run? (and (string=? name "run")
                           (run-allowed? (run-argv-of arguments) run-allow))))
    (case mode
      ((manual) (if (or allowed-run? (and (string=? name "run") sandboxed?) (and (mcp-tool-name? name) (member name mcp-allow))) 'allow 'ask))
      ((plan) (if read-only? 'allow 'deny))
      ;; Autopilot resolves reads and allowlists here; everything else is judged.
      ((autopilot) (if (or read-only? allowed-run? (and (string=? name "run") sandboxed?) (and (mcp-tool-name? name) (member name mcp-allow))) 'allow 'judge))
      (else 'deny))))
