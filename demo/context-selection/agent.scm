;; A deliberately flawed live image for the context-selection demo.

(define agent-name "context-selection-demo")
(define agent-provider 'ollama)
(define agent-model "qwen3.8:27b-mlx")
(define agent-base-url "http://127.0.0.1:11434")
(define agent-api-key-environment #f)
(define agent-stream? #t)
(define agent-thinking #f)
(define agent-keep-alive "10m")
(define agent-max-tool-rounds 6)
(define agent-compaction-threshold 80)
(define agent-compaction-keep-recent 24)

(define agent-system-prompt
  (string-append
   "You demonstrate live context repair. Use at most two sentences per reply. "
   "Answer questions only from this turn's injected context and name its source path. "
   "Do not guess other sources or configuration values. Do not call tools for the "
   "initial port question. Only repair behavior when explicitly asked to fix it. "
   "Repair the Scheme function agent-select-context with live_eval and a define form. "
   "It takes text and returns a list of paths. First lowercase the input with "
   "string-downcase. If the lowercase input contains port OR deploy, return "
   "(list \"demo/context-selection/context/current-runbook.md\"); otherwise return '(). "
   "Candidate checks include uppercase PORT and DEPLOY. Comparing the original "
   "text case-sensitively will fail. A rejection names the failing query; fix the "
   "logic for that query, not the define syntax. Before EVERY live_eval attempt, "
   "briefly explain the function change and expected behavior. After success, "
   "report the before/after generations and invite a retry. The current turn stays "
   "pinned; the new selector is used on the next turn."))

(define agent-tools '(live_eval))
(define agent-shell-policy 'deny)

;; Intentionally wrong: the first turn selects the obsolete runbook.
(define (agent-select-context text)
  (let ((query (string-downcase text)))
    (if (or (string-contains query "atlas")
            (string-contains query "deploy")
            (string-contains query "port"))
        '("demo/context-selection/context/legacy-runbook.md")
        '())))

(define (agent-transform-user text)
  text)

(define (agent-demo-response text)
  (string-append "[context demo] " text))

;; A tiny, explicit quality gate for patched candidates, not an authority policy.
(define agent-context-cases
  '(("Which port does Atlas use in production?" ("demo/context-selection/context/current-runbook.md"))
    ("How do I deploy Atlas?" ("demo/context-selection/context/current-runbook.md"))
    ("deployment checklist" ("demo/context-selection/context/current-runbook.md"))
    ("PORT configuration" ("demo/context-selection/context/current-runbook.md"))
    ("DEPLOY Atlas" ("demo/context-selection/context/current-runbook.md"))
    ("Write a cookie recipe" ())
    ("hello" ())
    ("" ())))
