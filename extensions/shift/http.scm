(define-module (shift http)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
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
          (let ((port (apply open-pipe* OPEN_READ "curl" "-sS" "-N" "--fail-with-body"
                                  "--connect-timeout" "10" "--max-time" "600"
                                  "--max-filesize" "4194304"
                                  "-H" (string-append "@" headers-path)
                                  (append (if payload (list "--data-binary" (string-append "@" payload-path)) '()) (list endpoint)))))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (let loop ((size 0))
                  (let ((line (get-line port)))
                    (unless (eof-object? line)
                      (let ((next (+ size (string-length line))))
                        (when (> next 4194304) (error "provider response exceeds 4 MiB"))
                        (unless (string-null? (string-trim-both line))
                          (consume-line line))
                        (loop next)))))
                (let ((exit-code (status:exit-val (close-pipe port))))
                  (unless (and exit-code (= exit-code 0))
                    (error "provider request failed" exit-code))))
              (lambda ()
                (unless (port-closed? port) (close-pipe port)))))))))))

(define* (curl-post-json endpoint api-key payload #:optional (extra-headers ""))
  (let ((output (open-output-string)))
    (curl-post-json-lines endpoint api-key payload
                          (lambda (line) (display line output) (newline output)) extra-headers)
    (get-output-string output)))

(define* (curl-get-json endpoint #:optional (key #f) (headers ""))
  (curl-post-json endpoint key #f headers))
