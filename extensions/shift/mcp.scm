(define-module (shift mcp)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (live-agent json)
  #:export (start-mcp! run-mcp-stdio mcp-dispatch))

(define protocol-version "2025-11-25")
(define (tool name description properties required)
  (json-object (cons "name" name) (cons "description" description)
    (cons "inputSchema" (json-object (cons "type" "object") (cons "properties" properties)
                                    (cons "required" required) (cons "additionalProperties" #f)))))
(define tools
  (json-array
    (tool "shift_cancel" "Cancel the active turn while preserving its prior checkpoint." (json-object) (json-array))
    (tool "shift_status" "Inspect this live Shift process, project, model, settings and session." (json-object) (json-array))
    (tool "shift_prompt" "Submit a prompt to the live session. Uses the session's tool approval policy; busy sessions reject concurrent turns."
      (json-object (cons "text" (json-object (cons "type" "string")))) (json-array "text"))
    (tool "shift_inspect" "Inspect live state using /show, /settings, /context, /session, /generations, /receipt, /traces or /trace ID."
      (json-object (cons "command" (json-object (cons "type" "string")))) (json-array "command"))))
(define (mcp-dispatch request dispatch)
  (let ((id (json-object-ref request "id" #f))
        (method (json-object-ref request "method" ""))
        (params (json-object-ref request "params" (json-object))))
    (define (response value) (json-object (cons "jsonrpc" "2.0") (cons "id" id) (cons "result" value)))
    (catch #t
      (lambda ()
        (cond
          ((not id) #f)
          ((string=? method "initialize")
           (response (json-object (cons "protocolVersion" protocol-version)
             (cons "capabilities" (json-object (cons "tools" (json-object))))
             (cons "serverInfo" (json-object (cons "name" "shift") (cons "version" "0.1.0"))))))
          ((string=? method "ping") (response (json-object)))
          ((string=? method "tools/list") (response (json-object (cons "tools" tools))))
          ((string=? method "tools/call")
           (let* ((name (json-object-ref params "name"))
                  (arguments (json-object-ref params "arguments" (json-object)))
                  (result (cond
                    ((string=? name "shift_cancel") (dispatch 'cancel #f))
                    ((string=? name "shift_status") (dispatch 'status #f))
                    ((string=? name "shift_prompt") (dispatch 'prompt (json-object-ref arguments "text")))
                    ((string=? name "shift_inspect") (dispatch 'inspect (json-object-ref arguments "command")))
                    (else (error "unknown tool" name)))))
             (response (json-object (cons "isError" #f)
               (cons "content" (json-array (json-object (cons "type" "text")
                 (cons "text" (if (string? result) result (json-write result))))))))))
          (else (error "unsupported method" method))))
      (lambda (key . args)
        (if (string=? method "tools/call")
          (response (json-object (cons "isError" #t) (cons "content" (json-array
            (json-object (cons "type" "text") (cons "text" (format #f "~a: ~s" key args)))))))
          (json-object (cons "jsonrpc" "2.0") (cons "id" id)
            (cons "error" (json-object (cons "code" -32601) (cons "message" "Unsupported or invalid request")))))))))

(define (run-mcp-stdio dispatch)
  (let loop ((line (get-line (current-input-port))))
    (unless (eof-object? line)
      (let ((response (catch #t
                        (lambda () (mcp-dispatch (json-read line) dispatch))
                        (lambda _ (json-object (cons "jsonrpc" "2.0") (cons "id" json-null)
                          (cons "error" (json-object (cons "code" -32700) (cons "message" "Invalid JSON"))))))))
        (when response (display (json-write response)) (newline) (force-output)))
      (loop (get-line (current-input-port))))))

(define (start-mcp! port-number dispatch)
  (let ((listener (socket PF_INET SOCK_STREAM 0)) (running? #t) (clients '()) (lock (make-mutex)))
    (setsockopt listener SOL_SOCKET SO_REUSEADDR 1)
    (bind listener AF_INET INADDR_LOOPBACK port-number)
    (listen listener 16)
    (sigaction SIGPIPE SIG_IGN)
    (define (respond client code value)
      (let ((body (if value (string->utf8 (json-write value)) (make-bytevector 0))))
        (write-response (build-response #:code code #:headers
          `((content-type . (application/json)) (content-length . ,(bytevector-length body))
            (connection . (close)))) client)
        (put-bytevector client body) (force-output client)))
    (define (serve client)
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (catch #t
            (lambda ()
              (let* ((request (read-request client))
                     (headers (request-headers request))
                     (host (assq-ref headers 'host))
                     (origin (assq-ref headers 'origin))
                     (length* (or (assq-ref headers 'content-length) 0))
                     (expected-token (getenv "SHIFT_MCP_TOKEN"))
                     ;; Drain bounded bodies even when rejecting headers, so
                     ;; closing the socket does not replace our HTTP error with RST.
                     (body (and (<= length* 1048576) (not (assq-ref headers 'transfer-encoding))
                                (read-request-body request))))
                (cond
                  ((or (not host) (not (member (car host) '("127.0.0.1" "localhost")))
                       (and origin (not (member origin
                         (list (format #f "http://127.0.0.1:~a" port-number)
                               (format #f "http://localhost:~a" port-number))))))
                   (respond client 403 #f))
                  ((and expected-token
                        (not (equal? (assq-ref headers 'authorization) (string-append "Bearer " expected-token))))
                   (respond client 401 #f))
                  ((not (string=? (uri-path (request-uri request)) "/mcp")) (respond client 404 #f))
                  ((not (eq? (request-method request) 'POST)) (respond client 405 #f))
                  ((or (> length* 1048576) (assq-ref headers 'transfer-encoding)) (respond client 413 #f))
                  (else
                    (let* ((response (mcp-dispatch (json-read (utf8->string body)) dispatch)))
                      (respond client (if response 200 202) response))))))
            (lambda _ (catch #t (lambda () (respond client 400 #f)) (lambda _ #f)))))
        (lambda ()
          (unless (port-closed? client) (close-port client))
          (with-mutex lock (set! clients (delq client clients))))))
    (let ((thread
           (call-with-new-thread
             (lambda ()
               (let loop ()
                 (when running?
                   (catch #t
                     (lambda ()
                       (let ((client (car (accept listener))))
                         (setsockopt client SOL_SOCKET SO_RCVTIMEO '(5 . 0))
                         (with-mutex lock (set! clients (cons client clients)))
                         (call-with-new-thread (lambda () (serve client)))))
                     (lambda _ #f))
                   (loop)))))))
      (lambda ()
        (set! running? #f)
        ;; Waking accept is portable; shutdown on a listening socket raises
        ;; ENOTCONN on macOS and closing from another thread need not wake it.
        (let ((wake (socket PF_INET SOCK_STREAM 0)))
          (connect wake AF_INET INADDR_LOOPBACK port-number)
          (close-port wake))
        (with-mutex lock
          (for-each (lambda (client) (catch #t (lambda () (shutdown client 2)) (lambda _ #f))) clients))
        (join-thread thread)
        (close-port listener)))))
