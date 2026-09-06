(define-module (shift openai)
  #:use-module (live-agent json)
  #:use-module (live-agent provider)
  #:use-module (live-agent tools)
  #:use-module (shift http)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:export (make-openai-request parse-completion-response provider-complete-openai openai-effort? openai-fast?))

(define (openai-effort? model)
  (if (member model '("gpt-5" "gpt-5-mini" "gpt-5-nano" "gpt-5.1" "gpt-5.2"
                     "gpt-5.4" "gpt-5.4-mini" "gpt-5.4-nano" "gpt-5.5"
                     "gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna" "o3" "o4-mini")) #t #f))
(define (openai-fast? model)
  (and (openai-effort? model) (not (member model '("gpt-5-nano" "gpt-5.4-nano")))))

(define (parse-tool-call value)
  (let* ((function (json-object-ref value "function"))
         (raw-arguments (json-object-ref function "arguments" "{}"))
         (arguments (json-read raw-arguments)))
    (unless (json-object? arguments)
      (error "tool arguments must decode to a JSON object" raw-arguments))
    (make-tool-call
     (json-object-ref value "id")
     (json-object-ref function "name")
     arguments
     raw-arguments)))

(define (tool-calls->json calls)
  (apply
   json-array
   (map
    (lambda (call)
      (json-object
       (cons "id" (tool-call-id call))
       (cons "type" "function")
       (cons "function"
             (json-object
              (cons "name" (tool-call-name call))
              (cons "arguments" (tool-call-raw-arguments call))))))
    calls)))

(define (parse-completion-response text)
  (let* ((root (json-read text))
         (provider-error (json-object-ref root "error" #f)))
    (when provider-error
      (error "provider returned an error"
             (if (json-object? provider-error)
                 (json-object-ref provider-error "message" provider-error)
                 provider-error)))
    (let* ((choices (json-object-ref root "choices"))
           (choice-items (json-array-items choices)))
      (when (null? choice-items) (error "provider returned no choices"))
      (let* ((message (json-object-ref (car choice-items) "message"))
             (content-value (json-object-ref message "content" json-null))
             (content (if (eq? content-value json-null) #f content-value))
             (calls-value
              (json-object-ref message "tool_calls" (json-array)))
             (calls (map parse-tool-call (json-array-items calls-value)))
             (assistant
              (apply
               json-object
               (append
                (list
                 (cons "role" "assistant")
                 (cons "content" (if content content json-null)))
                (if (null? calls)
                    '()
                    (list (cons "tool_calls" (tool-calls->json calls))))))))
        (make-completion content #f calls assistant root)))))

(define* (make-openai-request model messages tool-names prompt-cache-key
                              #:optional (stream? #f) (effort 'default) (fast? #f) (reserve 8192))
  (let* ((tool-values (map tool-schema tool-names))
         (base-fields
          (list
           (cons "model" model)
           (cons "messages" (apply json-array messages))
           (cons "prompt_cache_key" prompt-cache-key)
           (cons "stream" stream?)
           (cons "max_completion_tokens" reserve)))
         (fields
          (append
           base-fields
           (if (eq? effort 'default) '() (list (cons "reasoning_effort" (symbol->string effort))))
           (if (openai-fast? model) (list (cons "service_tier" (if fast? "fast" "default"))) '())
           (if stream?
               (list
                (cons "stream_options"
                      (json-object (cons "include_usage" #t))))
               '())
           (if (null? tool-values)
               '()
               (list
                (cons "tools" (apply json-array tool-values))
                (cons "parallel_tool_calls" #f)))))
         (payload (apply json-object fields)))
    payload))

(define* (provider-complete-openai model base-url api-key messages tool-names
                                  prompt-cache-key stream? on-content #:optional (effort 'default) (fast? #f) (reserve 8192))
  (let* ((payload
          (json-write
           (make-openai-request
            model messages tool-names prompt-cache-key stream? effort fast? reserve)))
         (endpoint
          (string-append (without-trailing-slash base-url) "/chat/completions")))
    (if (not stream?)
        (parse-completion-response
         (curl-post-json endpoint api-key payload))
        (let ((content-port (open-output-string))
              (call-states '())
              (finished? #f)
              (done? #f)
              (usage (json-object))
              (service-tier #f))
          (define (call-state index)
            (let ((found (assoc index call-states)))
              (if found
                  (cdr found)
                  (let ((state (vector "" "" "")))
                    (set! call-states (cons (cons index state) call-states))
                    state))))
          (define (append-field! state offset value)
            (when (and (string? value) (not (string-null? value)))
              (vector-set!
               state offset (string-append (vector-ref state offset) value))))
          (curl-post-json-lines
           endpoint api-key payload
           (lambda (line)
             (when (string-prefix? "data:" line)
               (let ((data (string-trim-both (substring line 5))))
                 (when (string=? data "[DONE]") (set! done? #t))
                 (unless (or (string-null? data) (string=? data "[DONE]"))
                   (let* ((root (json-read data))
                          (provider-error (json-object-ref root "error" #f))
                          (usage-value (json-object-ref root "usage" #f)))
                     (when (json-object-ref root "service_tier" #f)
                       (set! service-tier (json-object-ref root "service_tier")))
                     (when provider-error
                       (error
                        "provider returned an error"
                        (if (json-object? provider-error)
                            (json-object-ref
                             provider-error "message" provider-error)
                            provider-error)))
                     (when (json-object? usage-value)
                       (set! usage root))
                     (for-each
                      (lambda (choice)
                        (let ((reason (json-object-ref choice "finish_reason" json-null)))
                          (unless (eq? reason json-null)
                            (unless (member reason '("stop" "tool_calls"))
                              (error "provider stopped before completing the answer" reason))
                            (set! finished? #t)))
                        (let* ((delta
                                (json-object-ref choice "delta" (json-object)))
                               (content (json-object-ref delta "content" #f)))
                          (when (string? content)
                            (display content content-port)
                            (on-content content))
                          (for-each
                           (lambda (call-delta)
                             (let* ((index
                                     (json-object-ref call-delta "index" 0))
                                    (state (call-state index))
                                    (function
                                     (json-object-ref
                                      call-delta "function" (json-object))))
                               (append-field!
                                state 0 (json-object-ref call-delta "id" #f))
                               (append-field!
                                state 1 (json-object-ref function "name" #f))
                               (append-field!
                                state 2
                                (json-object-ref function "arguments" #f))))
                           (json-array-items
                            (json-object-ref
                             delta "tool_calls" (json-array))))))
                      (json-array-items
                       (json-object-ref root "choices" (json-array))))))))))
          (unless (and finished? done?)
            (error "incomplete OpenAI stream: missing finish or DONE event"))
          (let* ((content (get-output-string content-port))
                 (calls
                  (map
                   (lambda (entry)
                     (let ((state (cdr entry)))
                       (parse-tool-call
                        (json-object
                         (cons "id" (vector-ref state 0))
                         (cons "type" "function")
                         (cons
                          "function"
                          (json-object
                           (cons "name" (vector-ref state 1))
                           (cons "arguments" (vector-ref state 2))))))))
                   (sort call-states
                         (lambda (left right) (< (car left) (car right))))))
                 (assistant
                  (apply
                   json-object
                   (append
                    (list
                     (cons "role" "assistant")
                     (cons "content"
                           (if (string-null? content) json-null content)))
                    (if (null? calls)
                        '()
                        (list (cons "tool_calls" (tool-calls->json calls))))))))
            (make-completion
             (if (string-null? content) #f content)
             #f calls assistant
             (if service-tier (apply json-object (acons "service_tier" service-tier
               (filter (lambda (p) (not (string=? (car p) "service_tier"))) (json-object-entries usage)))) usage)))))))
