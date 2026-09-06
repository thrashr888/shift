(define-module (live-agent provider)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent transcript)
  #:use-module (live-agent builtins)
  #:use-module (live-agent json)
  #:export (tool-call?
            tool-call-id
            tool-call-name
            tool-call-arguments
            completion?
            completion-content
            completion-thinking
            completion-tool-calls
            completion-assistant-message
            completion-usage
            make-message
            make-tool-result-message
            make-tool-call
            tool-call-raw-arguments
            make-completion
            provider-complete))

(define-record-type <tool-call>
  (make-tool-call id name arguments raw-arguments)
  tool-call?
  (id tool-call-id)
  (name tool-call-name)
  (arguments tool-call-arguments)
  (raw-arguments tool-call-raw-arguments))

(define-record-type <completion>
  (make-completion content thinking tool-calls assistant-message usage)
  completion?
  (content completion-content)
  (thinking completion-thinking)
  (tool-calls completion-tool-calls)
  (assistant-message completion-assistant-message)
  (usage completion-usage))

(define (make-message role content)
  (json-object (cons "role" role) (cons "content" content)))

(define (make-tool-result-message provider call-id tool-name content)
  (json-object (cons "role" "tool") (cons "tool_name" tool-name)
               (cons "tool_call_id" call-id) (cons "content" content)))

;; Fixed built-ins load only when a request selects that provider.
(define* (provider-complete provider model base-url api-key messages tool-names
                           stream? thinking keep-alive prompt-cache-key
                           on-content on-thinking #:optional (effort 'default) (fast? #f) (output-reserve 8192))
  (let ((messages (normalize-messages messages)))
  (canonical-completion (case provider
    ((ollama)
     ((builtin-ref 'ollama 'provider-complete-ollama)
      model base-url api-key (messages-for-provider 'ollama messages) tool-names stream? thinking keep-alive
      on-content on-thinking))
    ((openai)
     ((builtin-ref 'openai 'provider-complete-openai)
      model base-url api-key (messages-for-provider 'openai messages) tool-names prompt-cache-key stream?
      on-content effort fast? output-reserve))
    ((claude)
     ((builtin-ref 'claude 'provider-complete-claude)
      model base-url api-key messages tool-names stream? thinking effort fast?
      output-reserve on-content on-thinking))
    (else (error "unsupported provider" provider))))))

(define (canonical-completion completion)
  (let* ((assistant (completion-assistant-message completion))
         (calls (completion-tool-calls completion))
         (message (apply json-object
           (acons "tool_calls" (apply json-array
             (map (lambda (call) (json-object (cons "id" (tool-call-id call)) (cons "type" "function")
               (cons "function" (json-object (cons "name" (tool-call-name call))
                                            (cons "arguments" (tool-call-arguments call)))))) calls))
             (filter (lambda (entry) (not (string=? (car entry) "tool_calls"))) (json-object-entries assistant))))))
    (make-completion (completion-content completion) (completion-thinking completion)
                     calls message (completion-usage completion))))
