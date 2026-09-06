(define-module (shift tracing)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent provider)
  #:use-module (live-agent json)
  #:export (tracer?
            make-tracer
            tracer-path
            tracer-session-id
            tracer-session-name
            trace-start!
            trace-end!
            trace-span-id
            trace-search
            trace-close!
            session-id-of span-id-of usage-attributes))

(define-record-type <tracer>
  (%make-tracer path session-id session-name bridge)
  tracer?
  (path tracer-path)
  (session-id tracer-session-id)
  (session-name tracer-session-name)
  (bridge tracer-bridge set-tracer-bridge!))

(define-record-type <trace-span>
  (%make-trace-span tracer trace-id span-id parent-id name kind
                    start-ns start-ticks attributes ended?)
  trace-span?
  (tracer trace-span-tracer)
  (trace-id trace-span-trace-id)
  (span-id trace-span-id)
  (parent-id trace-span-parent-id)
  (name trace-span-name)
  (kind trace-span-kind)
  (start-ns trace-span-start-ns)
  (start-ticks trace-span-start-ticks)
  (attributes trace-span-attributes)
  (ended? trace-span-ended? set-trace-span-ended?!))

(define id-counter 0)

(define (wall-time-ns)
  (let ((value (gettimeofday)))
    (+ (* (car value) 1000000000) (* (cdr value) 1000))))

