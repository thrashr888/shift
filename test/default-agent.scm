(use-modules (srfi srfi-64)
             (live-agent generation))

(test-begin "default agent")

(define source-path "agent/default.scm")
(define generation
  (build-generation 1 source-path (read-source-file source-path) '()))

(test-equal "defaults to installed tool-capable Ollama model"
  "qwen3.8:27b-mlx"
  (generation-ref generation 'agent-model))

(test-eq "defaults to native Ollama transport"
  'ollama
  (generation-ref generation 'agent-provider))

(test-equal "defaults to local native Ollama endpoint"
  "http://127.0.0.1:11434"
  (generation-ref generation 'agent-base-url))

(test-eq "Ollama does not require a credential environment variable"
  #f
  (generation-ref generation 'agent-api-key-environment))

(test-assert "streams output by default"
  (generation-ref generation 'agent-stream?))

(test-eq "hides model thinking by default"
  #f
  (generation-ref generation 'agent-thinking))
(test-equal "keeps the local model warm for an interactive pause"
  "10m"
  (generation-ref generation 'agent-keep-alive))

(test-assert "agent can change its constrained live image"
  (memq 'live_eval (generation-ref generation 'agent-tools)))

(test-equal "enables the complete constrained coding tool set"
  '(read rg write edit apply_patch status diff run shell traces live_eval extension)
  (generation-ref generation 'agent-tools))

(test-equal "compacts after a bounded number of messages"
  80 (generation-ref generation 'agent-compaction-threshold))

(test-equal "retains recent messages after compaction"
  24 (generation-ref generation 'agent-compaction-keep-recent))

(test-assert "guides import questions toward Guile module forms"
  (and
   (string-contains (generation-ref generation 'agent-system-prompt)
                    "#:use-module")
   (string-contains (generation-ref generation 'agent-system-prompt)
                    "(use-modules")))

(test-assert "ordinary content requests should not mutate project files"
  (string-contains (generation-ref generation 'agent-system-prompt)
                   "answer ordinary content requests in the conversation"))

(test-equal "default context selection is empty"
  '()
  (generation-call generation 'agent-select-context "hello"))

(define gateway-generation
  (build-generation
   2 source-path (read-source-file source-path)
   (list (read-source-file "extensions/openai-gateway.scm"))))

(test-equal "checked-in gateway extension selects streaming OpenAI"
  '(openai "gpt-5.4-mini" "OPENAI_API_KEY" #t)
  (list
   (generation-ref gateway-generation 'agent-provider)
   (generation-ref gateway-generation 'agent-model)
   (generation-ref gateway-generation 'agent-api-key-environment)
   (generation-ref gateway-generation 'agent-stream?)))

(test-end "default agent")
