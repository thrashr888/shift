(use-modules (srfi srfi-64) (srfi srfi-1)
             (live-agent json) (live-agent provider) (live-agent transcript)
             (live-agent policy) (live-agent context) (live-agent trace) (shift claude) (shift openai) (shift ollama))
(test-begin "daily driver")
(for-each
 (lambda (name)
   (test-eq (string-append "manual asks for " name) 'ask (tool-decision 'manual name (json-object))))
 '("read" "rg" "write" "edit" "shell" "live_eval" "extension" "traces"))
(for-each
 (lambda (name)
   (test-eq (string-append "plan denies " name) 'deny (tool-decision 'plan name (json-object))))
 '("write" "edit" "shell" "live_eval" "extension"))
(test-eq "plan permits extension listing" 'allow
 (tool-decision 'plan "extension" (json-object (cons "action" "list"))))
(test-eq "autopilot judges behavior changes" 'judge (tool-decision 'autopilot "live_eval" (json-object)))
(test-eq "autopilot judges edits" 'judge (tool-decision 'autopilot "edit" (json-object)))
(test-eq "plan permits status" 'allow (tool-decision 'plan "status" (json-object)))
(test-eq "plan permits diff" 'allow (tool-decision 'plan "diff" (json-object)))
(test-eq "plan denies patches" 'deny (tool-decision 'plan "apply_patch" (json-object)))
(test-eq "autopilot judges patches" 'judge (tool-decision 'autopilot "apply_patch" (json-object)))
(test-eq "autopilot judges unlisted runs" 'judge (tool-decision 'autopilot "run" (json-object)))
(test-eq "a * prefix allows every run in autopilot" 'allow
 (tool-decision 'autopilot "run" (json-object (cons "argv" (json-array "rm" "-rf" "build"))) '(("*"))))
(test-eq "a * prefix allows every run in manual" 'allow
 (tool-decision 'manual "run" (json-object (cons "argv" (json-array "make"))) '(("*"))))
(test-eq "a * prefix never touches plan mode" 'deny
 (tool-decision 'plan "run" (json-object (cons "argv" (json-array "make"))) '(("*"))))
(test-eq "a * prefix does not allow other tools" 'judge
 (tool-decision 'autopilot "edit" (json-object) '(("*"))))
