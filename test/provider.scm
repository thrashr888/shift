(use-modules (srfi srfi-64)
             (live-agent json)
             (live-agent provider)
             (shift ollama)
             (shift openai))

(test-begin "provider")

(define text-completion
  (parse-completion-response
   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}"))

(test-equal "parses assistant text" "hello" (completion-content text-completion))
(test-equal "text response has no calls" 0 (length (completion-tool-calls text-completion)))

(define tool-completion
  (parse-completion-response
   (string-append
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,"
    "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\","
    "\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}")))

(define call (car (completion-tool-calls tool-completion)))
(test-equal "parses tool name" "read" (tool-call-name call))
(test-equal "parses nested arguments"
  "README.md"
  (json-object-ref (tool-call-arguments call) "path"))

(define ollama-completion
  (parse-ollama-response
   (string-append
    "{\"message\":{\"role\":\"assistant\",\"content\":\"\","
    "\"thinking\":\"I should read it.\",\"tool_calls\":["
    "{\"id\":\"call_native\",\"function\":{\"name\":\"read\","
    "\"arguments\":{\"path\":\"LICENSE\"}}}]},\"done\":true,"
    "\"prompt_eval_count\":12,\"eval_count\":7}")))

(test-equal "parses native Ollama thinking"
  "I should read it."
  (completion-thinking ollama-completion))
(test-equal "parses native Ollama object arguments"
  "LICENSE"
  (json-object-ref
   (tool-call-arguments (car (completion-tool-calls ollama-completion)))
   "path"))

(define openai-usage-completion
  (parse-completion-response
   (string-append
    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}],"
    "\"usage\":{\"prompt_tokens\":1200,\"completion_tokens\":9,"
    "\"prompt_tokens_details\":{\"cached_tokens\":1024,\"cache_write_tokens\":0},"
    "\"completion_tokens_details\":{\"reasoning_tokens\":4}}}")))

(test-equal "retains OpenAI usage details for cache tracing"
  1024
  (json-object-ref
   (json-object-ref
    (json-object-ref (completion-usage openai-usage-completion) "usage")
    "prompt_tokens_details")
   "cached_tokens"))

(define thinking-off-request
  (make-ollama-request
   "fixture" (list (make-message "user" "hello")) '() #t #f "10m"))
(test-eq "serializes explicit thinking false"
  #f
  (json-object-ref thinking-off-request "think"))

(define leveled-request
  (make-ollama-request
   "fixture" (list (make-message "user" "hello")) '() #t 'medium "10m"))
(test-equal "serializes model-specific thinking level"
  "medium"
  (json-object-ref leveled-request "think"))

(define coding-tools-request
  (make-ollama-request
   "fixture"
   (list (make-message "user" "work"))
   '("read" "rg" "write" "edit" "shell" "traces" "live_eval" "extension")
   #t #f "10m"))

(test-equal "serializes an explicit model residency window"
  "10m"
  (json-object-ref coding-tools-request "keep_alive"))

(test-equal "serializes every constrained coding and mutation tool"
  8
  (length
   (json-array-items (json-object-ref coding-tools-request "tools"))))

(define openai-request
  (make-openai-request
   "gpt-5.4-mini"
   (list (make-message "user" "hello"))
   '("read")
   "shift-fixture-normal"))

(test-equal "serializes a stable OpenAI prompt cache key"
  "shift-fixture-normal"
  (json-object-ref openai-request "prompt_cache_key"))

(define openai-stream-request
  (make-openai-request
   "gpt-5.4-mini"
   (list (make-message "user" "hello"))
   '("read")
   "shift-fixture-normal"
   #t))

(test-assert "requests OpenAI SSE with a final usage chunk"
  (and
   (json-object-ref openai-stream-request "stream")
   (json-object-ref
    (json-object-ref openai-stream-request "stream_options")
    "include_usage")))

(test-end "provider")
