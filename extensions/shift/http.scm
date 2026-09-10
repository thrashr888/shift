(define-module (shift http)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent provider)
  #:export (without-trailing-slash curl-post-json curl-post-json-lines curl-get-json))

(define (without-trailing-slash value)
  (let loop ((end (string-length value)))
    (if (and (> end 0) (char=? (string-ref value (- end 1)) #\/))
        (loop (- end 1))
        (substring value 0 end))))

(define (call-with-temporary-content template content procedure)
  (let* ((port (mkstemp template))
         (path (port-filename port)))
    (dynamic-wind
      (lambda ()
        (display content port)
        (force-output port)
        (close-port port))
      (lambda () (procedure path))
      (lambda ()
        (when (file-exists? path) (delete-file path))))))

;; Retries are bounded and only happen when nothing of the response body was
;; handed to the consumer, so a stream that already produced output is never
;; replayed. The limit and observer are parameters owned by (live-agent provider).

;; Name resolution, connection, connect timeout, TLS handshake, empty reply,
;; and receive failures; all before or without any body.
(define retryable-curl-exits '(6 7 28 35 52 56))

(define (retry-delay-ms attempt retry-after)
  (let ((backoff (* 1000 (expt 2 (- attempt 1)))))
    (min 30000 (max backoff (or retry-after 0)))))

;; Short sleeps so a cancellation async lands promptly during a pause.
(define (pause-ms total)
  (let loop ((left total))
    (when (> left 0)
      (usleep (* 1000 (min left 100)))
      (loop (- left 100)))))

(define (parse-status line)
  (let ((parts (string-tokenize line)))
    (and (>= (length parts) 2)
         (string-prefix? "HTTP/" (car parts))
         (string->number (cadr parts)))))

(define (header-value line name)
  (let ((colon (string-index line #\:)))
    (and colon
         (string-ci=? (string-trim-both (substring line 0 colon)) name)
         (string-trim-both (substring line (+ colon 1))))))

;; One request with headers included in the output (-i), so the status is
;; known before any body line reaches the consumer. curl runs silent: every
;; failure is reported through the error raised here, with the status and body. Returns 'ok, or a list
;; (retry REASON RETRY-AFTER-MS) when the failure is retryable and no body
;; was consumed; anything else raises.
(define (attempt-once endpoint payload-path headers-path payload? consume-line)
  (let ((port (apply open-pipe* OPEN_READ "curl" "-s" "-N" "-i" "--fail-with-body"
                     "--connect-timeout" "10" "--max-time" "600"
                     "--max-filesize" "4194304"
                     "-H" (string-append "@" headers-path)
                     (append (if payload? (list "--data-binary" (string-append "@" payload-path)) '())
                             (list endpoint))))
        (phase 'status) (status #f) (retry-after #f) (consumed? #f)
        (error-body (open-output-string)) (error-size 0))
    (define (body-line! line size)
      (cond
       ((and status (>= status 200) (< status 300))
        (unless (string-null? (string-trim-both line))
          (set! consumed? #t)
          (consume-line line)))
       ((< error-size 4096)
        (display line error-body) (newline error-body)
        (set! error-size (+ error-size size)))))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let loop ((size 0))
          (let ((line (get-line port)))
            (unless (eof-object? line)
              (let ((next (+ size (string-length line))))
                (when (> next 4194304) (error "provider response exceeds 4 MiB"))
                (case phase
                  ((status)
                   (let ((code (parse-status line)))
                     (cond
                      ((not code) (set! phase 'body) (body-line! line (string-length line)))
                      ((< code 200) (set! phase 'skip-headers))
                      (else (set! status code) (set! phase 'headers)))))
                  ((skip-headers)
                   (when (string-null? (string-trim-both line)) (set! phase 'status)))
                  ((headers)
                   (cond
                    ((string-null? (string-trim-both line)) (set! phase 'body))
                    ((header-value line "retry-after")
                     => (lambda (value)
                          (let ((seconds (string->number value)))
                            (when seconds (set! retry-after (* 1000 seconds))))))))
                  ((body) (body-line! line (string-length line))))
                (loop next)))))
        (let ((exit-code (status:exit-val (close-pipe port))))
          (cond
           ((and status (>= status 200) (< status 300) exit-code (= exit-code 0)) 'ok)
           ((and status (retryable-status? status) (not consumed?))
            (list 'retry status retry-after))
           (status
            (error "provider request failed" status
                   (string-trim-both (get-output-string error-body))))
           ((and (not consumed?) exit-code (memv exit-code retryable-curl-exits))
            (list 'retry (string->symbol (string-append "curl-" (number->string exit-code))) #f))
           (else (error "provider request failed" exit-code)))))
      (lambda ()
        (unless (port-closed? port)
          (catch #t (lambda () (close-pipe port)) (lambda _ #f)))))))

(define* (curl-post-json-lines endpoint api-key payload consume-line #:optional (extra-headers ""))
  (when (and api-key
             (or (string-index api-key #\newline)
                 (string-index api-key #\return)))
    (error "API key contains an invalid newline"))
  (let ((headers
         (string-append "Content-Type: application/json\n" extra-headers
                        (if (and api-key (not (string-null? api-key)))
                            (string-append "Authorization: Bearer " api-key "\n") ""))))
    ;; Both transports share private request files, bounds, and cleanup.
    (call-with-temporary-content
     "/tmp/shift-request-XXXXXX" (or payload "")
     (lambda (payload-path)
       (call-with-temporary-content
        "/tmp/shift-headers-XXXXXX" headers
        (lambda (headers-path)
          (let loop ((attempt 1))
            (let ((outcome (attempt-once endpoint payload-path headers-path
                                         (if payload #t #f) consume-line)))
              (cond
               ((eq? outcome 'ok) #t)
               ((<= attempt (provider-retry-limit))
                (let ((delay (retry-delay-ms attempt (caddr outcome))))
                  ((current-retry-observer) attempt (cadr outcome) delay)
                  (pause-ms delay)
                  (loop (+ attempt 1))))
               (else (error "provider request failed after retries" (cadr outcome))))))))))))

(define* (curl-post-json endpoint api-key payload #:optional (extra-headers ""))
  (let ((output (open-output-string)))
    (curl-post-json-lines endpoint api-key payload
                          (lambda (line) (display line output) (newline output)) extra-headers)
    (get-output-string output)))

(define* (curl-get-json endpoint #:optional (key #f) (headers ""))
  (curl-post-json endpoint key #f headers))