(test-eq "autopilot allows reads" 'allow (tool-decision 'autopilot "read" (json-object)))
(test-eq "manual asks before an unlisted run" 'ask (tool-decision 'manual "run" (json-object)))
(test-eq "manual lets a sandboxed run go" 'allow (tool-decision 'manual "run" (json-object) '() '() #t))
(test-eq "autopilot lets a sandboxed run go without the judge" 'allow (tool-decision 'autopilot "run" (json-object) '() '() #t))
(test-eq "plan still denies sandboxed runs" 'deny (tool-decision 'plan "run" (json-object) '() '() #t))
(test-eq "a sandboxed flag on another tool changes nothing" 'ask (tool-decision 'manual "write" (json-object) '() '() #t))
(test-eq "unknown modes are denied" 'deny (tool-decision 'accept "run" (json-object)))
;; MCP tools: hints decide plan mode, the scoped allowlist decides manual.
(mcp-tool-hints (lambda (name)
  (cond ((string=? name "fake__ping") '((read-only . #t) (destructive . #f) (open-world . #f)))
        ((string=? name "fake__search") '((read-only . #t) (destructive . #f) (open-world . #t)))
        ((string=? name "fake__echo") '((read-only . #f) (destructive . #t) (open-world . #t)))
        (else #f))))
(test-eq "plan allows a closed-world read-only MCP tool" 'allow (tool-decision 'plan "fake__ping" (json-object)))
(test-eq "plan denies an open-world read" 'deny (tool-decision 'plan "fake__search" (json-object)))
(test-eq "plan denies mutating MCP tools" 'deny (tool-decision 'plan "fake__echo" (json-object)))
(test-eq "plan denies an MCP tool it has no hints for" 'deny (tool-decision 'plan "other__thing" (json-object)))
(test-eq "manual asks for MCP tools" 'ask (tool-decision 'manual "fake__ping" (json-object)))
(test-eq "manual allows allowlisted MCP tools" 'allow (tool-decision 'manual "fake__echo" (json-object) '() '("fake__echo")))
(test-eq "autopilot judges MCP tools" 'judge (tool-decision 'autopilot "fake__echo" (json-object)))
(test-eq "autopilot allows allowlisted MCP tools" 'allow (tool-decision 'autopilot "fake__echo" (json-object) '() '("fake__echo")))
(test-eq "tool_search is a read" 'allow (tool-decision 'plan "tool_search" (json-object)))
(define cargo-test (json-object (cons "argv" (json-array "cargo" "test" "--" "session"))))
(define allow '(("cargo" "test") ("make" "check")))
(test-eq "manual allows an allowlisted run prefix" 'allow (tool-decision 'manual "run" cargo-test allow))
(test-eq "autopilot allows allowlisted runs" 'allow (tool-decision 'autopilot "run" cargo-test allow))
(test-eq "plan still denies allowlisted runs" 'deny (tool-decision 'plan "run" cargo-test allow))
(test-eq "a different argv is not covered by the prefix" 'ask
 (tool-decision 'manual "run" (json-object (cons "argv" (json-array "cargo" "publish"))) allow))
(test-eq "a prefix longer than argv does not match" 'ask
 (tool-decision 'manual "run" (json-object (cons "argv" (json-array "cargo"))) allow))
(test-assert "run-allowed? is exact on leading elements"
 (and (run-allowed? '("make" "check" "-j4") allow) (not (run-allowed? '("make" "test") allow))))
(test-eq "manual cannot guess a shell approval" 'ask (tool-decision 'manual "shell" (json-object)))
(define idless
 (list (make-message "user" "read")
       (json-read "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"read\",\"arguments\":{\"path\":\"README.md\"}}}]}")
       (json-read "{\"role\":\"tool\",\"tool_name\":\"read\",\"content\":\"read result\"}")))
(define normalized (normalize-messages idless))
(define call-id (json-object-ref (car (json-array-items (json-object-ref (cadr normalized) "tool_calls"))) "id"))
(test-equal "calls without ids and their results get matching IDs" call-id (json-object-ref (caddr normalized) "tool_call_id"))
(test-equal "normalization is stable" (json-write (apply json-array normalized))
 (json-write (apply json-array (normalize-messages normalized))))
(define openai-messages (messages-for-provider 'openai normalized))
(test-assert "OpenAI arguments are serialized" (string? (json-object-ref
 (json-object-ref (car (json-array-items (json-object-ref (cadr openai-messages) "tool_calls"))) "function") "arguments")))
(define claude (make-claude-request "claude-haiku-4-5-20251001" normalized '("read") #t #f 'default #f 8192))
(define converted (json-array-items (json-object-ref claude "messages")))
(test-equal "Claude result is a user block" "user" (json-object-ref (caddr converted) "role"))
(test-equal "Claude preserves tool IDs" call-id
 (json-object-ref (car (json-array-items (json-object-ref (caddr converted) "content"))) "tool_use_id"))
(define cached-request
  (make-claude-request "claude-haiku-4-5-20251001"
                       (list (make-message "system" "be brief") (make-message "user" "hi")) '("read") #t #f 'default #f 8192))
(define system-blocks (json-array-items (json-object-ref cached-request "system")))
(test-equal "the system prompt is a cache breakpoint" "ephemeral"
  (json-object-ref (json-object-ref (car system-blocks) "cache_control") "type"))
(test-equal "the final message block is a cache breakpoint" "ephemeral"
  (let* ((messages (json-array-items (json-object-ref cached-request "messages")))
         (blocks (json-array-items (json-object-ref (last messages) "content"))))
    (json-object-ref (json-object-ref (last blocks) "cache_control") "type")))
(test-assert "earlier blocks carry no breakpoint"
  (let* ((messages (json-array-items (json-object-ref claude "messages")))
         (first-blocks (json-array-items (json-object-ref (car messages) "content"))))
    (not (json-object-ref (car first-blocks) "cache_control" #f))))
(test-equal "an empty system prompt sends no blocks" '()
  (json-array-items (json-object-ref (make-claude-request "claude-haiku-4-5-20251001" (list (make-message "user" "hi")) '() #t #f 'default #f 8192) "system")))
(define claude-usage
  (usage-attributes
   (make-completion "ok" "" '() (make-message "assistant" "ok")
                    (json-object (cons "usage" (json-object (cons "input_tokens" 100) (cons "output_tokens" 5)
                                                            (cons "cache_read_input_tokens" 900)
                                                            (cons "cache_creation_input_tokens" 40)))))))
(test-equal "Claude cache reads count as cached prompt tokens" 900 (assq-ref claude-usage 'llm.token_count.prompt_cached))
(test-equal "Claude prompt totals include cached and written tokens" 1040 (assq-ref claude-usage 'llm.token_count.prompt))
(test-equal "Claude cache hits are marked" "hit" (assq-ref claude-usage 'llm.prompt_cache.status))
(test-equal "Claude cache writes are recorded" 40 (assq-ref claude-usage 'llm.token_count.prompt_cache_write))
(test-equal "valid tool arguments parse to an object" "x.py"
  (json-object-ref (tool-arguments-from-json "{\"path\":\"x.py\"}") "path"))
(define broken (tool-arguments-from-json "{\"path\":\"x.py\", \"old_text\":\"unterminated}"))
(test-assert "malformed tool arguments become an invalid_json marker, not an error"
  (and (string? (json-object-ref broken "invalid_json" #f))
       (string? (json-object-ref broken "json_error" #f))))
(test-assert "non-object arguments are marked too"
  (json-object-ref (tool-arguments-from-json "[1,2]") "invalid_json" #f))
(test-assert "a truncated Claude tool input does not fail the whole response"
  (let ((completion (parse-claude-response
                     (json-read "{\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"edit\",\"input\":{\"invalid_json\":\"{\\\"path\",\"json_error\":\"expected comma\"}}]}")
                     "claude-haiku-4-5-20251001")))
    (json-object-ref (tool-call-arguments (car (completion-tool-calls completion))) "invalid_json" #f)))
(test-error "unsupported fast mode fails before request" #t
 (make-claude-request "claude-haiku-4-5-20251001" normalized '() #f #f 'default #t 8192))
(test-error "unsupported effort fails before request" #t
 (make-claude-request "claude-haiku-4-5-20251001" normalized '() #f #f 'high #f 8192))
(define signed
 (parse-claude-response (json-read "{\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"inspect first\",\"signature\":\"opaque\"},{\"type\":\"tool_use\",\"id\":\"tool1\",\"name\":\"read\",\"input\":{\"path\":\"README.md\"}}]}") "claude-haiku-4-5-20251001"))
(define signed-history (list (make-message "user" "read") (completion-assistant-message signed)
  (make-tool-result-message 'claude "tool1" "read" "contents")))
(test-assert "Claude thinking signatures survive follow-up"
 (string-contains (json-write (make-claude-request "claude-haiku-4-5-20251001" signed-history '("read") #t #t 'default #f 8192)) "opaque"))
(test-assert "other providers never receive Claude signature blocks"
 (not (string-contains (json-write (apply json-array (messages-for-provider 'openai signed-history))) "opaque")))
(test-error "truncated Claude response rejected" #t
 (parse-claude-response (json-read "{\"stop_reason\":\"max_tokens\",\"content\":[]}") "claude-haiku-4-5-20251001"))
(test-error "orphan tool result rejected" #t (normalize-messages (list (caddr idless))))
(test-assert "token estimate includes tool schemas"
 (> (estimate-input-tokens normalized '("read")) (estimate-input-tokens normalized '())))
(test-assert "output space reserved" (context-over-budget? 7000 10000 2000))
(test-assert "unknown limit stays unknown" (not (context-over-budget? 100000 #f 8192)))
(test-equal "prompt usage scales the next raw estimate" 80300
  (calibrate-input-estimate 121000 110000 73000))
(test-assert "the calibrated code prompt fits the 131k window"
  (and (context-over-budget? 121000 131072 8192)
       (not (context-over-budget?
             (calibrate-input-estimate 121000 110000 73000) 131072 8192))))
(test-equal "later rounds use the latest actual count and its raw estimate" 87273
  (calibrate-input-estimate 132000 121000 80000))
(test-equal "underestimates are calibrated upward too" 144000
  (calibrate-input-estimate 120000 100000 120000))
(test-assert "calibration preserves the output reserve and safety margin"
  (context-over-budget? (calibrate-input-estimate 150000 100000 73000) 131072 8192))
(for-each
 (lambda (reference)
   (test-equal "missing or zero usage keeps the raw estimate" 121000
     (calibrate-input-estimate 121000 (car reference) (cadr reference))))
 '((#f #f) (110000 #f) (110000 0) (0 73000) (110000 -1)))
(define fast-openai (make-openai-request "gpt-5.4-mini" (list (make-message "user" "hi")) '() "test" #t 'high #t 2048))
(test-equal "OpenAI fast service is separate from effort" "fast" (json-object-ref fast-openai "service_tier"))
(test-equal "OpenAI effort parameter" "high" (json-object-ref fast-openai "reasoning_effort"))
(test-equal "output reservation reaches OpenAI" 2048 (json-object-ref fast-openai "max_completion_tokens"))
(define plain-ollama (make-ollama-request "qwen" (list (make-message "user" "hi")) '() #t #f "10m"))
(test-assert "Ollama gets no options without a known context limit"
  (not (json-object-ref plain-ollama "options" #f)))
(test-equal "Ollama num_ctx follows the runtime's context limit" 131072
  (parameterize ((provider-context-limit 131072))
    (json-object-ref (json-object-ref (make-ollama-request "qwen" (list (make-message "user" "hi")) '() #t #f "10m") "options") "num_ctx")))
(test-end "daily driver")
