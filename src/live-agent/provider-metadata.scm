(define-module (live-agent provider-metadata)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (web uri)
  #:use-module (live-agent json)
  #:export (loaded-ollama-metadata
            make-provider-metadata-cache
            provider-metadata!
            provider-configured-metadata
            provider-usage-event
            provider-session-usage-event
            current-metadata-fetch
            current-metadata-clock))

;; Telemetry is deliberately separate from inference and model catalog requests:
;; no credentials, redirects, retries, remote hosts, or /api/show architecture
;; maxima. /api/ps describes residency, not model download size or host RAM.
(define (local-metadata-url? base)
  (catch #t
    (lambda ()
      (let ((uri (and (string? base) (string->uri base))))
        (and uri (memq (uri-scheme uri) '(http https))
             (not (uri-userinfo uri))
             (member (uri-host uri) '("127.0.0.1" "::1" "localhost"))
             (not (uri-query uri)) (not (uri-fragment uri)))))
    (lambda _ #f)))

(define (fetch-loaded-models base)
  (catch #t
    (lambda ()
      (let* ((endpoint (string-append (string-trim-right base #\/) "/api/ps"))
             (port (open-pipe* OPEN_READ "curl" "--disable" "--silent" "--fail"
                              "--noproxy" "*" "--proto" "=http,https"
                              "--connect-timeout" "1" "--max-time" "1"
                              "--max-filesize" "65536" endpoint))
             (status #f)
             (body (dynamic-wind
                     (lambda () #t)
                     (lambda () (get-string-n port 65537))
                     (lambda () (set! status (close-pipe port))))))
        (cond
         ((not (zero? status)) "metadata-unreachable")
         ((or (eof-object? body) (> (string-length body) 65536))
          "metadata-invalid")
         ;; get-string-n can return a shared slice; materialize it for Guile's
         ;; compiled string indexing in the JSON reader.
         (else (json-read (string-copy body))))))
    (lambda (key . args)
      (if (eq? key 'turn-cancelled) (apply throw key args) "metadata-invalid"))))

(define current-metadata-fetch (make-parameter fetch-loaded-models))
(define current-metadata-clock
  (make-parameter (lambda () (/ (get-internal-real-time) internal-time-units-per-second))))

(define (count? value minimum)
  (and (exact-integer? value) (>= value minimum)))

(define (metadata-result provider model limit source memory context-reason memory-reason)
  (json-object
   (cons "provider" (if (symbol? provider) (symbol->string provider) provider))
   (cons "model" model)
   (cons "context_limit" (or limit json-null))
   (cons "context_source" (or source json-null))
   (cons "memory_bytes" (if (number? memory) memory json-null))
   (cons "memory_label" (if (number? memory) "GPU/model allocated" json-null))
   (cons "context_reason" (or context-reason json-null))
   (cons "memory_reason" (or memory-reason json-null))
   (cons "reason" (if (or context-reason memory-reason)
                      (string-join (delete-duplicates
                                    (filter identity (list context-reason memory-reason))) "; ")
                      json-null))))

(define (canonical-model model)
  (if (string-index (last (string-split model #\/)) #\:)
      model (string-append model ":latest")))

(define (loaded-ollama-metadata model root)
  (let* ((models (and (json-object? root) (json-object-ref root "models" #f)))
         (loaded (and (json-array? models)
                      (find (lambda (entry)
                              (and (json-object? entry)
                                   (any (lambda (field)
                                          (let ((name (json-object-ref entry field #f)))
                                            (and (string? name)
                                                 (string=? (canonical-model name)
                                                           (canonical-model model)))))
                                        '("name" "model"))))
                            (json-array-items models))))
         (reason (cond ((not (json-array? models)) "metadata-invalid")
                       ((not loaded) "model-not-loaded") (else #f)))
         (context (and loaded (json-object-ref loaded "context_length" #f)))
         (memory (and loaded (json-object-ref loaded "size_vram" #f)))
         (context (and (count? context 1) context))
         (memory (and (count? memory 0) memory)))
    (metadata-result 'ollama model context (and context "ollama:/api/ps")
                     memory (and (not context) (or reason "loaded-context-unavailable"))
                     (and (not memory) (or reason "loaded-memory-unavailable")))))

(define (with-context-override metadata override)
  (if (not (count? override 1)) metadata
      (apply json-object
             (append (list (cons "context_limit" override)
                           (cons "context_source" "override")
                           (cons "context_reason" json-null)
                           (cons "reason" (json-object-ref metadata "memory_reason")))
                     (filter (lambda (entry)
                               (not (member (car entry)
                                            '("context_limit" "context_source" "context_reason" "reason"))))
                             (json-object-entries metadata))))))

;; One identity only: switching provider/model/endpoint drops old residency
;; facts, including switching away and back. Cache failures too. Callers invoke
;; this on session/usage events, never from a renderer or periodic draw.
(define (make-provider-metadata-cache)
  (let ((key #f) (checked #f) (cached #f))
    (lambda (provider model base override)
      (let* ((next-key (list provider model base))
             (now ((current-metadata-clock))))
        (unless (and (equal? key next-key) checked (< (- now checked) 5))
          (set! key next-key)
          (set! cached
            (let ((reason (cond ((equal? model "demo") "demo-no-metadata")
                                ((not (eq? provider 'ollama)) "provider-metadata-unsupported")
                                ((not (local-metadata-url? base)) "remote-metadata-disabled")
                                (else #f))))
              (if reason
                  (metadata-result provider model #f #f #f reason reason)
                  (let ((root (catch #t
                                (lambda () ((current-metadata-fetch) base))
                                (lambda (key . args)
                                  (if (eq? key 'turn-cancelled)
                                      (apply throw key args) "metadata-unreachable")))))
                    (if (string? root)
                        (metadata-result provider model #f #f #f root root)
                        (loaded-ollama-metadata model root))))))
          (set! checked ((current-metadata-clock))))
        (with-context-override cached override)))))

(define provider-metadata! (make-provider-metadata-cache))

(define (provider-configured-metadata provider model override)
  (with-context-override
    (metadata-result provider model #f #f #f "context-not-measured" "memory-not-measured")
    override))

;; A missing reported prompt count is not a reported zero. Preserve that
;; distinction when a local estimate is the only available numerator.
(define (provider-usage-event raw estimate round max-rounds metadata)
  (let* ((usage (and (json-object? raw) (json-object-ref raw "usage" #f)))
         (reported
           (if (json-object? usage)
               (json-object-ref usage "prompt_tokens"
                 (let ((input (json-object-ref usage "input_tokens" #f))
                       (read (json-object-ref usage "cache_read_input_tokens" 0))
                       (write (json-object-ref usage "cache_creation_input_tokens" 0)))
                   (and (every (lambda (value) (count? value 0)) (list input read write))
                        (+ input read write))))
               (and (json-object? raw) (json-object-ref raw "prompt_eval_count" #f))))
         (reported? (count? reported 0))
         (estimated? (count? estimate 0)))
    (apply json-object
     (cons "prompt_tokens" (cond (reported? reported) (estimated? estimate) (else json-null)))
     (cons "prompt" (cond (reported? reported) (estimated? estimate) (else json-null)))
     (cons "prompt_source" (cond (reported? "reported") (estimated? "estimated")
                                 (else "unavailable")))
     (cons "prompt_reason" (if reported? json-null "provider-not-measured"))
     (cons "round" round)
     (cons "round_source" (if (= round 0) "not-started" "reported"))
     (cons "limit" (json-object-ref metadata "context_limit"))
     (cons "max_rounds" max-rounds)
     (json-object-entries metadata))))

;; Session/mode/theme publications refresh effective limits and metadata,
;; but must not replace the last reported numerator with a new estimate.
(define (provider-session-usage-event previous estimate max-rounds metadata)
  (let* ((same? (and previous
                    (every (lambda (key)
                             (equal? (json-object-ref previous key #f)
                                     (json-object-ref metadata key)))
                           '("provider" "model"))))
         (snapshot (provider-usage-event
                     (json-object) estimate 0 max-rounds metadata))
         (preserved '("prompt_tokens" "prompt" "prompt_source" "prompt_reason"
                      "round" "round_source")))
    (if (not same?) snapshot
        (apply json-object
          (map (lambda (entry)
                 (if (member (car entry) preserved)
                     (cons (car entry) (json-object-ref previous (car entry)))
                     entry))
               (json-object-entries snapshot))))))