(define (fresh-hex width)
  (set! id-counter (+ id-counter 1))
  (let* ((now (gettimeofday))
         (seed (+ (* (car now) 1000003)
                  (cdr now)
                  (* (getpid) 7919)
                  id-counter)))
    (let loop ((remaining width) (value seed) (parts '()))
      (if (= remaining 0)
          (string-concatenate-reverse parts)
          (let* ((chunk-width (min 8 remaining))
                 (chunk (modulo value (expt 16 chunk-width))))
            (loop (- remaining chunk-width)
                  (+ (quotient value 17) (* id-counter 104729))
                  (cons (format #f "~v,'0x" chunk-width chunk) parts)))))))

(define (attribute-key value)
  (if (symbol? value) (symbol->string value) value))

(define (bounded value)
  (if (and (string? value) (> (string-length value) 4096))
      (string-append (substring value 0 4096)
                     "\n…[trace attribute truncated; original chars="
                     (number->string (string-length value)) "]")
      value))

(define (attributes->json attributes)
  (apply
   json-object
   (map (lambda (entry)
          (cons (attribute-key (car entry)) (bounded (cdr entry))))
        attributes)))

(define (open-otel-bridge endpoint)
  (let* ((root (or (getenv "SHIFT_PROJECT_ROOT")
                   (getenv "LISP_AGENT_PROJECT_ROOT")))
         (script (and root (string-append root "/extensions/shift/otel.py"))))
    (if (and endpoint script (file-exists? script))
        (begin
          ;; An optional exporter must never take down the local harness when
          ;; its collector or dependency runner exits early.
          (sigaction SIGPIPE SIG_IGN)
          (open-pipe* OPEN_WRITE
                      "uv" "run" "--quiet" "--script" script
                      "--endpoint" endpoint
                      "--project" "shift"))
        #f)))

(define* (make-tracer state-directory
                      #:optional
                      (endpoint (or (getenv "SHIFT_OTEL_ENDPOINT")
                                    (getenv "LISP_AGENT_OTEL_ENDPOINT")
                                    (getenv "PHOENIX_COLLECTOR_ENDPOINT")))
                      (session-id #f)
                      (session-name #f))
  (let ((path (string-append state-directory "/traces.jsonl")))
    (%make-tracer path (or session-id (fresh-hex 32)) session-name
                  (open-otel-bridge endpoint))))

(define* (trace-start! tracer name kind attributes #:optional parent)
  (%make-trace-span
   tracer
   (if parent (trace-span-trace-id parent) (fresh-hex 32))
   (fresh-hex 16)
   (and parent (trace-span-id parent))
   name
   kind
   (wall-time-ns)
   (get-internal-real-time)
   (append
    `((openinference.span.kind . ,kind)
      (session.id . ,(tracer-session-id tracer)))
    (if (tracer-session-name tracer)
        `((session.name . ,(tracer-session-name tracer)))
        '())
    attributes)
   #f))

(define (write-span! span end-ns duration-ms status attributes)
  (let* ((tracer (trace-span-tracer span))
         (value
          (json-object
           (cons "trace_id" (trace-span-trace-id span))
           (cons "span_id" (trace-span-id span))
           (cons "parent_span_id"
                 (or (trace-span-parent-id span) json-null))
           (cons "name" (trace-span-name span))
           (cons "kind" (trace-span-kind span))
           (cons "start_time_unix_nano" (trace-span-start-ns span))
           (cons "end_time_unix_nano" end-ns)
           (cons "duration_ms" duration-ms)
           (cons "status" status)
           (cons "attributes"
                 (attributes->json
                  (append (trace-span-attributes span) attributes)))))
         (line (json-write value)))
    (let ((port (open-file (tracer-path tracer) "a")))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
        (display line port)
        (newline port)
          (force-output port))
        (lambda () (close-port port))))
    (let ((bridge (tracer-bridge tracer)))
      (when bridge
        (catch #t
          (lambda ()
            (display line bridge)
            (newline bridge)
            (force-output bridge))
          (lambda _
            (catch #t
              (lambda () (close-pipe bridge))
              (lambda _ #f))
            (set-tracer-bridge! tracer #f)))))))

(define* (trace-end! span #:optional (status "OK") (attributes '()))
  (unless (trace-span-ended? span)
    (let* ((end-ns (wall-time-ns))
           (elapsed (- (get-internal-real-time)
                       (trace-span-start-ticks span)))
           (duration-ms
            (/ (round (* 1000.0 (/ elapsed internal-time-units-per-second)))
               1.0)))
      (write-span! span end-ns duration-ms status attributes)
      (set-trace-span-ended?! span #t))))

(define (same-filter-value? actual expected)
  (cond
   ((not expected) #t)
   ((and (string? actual) (string? expected))
    (string-ci=? actual expected))
   (else (equal? actual expected))))

(define (trace-preview attributes)
  (let ((value
         (or (json-object-ref attributes "error.message" #f)
             (json-object-ref attributes "output.value" #f)
             (json-object-ref attributes "input.value" #f)
             (json-object-ref attributes "context.paths" #f))))
    (if (and (string? value) (> (string-length value) 240))
        (string-append (substring value 0 240) "…")
        (or value ""))))

(define (trace-hit span)
  (let ((attributes (json-object-ref span "attributes" (json-object))))
    (json-object
     (cons "trace_id" (json-object-ref span "trace_id" ""))
     (cons "span_id" (json-object-ref span "span_id" ""))
     (cons "parent_span_id"
           (json-object-ref span "parent_span_id" json-null))
     (cons "name" (json-object-ref span "name" ""))
     (cons "kind" (json-object-ref span "kind" ""))
     (cons "status" (json-object-ref span "status" ""))
     (cons "duration_ms" (json-object-ref span "duration_ms" 0))
     (cons "start_time_unix_nano"
           (json-object-ref span "start_time_unix_nano" 0))
     (cons "generation"
           (json-object-ref attributes "generation.id" json-null))
     (cons "turn" (json-object-ref attributes "turn.number" json-null))
     (cons "cache_status"
           (json-object-ref attributes "llm.prompt_cache.status" json-null))
     (cons "cached_tokens"
           (json-object-ref attributes
                            "llm.token_count.prompt_cached" json-null))
     (cons "preview" (trace-preview attributes)))))

;; Scan the complete append-only trace file while retaining only a bounded set
;; of newest matches. Search hits are compact and carry stable span IDs; an
;; exact span-id lookup returns the full stored span for follow-up inspection.
(define* (trace-search tracer
                       #:key
                       (query #f)
                       (span-id #f)
                       (name #f)
                       (kind #f)
                       (status #f)
                       (generation #f)
                       (turn #f)
                       (errors-only? #f)
                       (limit 12))
  (if (not (file-exists? (tracer-path tracer)))
      (values '() 0 0 0)
      (let ((needle (and query (string-downcase query)))
            (session-id (tracer-session-id tracer)))
        (call-with-input-file
            (tracer-path tracer)
          (lambda (port)
            (let loop ((matches '()) (matched 0) (scanned 0) (malformed 0))
              (let ((line (get-line port)))
                (if (eof-object? line)
                    (values matches matched scanned malformed)
                    (let ((next-scanned (+ scanned 1)))
                      (catch #t
                        (lambda ()
                          (let* ((span (json-read line))
                                 (attributes
                                  (json-object-ref span "attributes"
                                                   (json-object)))
                                 (in-session?
                                  (string=?
                                   (json-object-ref attributes "session.id" "")
                                   session-id))
                                 (matches?
                                  (and
                                   in-session?
                                   (or (not needle)
                                       (string-contains
                                        (string-downcase line) needle))
                                   (same-filter-value?
                                    (json-object-ref span "span_id" #f) span-id)
                                   (same-filter-value?
                                    (json-object-ref span "name" #f) name)
                                   (same-filter-value?
                                    (json-object-ref span "kind" #f) kind)
                                   (same-filter-value?
                                    (json-object-ref span "status" #f) status)
                                   (same-filter-value?
                                    (json-object-ref attributes
                                                     "generation.id" #f)
                                    generation)
                                   (same-filter-value?
                                    (json-object-ref attributes
                                                     "turn.number" #f)
                                    turn)
                                   (or (not errors-only?)
                                       (member
                                        (json-object-ref span "status" "")
                                        '("ERROR" "CANCELLED"))))))
                            (if matches?
                                (let ((next
                                       (cons (if span-id span (trace-hit span))
                                             matches)))
                                  (loop (take next (min limit (length next)))
                                        (+ matched 1) next-scanned malformed))
                                (loop matches matched next-scanned malformed))))
                        (lambda _
                          (loop matches matched next-scanned (+ malformed 1)))))))))))))

(define (trace-close! tracer)
  (let ((bridge (tracer-bridge tracer)))
    (when bridge
      (catch #t
        (lambda () (close-pipe bridge))
        (lambda _ #f))
      (set-tracer-bridge! tracer #f))))

(define (session-id-of tracer) (tracer-session-id tracer))
(define (span-id-of span) (trace-span-id span))

(define (usage-attributes completion)
  (let* ((root (completion-usage completion))
         (openai-usage
          (and (json-object? root)
               (json-object-ref root "usage" #f)))
         (prompt
          (if (and openai-usage (json-object? openai-usage))
              (json-object-ref openai-usage "prompt_tokens"
                (let ((input (json-object-ref openai-usage "input_tokens" #f)))
                  (and input (+ input (json-object-ref openai-usage "cache_read_input_tokens" 0)
                                     (json-object-ref openai-usage "cache_creation_input_tokens" 0)))))
              (and (json-object? root)
                   (json-object-ref root "prompt_eval_count" #f))))
         (output
          (if (and openai-usage (json-object? openai-usage))
              (json-object-ref openai-usage "completion_tokens"
                (json-object-ref openai-usage "output_tokens" #f))
              (and (json-object? root)
                   (json-object-ref root "eval_count" #f))))
         (prompt-details
          (and openai-usage
               (json-object? openai-usage)
               (json-object-ref openai-usage "prompt_tokens_details" #f)))
         (completion-details
          (and openai-usage
               (json-object? openai-usage)
               (json-object-ref openai-usage "completion_tokens_details" #f)))
         (cached
          (or (and prompt-details (json-object? prompt-details)
                   (json-object-ref prompt-details "cached_tokens" #f))
              (and openai-usage (json-object-ref openai-usage "cache_read_input_tokens" #f))))
         (cache-write
          (or (and prompt-details (json-object? prompt-details)
                   (json-object-ref prompt-details "cache_write_tokens" #f))
              (and openai-usage (json-object-ref openai-usage "cache_creation_input_tokens" #f))))
         (reasoning
          (and completion-details
               (json-object? completion-details)
               (json-object-ref completion-details "reasoning_tokens" #f)))
         (cache-hit?
          (and (number? cached) (> cached 0)))
         (uncached
          (and (number? prompt) (number? cached)
               (max 0 (- prompt cached))))
         (metric
          (lambda (name)
            (and (json-object? root) (json-object-ref root name #f)))))
    (append
     (if prompt `((llm.token_count.prompt . ,prompt)) '())
     (if output `((llm.token_count.completion . ,output)) '())
     (if cached `((llm.token_count.prompt_cached . ,cached)) '())
     (if (number? cached)
         `((llm.prompt_cache.hit . ,cache-hit?)
           (llm.prompt_cache.status . ,(if cache-hit? "hit" "miss")))
         '())
     (if uncached `((llm.token_count.prompt_uncached . ,uncached)) '())
     (if cache-write `((llm.token_count.prompt_cache_write . ,cache-write)) '())
     (if reasoning `((llm.token_count.reasoning . ,reasoning)) '())
     (if (metric "total_duration")
         `((llm.total_duration_ns . ,(metric "total_duration"))) '())
     (if (metric "load_duration")
         `((llm.load_duration_ns . ,(metric "load_duration"))) '())
     (if (metric "prompt_eval_duration")
         `((llm.prompt_eval_duration_ns . ,(metric "prompt_eval_duration"))) '())
     (if (metric "eval_duration")
         `((llm.eval_duration_ns . ,(metric "eval_duration"))) '()))))
