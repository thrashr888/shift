(use-modules (srfi srfi-64) (srfi srfi-1)
             (live-agent json) (live-agent provider) (live-agent transcript)
             (live-agent policy) (live-agent context) (shift claude) (shift openai))
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
(test-eq "accept asks before behavior changes" 'ask (tool-decision 'accept "live_eval" (json-object)))
(test-eq "accept permits scoped edits" 'allow (tool-decision 'accept "edit" (json-object)))
(test-eq "plan permits status" 'allow (tool-decision 'plan "status" (json-object)))
(test-eq "plan permits diff" 'allow (tool-decision 'plan "diff" (json-object)))
(test-eq "plan denies patches" 'deny (tool-decision 'plan "apply_patch" (json-object)))
(test-eq "accept permits patches" 'allow (tool-decision 'accept "apply_patch" (json-object)))
(test-eq "accept asks before run" 'ask (tool-decision 'accept "run" (json-object)))
(test-eq "auto asks before run" 'ask (tool-decision 'auto "run" (json-object)))
(define cargo-test (json-object (cons "argv" (json-array "cargo" "test" "--" "session"))))
(define allow '(("cargo" "test") ("make" "check")))
(test-eq "accept allows an allowlisted run prefix" 'allow (tool-decision 'accept "run" cargo-test allow))
(test-eq "auto allows an allowlisted run prefix" 'allow (tool-decision 'auto "run" cargo-test allow))
(test-eq "manual still asks for allowlisted runs" 'ask (tool-decision 'manual "run" cargo-test allow))
(test-eq "plan still denies allowlisted runs" 'deny (tool-decision 'plan "run" cargo-test allow))
(test-eq "a different argv is not covered by the prefix" 'ask
 (tool-decision 'accept "run" (json-object (cons "argv" (json-array "cargo" "publish"))) allow))
(test-eq "a prefix longer than argv does not match" 'ask
 (tool-decision 'accept "run" (json-object (cons "argv" (json-array "cargo"))) allow))
(test-assert "run-allowed? is exact on leading elements"
 (and (run-allowed? '("make" "check" "-j4") allow) (not (run-allowed? '("make" "test") allow))))
(test-eq "auto cannot guess a shell approval" 'ask (tool-decision 'auto "shell" (json-object)))
(define legacy
 (list (make-message "user" "read")
       (json-read "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"read\",\"arguments\":{\"path\":\"README.md\"}}}]}")
       (json-read "{\"role\":\"tool\",\"tool_name\":\"read\",\"content\":\"read result\"}")))
(define normalized (normalize-messages legacy))
(define call-id (json-object-ref (car (json-array-items (json-object-ref (cadr normalized) "tool_calls"))) "id"))
(test-equal "legacy calls and results get matching IDs" call-id (json-object-ref (caddr normalized) "tool_call_id"))
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
(test-error "orphan tool result rejected" #t (normalize-messages (list (caddr legacy))))
(test-assert "token estimate includes tool schemas"
 (> (estimate-input-tokens normalized '("read")) (estimate-input-tokens normalized '())))
(test-assert "output space reserved" (context-over-budget? 7000 10000 2000))
(test-assert "unknown limit stays unknown" (not (context-over-budget? 100000 #f 8192)))
(define fast-openai (make-openai-request "gpt-5.4-mini" (list (make-message "user" "hi")) '() "test" #t 'high #t 2048))
(test-equal "OpenAI fast service is separate from effort" "fast" (json-object-ref fast-openai "service_tier"))
(test-equal "OpenAI effort parameter" "high" (json-object-ref fast-openai "reasoning_effort"))
(test-equal "output reservation reaches OpenAI" 2048 (json-object-ref fast-openai "max_completion_tokens"))
(test-end "daily driver")
