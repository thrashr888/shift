;; Optional tracing behind the small runtime-facing contract.
(define-module (live-agent trace)
  #:use-module (live-agent builtins)
  #:use-module (srfi srfi-9)
  #:export (make-tracer tracer? tracer-path tracer-session-id tracer-session-name
            usage-attributes trace-start! trace-end! trace-span-id trace-trace-id
            trace-search trace-close!))

(define-record-type <trace-context>
  (context path id name backend)
  tracer?
  (path tracer-path)
  (id tracer-session-id)
  (name tracer-session-name)
  (backend tracer-backend))

(define* (make-tracer directory #:optional
                      (endpoint (or (getenv "SHIFT_OTEL_ENDPOINT")
                                    (getenv "PHOENIX_COLLECTOR_ENDPOINT")))
                      (id #f) (name #f))
  (let ((backend (and (builtin-enabled? 'tracing)
                      ((builtin-ref 'tracing 'make-tracer) directory endpoint id name))))
    (context (string-append directory "/traces.jsonl")
             (or id (and backend ((builtin-ref 'tracing 'session-id-of) backend))
                 "untraced")
             name backend)))

(define (trace-start! tracer . args)
  (and (tracer-backend tracer)
       (apply (builtin-ref 'tracing 'trace-start!) (tracer-backend tracer) args)))
(define (trace-end! span . args)
  (when span (apply (builtin-ref 'tracing 'trace-end!) span args)))
(define (trace-span-id span)
  (and span ((builtin-ref 'tracing 'span-id-of) span)))
(define (trace-trace-id span)
  (and span ((builtin-ref 'tracing 'trace-id-of) span)))
(define (trace-search tracer . args)
  (if (tracer-backend tracer)
      (apply (builtin-ref 'tracing 'trace-search) (tracer-backend tracer) args)
      (values '() 0 0 0)))
(define (trace-close! tracer)
  (when (tracer-backend tracer)
    ((builtin-ref 'tracing 'trace-close!) (tracer-backend tracer))))

(define (usage-attributes completion)
  (if (builtin-enabled? 'tracing)
      ((builtin-ref 'tracing 'usage-attributes) completion) '()))
