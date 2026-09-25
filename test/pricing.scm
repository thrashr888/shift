(use-modules (srfi srfi-64) (live-agent pricing))

(test-begin "pricing")

(define sonnet-turn
  '((uncached . 545) (cached . 1900) (cache_write . 200) (completion . 611)))

;; Rates are configured, never built in, so nothing in the harness can go
;; stale. A model with no row must report no cost rather than $0, which would
;; sum into a session total as though the turn were free.
(test-assert "an unconfigured model is unpriced, not free"
  (not (token-cost 'claude "claude-sonnet-5" sonnet-turn)))

(test-equal "local inference is genuinely zero" 0
  (car (token-cost 'ollama "qwen3.8:27b-mlx" '((uncached . 5000) (completion . 900)))))

(test-equal "the local row is the one built-in rate" 'listed
  (cdr (token-cost 'ollama "anything" '((completion . 1)))))

(define claude-rows
  '((claude "claude-sonnet" 3.0 0.3 3.75 15.0)
    (claude "claude-sonnet-5" 2.0 0.2 2.5 10.0)
    (claude "claude-haiku-4-5" 1.0 0.1 1.25 5.0)))

(parameterize ((configured-prices claude-rows))
  ;; 545×$3 + 1900×$0.30 + 200×$3.75 + 611×$15, per million.
  (test-equal "each bucket bills at its own rate" 0.01212
    (exact->inexact (car (token-cost 'claude "claude-sonnet-4-6" sonnet-turn))))

  (test-equal "a configured price says so" 'configured
    (cdr (token-cost 'claude "claude-sonnet-4-6" sonnet-turn)))

  (test-equal "a provider given as a string resolves" 0.01212
    (exact->inexact (car (token-cost "claude" "claude-sonnet-4-6" sonnet-turn))))

  ;; 545×$2 + 1900×$0.20 + 200×$2.50 + 611×$10.
  (test-equal "the longest matching prefix wins" 0.00808
    (exact->inexact (car (token-cost 'claude "claude-sonnet-5" sonnet-turn))))

  (test-equal "rates come back as a row" '(1.0 0.1 1.25 5.0)
    (model-price 'claude "claude-haiku-4-5-20251001"))

  (test-assert "a provider mismatch does not borrow another provider's rates"
    (not (token-cost 'openai "claude-sonnet-4-6" sonnet-turn)))

  ;; Missing buckets count as zero rather than failing: an Ollama turn reports
  ;; no cache figures at all.
  (test-equal "absent buckets contribute nothing" 0.0015
    (exact->inexact (car (token-cost 'claude "claude-haiku-4-5" '((completion . 300))))))

  (test-equal "a configured row still prices the local provider at zero" 0
    (car (token-cost 'ollama "qwen3.8:27b-mlx" sonnet-turn))))

(test-assert "clearing the configuration returns the model to unpriced"
  (not (token-cost 'claude "claude-sonnet-4-6" sonnet-turn)))

(test-end "pricing")
