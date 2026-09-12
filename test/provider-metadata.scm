(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (live-agent json)
             (live-agent provider-metadata))

(test-begin "provider-metadata")

;; /api/ps fixtures include disk/model size deliberately: only size_vram is
;; allocated memory, and context_length is the loaded window, not a maximum.
(define loaded
  (json-read "{\"models\":[{\"name\":\"fixture:latest\",\"model\":\"fixture:latest\",\"size\":999999999,\"size_vram\":1073741824,\"context_length\":32768}]}"))
(define (field value key) (json-object-ref value key))
(define metadata (loaded-ollama-metadata "fixture" loaded))
(test-equal "matches omitted latest tag" 32768 (field metadata "context_limit"))
(test-equal "loaded window provenance" "ollama:/api/ps" (field metadata "context_source"))
(test-equal "allocated memory is bytes, not disk size or GiB" 1073741824 (field metadata "memory_bytes"))
(test-equal "does not describe host RAM" "GPU/model allocated" (field metadata "memory_label"))
(test-equal "all measurements available" json-null (field metadata "reason"))

(define missing
  (loaded-ollama-metadata "fixture"
    (json-read "{\"models\":[{\"name\":\"fixture:latest\",\"size\":999999999,\"model_info\":{\"fixture.context_length\":262144}}]}")))
(test-equal "never substitutes architecture max" json-null (field missing "context_limit"))
(test-equal "never substitutes disk size" json-null (field missing "memory_bytes"))
(test-equal "missing loaded context explanation" "loaded-context-unavailable" (field missing "context_reason"))
(test-equal "missing memory explanation" "loaded-memory-unavailable" (field missing "memory_reason"))
(test-equal "does not fuzzy-match a different tag" "model-not-loaded"
  (field (loaded-ollama-metadata "fixture:other" loaded) "reason"))
(test-equal "unloaded model explanation" "model-not-loaded"
  (field (loaded-ollama-metadata "fixture" (json-read "{\"models\":[]}")) "reason"))
(test-equal "unsupported ps schema explanation" "metadata-invalid"
  (field (loaded-ollama-metadata "fixture" (json-read "{}")) "reason"))
(test-equal "zero GPU allocation is reported, not host RAM"
  0 (field (loaded-ollama-metadata "fixture"
             (json-read "{\"models\":[{\"model\":\"fixture\",\"size_vram\":0}]}")) "memory_bytes"))
(for-each
 (lambda (value)
   (let ((bad (loaded-ollama-metadata "fixture"
                (json-object (cons "models" (json-array
                  (json-object (cons "model" "fixture") (cons "context_length" value)
                               (cons "size_vram" value))))))))
     (test-equal "rejects invalid context count" json-null (field bad "context_limit"))
     (test-equal "rejects invalid memory count" json-null (field bad "memory_bytes"))))
 (list -1 "32768" 1.5 json-null))

