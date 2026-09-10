(define-module (live-agent provider)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent transcript)
  #:use-module (live-agent builtins)
  #:use-module (live-agent json)
  #:export (provider-retry-limit
            current-retry-observer
            retryable-status?
            tool-call?
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
            tool-arguments-from-json
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

;; Retries of a provider request that failed before any of the response was
;; consumed. The limit comes from the provider-retries setting through this
;; parameter; SHIFT_PROVIDER_RETRIES is the process-wide default (tests use 0).
(define provider-retry-limit
  (make-parameter
   (let ((value (getenv "SHIFT_PROVIDER_RETRIES")))
     (or (and value (string->number value)) 3))))

;; Called as (observer attempt reason delay-ms) before each pause; reason is
;; an HTTP status or a curl exit-code symbol such as curl-7.
(define current-retry-observer (make-parameter (lambda (attempt reason delay) #f)))

(define (retryable-status? status)
  (and (memv status '(408 409 425 429 500 502 503 504 529)) #t))

(define (make-message role content)
  (json-object (cons "role" role) (cons "content" content)))

;; A tool call whose arguments are not a valid JSON object fails that one
;; call with a message the model can act on; it never fails the turn. A
;; 30-round turn was lost to one malformed 25 KB edit before this existed.
(define (tool-arguments-from-json text)
  (define (invalid detail)
    (json-object
     (cons "invalid_json" (if (> (string-length text) 400)
                              (string-append (substring text 0 400) "…")
                              text))
     (cons "json_error" detail)))
  (catch #t
    (lambda ()
      (let ((value (json-read text)))
        (if (json-object? value)
            value
            (invalid "arguments must be a JSON object"))))
    (lambda (key . arguments)
      (invalid (catch #t
                 (lambda ()
                   (if (and (>= (length arguments) 3) (string? (cadr arguments)) (list? (caddr arguments)))
                       (apply format #f (cadr arguments) (caddr arguments))
                       (format #f "~a" key)))
                 (lambda _ (format #f "~a" key)))))))

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
