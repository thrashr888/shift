(define-module (shift claude)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent provider)
  #:use-module (live-agent tools)
  #:use-module (shift http)
  #:export (provider-complete-claude make-claude-request parse-claude-response
            claude-fast? claude-adaptive? claude-effort?))

;; Conservative known capabilities. Unknown future models need a capability
;; update rather than silently receiving incompatible controls.
(define (claude-fast? model) (if (member model '("claude-opus-5" "claude-opus-4-8")) #t #f))
(define (claude-adaptive? model)
  (if (member model '("claude-sonnet-4-6" "claude-opus-4-6" "claude-opus-4-7"
                     "claude-opus-4-8" "claude-opus-5" "claude-sonnet-5")) #t #f))
(define (claude-effort? model)
  (or (claude-adaptive? model) (string-prefix? "claude-opus-4-5" model)))
(define (block type key value) (json-object (cons "type" type) (cons key value)))
(define (claude-messages model messages)
  (let loop ((remaining messages) (out '()))
    (if (null? remaining) (reverse out)
        (let* ((message (car remaining)) (role (json-object-ref message "role"))
               (text (json-object-ref message "content" ""))
               (calls (json-array-items (json-object-ref message "tool_calls" (json-array))))
               (role* (if (string=? role "assistant") "assistant" "user"))
               (native (and (equal? (json-object-ref message "claude_model" #f) model)
                            (json-object-ref message "claude_blocks" #f)))
               (blocks
                (cond
                 ((string=? role "tool")
                  (list (json-object (cons "type" "tool_result")
                         (cons "tool_use_id" (json-object-ref message "tool_call_id")) (cons "content" text))))
                 (native (json-array-items native))
                 (else (append
                   (if (and (string? text) (not (string-null? text))) (list (block "text" "text" text)) '())
                   (map (lambda (call)
                     (let ((function (json-object-ref call "function")))
                       (json-object (cons "type" "tool_use") (cons "id" (json-object-ref call "id"))
                         (cons "name" (json-object-ref function "name"))
                         (cons "input" (json-object-ref function "arguments"))))) calls))))))
          (cond
           ((string=? role "system") (loop (cdr remaining) out))
           ((null? blocks) (loop (cdr remaining) out))
           ((and (pair? out) (string=? role* (json-object-ref (car out) "role")))
            (loop (cdr remaining)
              (cons (json-object (cons "role" role*) (cons "content"
                (apply json-array (append (json-array-items (json-object-ref (car out) "content")) blocks)))) (cdr out))))
           (else (loop (cdr remaining)
                   (cons (json-object (cons "role" role*) (cons "content" (apply json-array blocks))) out))))))))

(define (make-claude-request model messages tools stream? thinking effort fast? reserve)
  (when (and fast? (not (claude-fast? model))) (error "fast mode unsupported for model" model))
  (when (and (not (eq? effort 'default)) (not (claude-effort? model)))
    (error "effort unsupported for model" model))
  (apply json-object
    (append
     (list (cons "model" model) (cons "max_tokens" reserve) (cons "stream" stream?)
           (cons "messages" (apply json-array (claude-messages model messages)))
           (cons "system" (string-join
              (map (lambda (m) (json-object-ref m "content" ""))
                   (filter (lambda (m) (string=? (json-object-ref m "role") "system")) messages)) "\n\n")))
     (if (null? tools) '()
         (list (cons "tools" (apply json-array
           (map (lambda (name)
             (let ((schema (json-object-ref (tool-schema name) "function")))
               (json-object (cons "name" name)
                            (cons "description" (json-object-ref schema "description"))
                            (cons "input_schema" (json-object-ref schema "parameters"))))) tools)))))
     (if thinking
         (list (cons "thinking" (if (claude-adaptive? model)
                  (json-object (cons "type" "adaptive"))
                  (begin
                    (when (<= reserve 1024) (error "thinking requires output reserve above 1024"))
                    (json-object (cons "type" "enabled") (cons "budget_tokens" (min 4096 (- reserve 1024)))))))) '())
     (if (eq? effort 'default) '() (list (cons "output_config" (json-object (cons "effort" (symbol->string effort))))))
     (if fast? (list (cons "speed" "fast")) '()))))

(define (parse-claude-response root model)
  (when (json-object-ref root "error" #f) (error "Claude request failed" (json-write root)))
  (let* ((reason (json-object-ref root "stop_reason" #f))
         (blocks (json-array-items (json-object-ref root "content")))
         (text (string-concatenate (map (lambda (b) (json-object-ref b "text" "")) blocks)))
         (thought (string-concatenate (map (lambda (b) (json-object-ref b "thinking" "")) blocks)))
         (calls (map (lambda (b)
                       (let ((args (json-object-ref b "input")))
                         (unless (json-object? args) (error "Claude tool arguments must be an object"))
                         (make-tool-call (json-object-ref b "id") (json-object-ref b "name") args (json-write args))))
                     (filter (lambda (b) (equal? (json-object-ref b "type") "tool_use")) blocks))))
    (unless (member reason '("end_turn" "tool_use" "stop_sequence"))
      (error "Claude stopped before completing the answer" reason))
    (make-completion text thought calls
      (json-object (cons "role" "assistant") (cons "content" text)
        (cons "claude_model" model) (cons "claude_blocks" (apply json-array blocks))
        (cons "tool_calls" (apply json-array
          (map (lambda (call) (json-object (cons "id" (tool-call-id call)) (cons "type" "function")
            (cons "function" (json-object (cons "name" (tool-call-name call))
                                         (cons "arguments" (tool-call-arguments call)))))) calls)))) root)))

(define (provider-complete-claude model base-url key messages tools stream? thinking effort fast? reserve on-text on-thought)
  (unless (and (string? key) (not (string-null? key))) (error "CLAUDE_API_KEY is missing"))
  (when (or (string-index key #\newline) (string-index key #\return)) (error "invalid Claude key"))
  (let* ((headers (string-append "x-api-key: " key "\nanthropic-version: 2023-06-01\n"
                   (if fast? "anthropic-beta: fast-mode-2026-02-01\n" "")))
         (payload (json-write (make-claude-request model messages tools stream? thinking effort fast? reserve)))
         (endpoint (string-append (without-trailing-slash base-url) "/messages")))
    (if (not stream?)
        (parse-claude-response (json-read (curl-post-json endpoint #f payload headers)) model)
        (let ((blocks '()) (usage '()) (reason #f) (done? #f))
          (define (put-usage! value)
            (for-each (lambda (entry) (set! usage (acons (car entry) (cdr entry)
              (filter (lambda (p) (not (string=? (car p) (car entry)))) usage)))) (json-object-entries value)))
          (curl-post-json-lines endpoint #f payload
            (lambda (line)
              (when (string-prefix? "data:" line)
                (let* ((event (json-read (string-trim-both (substring line 5))))
                       (type (json-object-ref event "type")))
                  (cond
                   ((string=? type "error") (error "Claude stream error" (json-write event)))
                   ((string=? type "message_start")
                    (put-usage! (json-object-ref (json-object-ref event "message") "usage" (json-object))))
                   ((string=? type "content_block_start")
                    (set! blocks (acons (json-object-ref event "index")
                      (vector (json-object-ref event "content_block") "") blocks)))
                   ((string=? type "content_block_delta")
                    (let* ((state (assoc-ref blocks (json-object-ref event "index")))
                           (delta (json-object-ref event "delta")) (kind (json-object-ref delta "type"))
                           (field (cond ((string=? kind "text_delta") "text")
                                        ((string=? kind "thinking_delta") "thinking")
                                        ((string=? kind "signature_delta") "signature") (else #f))))
                      (unless state (error "Claude delta without block"))
                      (cond
                       ((string=? kind "input_json_delta")
                        (vector-set! state 1 (string-append (vector-ref state 1) (json-object-ref delta "partial_json"))))
                       (field
                        (let* ((chunk (json-object-ref delta field)) (old (vector-ref state 0)))
                          (vector-set! state 0 (apply json-object (acons field
                            (string-append (json-object-ref old field "") chunk)
                            (filter (lambda (p) (not (string=? (car p) field))) (json-object-entries old)))))
                          (cond ((string=? field "text") (on-text chunk))
                                ((string=? field "thinking") (on-thought chunk))))))))
                   ((string=? type "message_delta")
                    (set! reason (json-object-ref (json-object-ref event "delta") "stop_reason" #f))
                    (put-usage! (json-object-ref event "usage" (json-object))))
                   ((string=? type "message_stop") (set! done? #t)))))) headers)
          (unless done? (error "incomplete Claude stream: missing message_stop"))
          (parse-claude-response
            (json-object (cons "stop_reason" reason) (cons "usage" (apply json-object usage))
              (cons "content" (apply json-array
                (map (lambda (entry)
                  (let* ((state (cdr entry)) (value (vector-ref state 0)) (args (vector-ref state 1)))
                    (if (string-null? args) value
                        (apply json-object (acons "input" (json-read args)
                          (filter (lambda (p) (not (string=? (car p) "input"))) (json-object-entries value)))))))
                  (sort blocks (lambda (a b) (< (car a) (car b)))))))) model)))))