(let ((calls 0) (now 0) (cache (make-provider-metadata-cache)))
  (parameterize ((current-metadata-fetch (lambda (base) (set! calls (+ calls 1)) loaded))
                 (current-metadata-clock (lambda () now)))
    (test-equal "demo has no discovery" "demo-no-metadata"
      (field (cache 'ollama "demo" "http://127.0.0.1:11434" #f) "reason"))
    (test-equal "demo never probes default ollama" 0 calls)
    (test-equal "remote provider metadata is disabled" "remote-metadata-disabled"
      (field (cache 'ollama "fixture" "https://example.org" #f) "reason"))
    (test-equal "unsupported adapter explanation" "provider-metadata-unsupported"
      (field (cache 'openai "fixture" "http://127.0.0.1:11434" #f) "reason"))
    (test-equal "unsupported and remote never fetch" 0 calls)
    (cache 'ollama "fixture" "http://127.0.0.1:11434" #f)
    (test-equal "fetch selected local model once" 1 calls)
    (let ((overridden (cache 'ollama "fixture" "http://127.0.0.1:11434" 16384)))
      (test-equal "override takes precedence immediately" 16384 (field overridden "context_limit"))
      (test-equal "override provenance" "override" (field overridden "context_source")))
    (test-equal "override changes reuse resident cache" 1 calls)
    (test-equal "clearing override reveals loaded window" 32768
      (field (cache 'ollama "fixture" "http://127.0.0.1:11434" #f) "context_limit"))
    (set! now 4)
    (cache 'ollama "fixture" "http://127.0.0.1:11434" #f)
    (test-equal "session and usage share bounded cache" 1 calls)
    (set! now 5)
    (cache 'ollama "fixture" "http://127.0.0.1:11434" #f)
    (test-equal "expiry refreshes on next event" 2 calls)
    (cache 'ollama "other" "http://127.0.0.1:11434" #f)
    (test-equal "model change invalidates" 3 calls)
    (cache 'ollama "fixture" "http://127.0.0.1:11435" #f)
    (test-equal "endpoint change invalidates" 4 calls)
    (cache 'openai "fixture" "http://127.0.0.1:11435" #f)
    (cache 'ollama "fixture" "http://127.0.0.1:11435" #f)
    (test-equal "provider switch back cannot reuse old facts" 5 calls)))

(let ((calls 0) (now 0) (cache (make-provider-metadata-cache)))
  (parameterize ((current-metadata-fetch
                   (lambda (base) (set! calls (+ calls 1)) "metadata-unreachable"))
                 (current-metadata-clock (lambda () now)))
    (test-equal "offline explanation" "metadata-unreachable"
      (field (cache 'ollama "fixture" "http://localhost:11434" #f) "reason"))
    (let ((overridden (cache 'ollama "fixture" "http://localhost:11434" 8192)))
      (test-equal "override works while provider offline" 8192 (field overridden "context_limit"))
      (test-equal "override needs no context metadata" json-null (field overridden "context_reason"))
      (test-equal "offline memory still unknown" "metadata-unreachable" (field overridden "memory_reason")))
    (test-equal "failure cached without retry storm" 1 calls)
    (set! now 5)
    (parameterize ((current-metadata-fetch (lambda (base) loaded)))
      (test-equal "recovers after cache expires" 32768
        (field (cache 'ollama "fixture" "http://localhost:11434" #f) "context_limit")))))

(define reported (provider-usage-event (json-read "{\"prompt_eval_count\":8600}") 9000 3 6 metadata))
(test-equal "reported count wins over estimate" 8600 (field reported "prompt"))
(test-equal "reported numerator provenance" "reported" (field reported "prompt_source"))
(test-equal "usage denominator matches metadata" 32768 (field reported "limit"))
(test-equal "round semantics retained" 3 (field reported "round"))
(test-equal "configured maximum retained" 6 (field reported "max_rounds"))
(define estimated (provider-usage-event (json-object) 9000 1 6 missing))
(test-equal "missing report uses local estimate" 9000 (field estimated "prompt"))
(test-equal "estimate is labeled" "estimated" (field estimated "prompt_source"))
(test-equal "missing denominator remains null" json-null (field estimated "limit"))
(test-equal "reported zero is not missing" "reported"
  (field (provider-usage-event (json-read "{\"prompt_eval_count\":0}") 90 1 6 metadata) "prompt_source"))
(test-equal "no available numerator is not zero" json-null
  (field (provider-usage-event (json-object) #f 1 6 metadata) "prompt"))
(test-equal "OpenAI reports prompt tokens without tracing enabled" 1200
  (field (provider-usage-event (json-read "{\"usage\":{\"prompt_tokens\":1200}}")
                              2000 1 6 metadata) "prompt"))
(test-equal "Claude cached prompt tokens still occupy context" 1200
  (field (provider-usage-event
           (json-read "{\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":1000,\"cache_creation_input_tokens\":100}}")
           2000 1 6 metadata) "prompt"))
(test-equal "metadata must not swallow turn cancellation" 'cancelled
  (parameterize ((current-metadata-fetch (lambda (base) (throw 'turn-cancelled))))
    (catch 'turn-cancelled
      (lambda () ((make-provider-metadata-cache) 'ollama "fixture" "http://localhost:11434" #f))
      (lambda _ 'cancelled))))

(define snapshot-keys
  '("provider" "model" "prompt_tokens" "prompt" "prompt_source" "prompt_reason"
    "limit" "context_limit" "context_source" "context_reason"
    "round" "round_source" "max_rounds" "memory_bytes" "memory_label" "memory_reason" "reason"))
(for-each
  (lambda (provider)
    (let* ((configured (provider-configured-metadata provider "fixture" 8192))
           (initial (provider-session-usage-event #f 245 6 configured)))
      (test-assert "initial six-field snapshot is complete, including unknown fields"
        (every (lambda (key) (assoc key (json-object-entries initial))) snapshot-keys))
      (test-equal "configured context denominator known for every provider" 8192 (field initial "limit"))
      (test-equal "max rounds known before any provider request" 6 (field initial "max_rounds"))
      (test-equal "round zero is explicit before turn" 0 (field initial "round"))
      (test-equal "initial round has not started" "not-started" (field initial "round_source"))
      (test-equal "initial prompt uses local estimate" 245 (field initial "prompt_tokens"))
      (test-equal "initial estimate never claims provider measurement" "estimated" (field initial "prompt_source"))
      (test-equal "RAM is not fabricated by initial snapshot" json-null (field initial "memory_bytes"))))
  '(ollama openai claude))
(define no-estimate
  (provider-session-usage-event #f #f 0 (provider-configured-metadata 'ollama "demo" #f)))
(test-equal "configured zero max rounds is preserved" 0 (field no-estimate "max_rounds"))
(test-equal "unmeasured prompt remains explicit null" json-null (field no-estimate "prompt_tokens"))
(test-equal "unmeasured prompt has reason" "provider-not-measured" (field no-estimate "prompt_reason"))
(test-equal "unknown initial limit is explicit null" json-null (field no-estimate "limit"))
(define refreshed
  (provider-session-usage-event reported 99999 8
    (provider-configured-metadata 'ollama "fixture" 65536)))
(test-equal "mode/session/theme refresh retains last measured prompt" 8600 (field refreshed "prompt_tokens"))
(test-equal "refresh retains reported provenance" "reported" (field refreshed "prompt_source"))
(test-equal "refresh retains completed round" 3 (field refreshed "round"))
(test-equal "effective max rounds changes refresh immediately" 8 (field refreshed "max_rounds"))
(test-equal "effective limit changes refresh immediately" 65536 (field refreshed "limit"))
(define switched
  (provider-session-usage-event reported 321 6
    (provider-configured-metadata 'ollama "other" #f)))
(test-equal "model switch discards stale measured prompt" 321 (field switched "prompt_tokens"))
(test-equal "model switch resets round" 0 (field switched "round"))
(test-equal "model switch labels fresh estimate" "estimated" (field switched "prompt_source"))

(test-end "provider-metadata")
