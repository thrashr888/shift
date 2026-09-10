(define-module (shift ollama)
  #:use-module (live-agent json)
  #:use-module (live-agent provider)
  #:use-module (live-agent tools)
  #:use-module (shift http)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-13)
  #:export (make-ollama-request parse-ollama-response provider-complete-ollama))

(define (parse-ollama-tool-call value)
  (let* ((function (json-object-ref value "function"))
         (arguments-value (json-object-ref function "arguments" (json-object)))
         (arguments
          (cond ((string? arguments-value) (tool-arguments-from-json arguments-value))
                ((json-object? arguments-value) arguments-value)
                (else (tool-arguments-from-json (json-write arguments-value)))))
         (raw-arguments
          (if (string? arguments-value)
              arguments-value
              (json-write arguments-value))))
    (make-tool-call
     (json-object-ref value "id" (string-append "call_" (number->string (random 1000000000))))
     (json-object-ref function "name")
     arguments
     raw-arguments)))

(define (tool-calls->ollama-json calls)
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
              (cons "arguments" (tool-call-arguments call))))))
    calls)))

(define (make-ollama-request model messages tool-names stream? thinking keep-alive)
  (let* ((tool-values (map tool-schema tool-names))
         (fields
          (append
           (list
            (cons "model" model)
            (cons "messages" (apply json-array messages))
            (cons "stream" stream?)
            (cons "keep_alive" keep-alive)
            (cons "think"
                  (if (symbol? thinking)
                      (symbol->string thinking)
                      thinking)))
           (if (null? tool-values)
               '()
               (list (cons "tools" (apply json-array tool-values))))
           ;; Ollama truncates the prompt to num_ctx without saying so; the
           ;; window the runtime budgets for is the window the server gets.
           (if (number? (provider-context-limit))
               (list (cons "options" (json-object (cons "num_ctx" (provider-context-limit)))))
               '()))))
    (apply json-object fields)))

(define (parse-ollama-response text)
  (let* ((root (json-read text))
         (provider-error (json-object-ref root "error" #f)))
    (when provider-error
      (error "provider returned an error" provider-error))
    (let* ((message (json-object-ref root "message"))
           (content (json-object-ref message "content" ""))
           (thought (json-object-ref message "thinking" ""))
           (calls
            (map parse-ollama-tool-call
                 (json-array-items
                  (json-object-ref message "tool_calls" (json-array))))))
      (make-completion content thought calls message root))))

(define (provider-complete-ollama model base-url api-key messages tool-names
                                  stream? thinking keep-alive
                                  on-content on-thinking)
  (let* ((payload
          (json-write
           (make-ollama-request
            model messages tool-names stream? thinking keep-alive)))
         (endpoint (string-append (without-trailing-slash base-url) "/api/chat")))
    (if stream?
        (let ((content-port (open-output-string))
              (thinking-port (open-output-string))
              (calls '())
              (usage (json-object)))
          (curl-post-json-lines
           endpoint api-key payload
           (lambda (line)
             (let* ((root (json-read line))
                    (provider-error (json-object-ref root "error" #f)))
               (when provider-error
                 (error "provider returned an error" provider-error))
               (let* ((message (json-object-ref root "message" (json-object)))
                      (content (json-object-ref message "content" ""))
                      (thought (json-object-ref message "thinking" ""))
                      (chunk-calls
                       (json-array-items
                        (json-object-ref message "tool_calls" (json-array)))))
                 (unless (string-null? thought)
                   (display thought thinking-port)
                   (on-thinking thought))
                 (unless (string-null? content)
                   (display content content-port)
                   (on-content content))
                 (unless (null? chunk-calls)
                   (set! calls
                         (append calls (map parse-ollama-tool-call chunk-calls))))
                 (when (json-object-ref root "done" #f)
                   (when (equal? (json-object-ref root "done_reason" #f) "length")
                     (error "provider stopped before completing the answer" "length"))
                   (set! usage root))))))
          (unless (eq? (json-object-ref usage "done" #f) #t)
            (error "incomplete Ollama stream: missing done event"))
          (let* ((content (get-output-string content-port))
                 (thought (get-output-string thinking-port))
                 (assistant
                  (apply
                   json-object
                   (append
                    (list (cons "role" "assistant")
                          (cons "content" content))
                    (if (string-null? thought)
                        '()
                        (list (cons "thinking" thought)))
                    (if (null? calls)
                        '()
                        (list
                         (cons "tool_calls"
                               (tool-calls->ollama-json calls))))))))
            (make-completion content thought calls assistant usage)))
        (parse-ollama-response
         (curl-post-json endpoint api-key payload)))))
