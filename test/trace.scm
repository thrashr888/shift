(use-modules (ice-9 textual-ports) (srfi srfi-64)
             (live-agent json)
             (live-agent trace))

(test-begin "trace")

(define test-root
  (string-append "/tmp/shift-trace-test-" (number->string (getpid))))
(system* "mkdir" "-p" test-root)

(define tracer (make-tracer test-root #f))
(define root
  (trace-start! tracer "agent.turn" "AGENT" '((input.value . "hello"))))
(define child
  (trace-start! tracer "ollama.chat" "LLM" '((llm.model_name . "fixture")) root))

(trace-end! child "OK" '((output.value . "hi")))
(trace-end! root "OK" '((output.value . "hi")))

(define lines
  (call-with-input-file (tracer-path tracer)
    (lambda (port) (list (get-line port) (get-line port)))))
(test-equal "writes both completed spans" 2 (length lines))

(define child-json (json-read (car lines)))
(define root-json (json-read (cadr lines)))
(test-equal "child keeps its OpenInference kind"
  "LLM"
  (json-object-ref child-json "kind"))
(test-equal "root finishes after its children"
  "AGENT"
  (json-object-ref root-json "kind"))
(test-equal "child points at root"
  (json-object-ref root-json "span_id")
  (json-object-ref child-json "parent_span_id"))

(trace-close! tracer)

(define named-tracer (make-tracer test-root #f "stable-session-id" "dogfood"))
(define named-span
  (trace-start! named-tracer "agent.turn" "AGENT"
                '((generation.id . 2)
                  (turn.number . 17)
                  (input.value . "remember the old deploy port"))))
(trace-end! named-span "OK" '((output.value . "Use port 4317 after compaction.")))
(define named-json
  (call-with-values
      (lambda () (trace-search named-tracer #:span-id (trace-span-id named-span)))
    (lambda (hits . _) (car hits))))
(define named-attributes (json-object-ref named-json "attributes"))
(test-equal "a resumed session keeps its trace identity"
  "stable-session-id"
  (json-object-ref named-attributes "session.id"))
(test-equal "traces carry the human session name"
  "dogfood"
  (json-object-ref named-attributes "session.name"))

(call-with-values
    (lambda ()
      (trace-search named-tracer #:query "PORT 4317" #:limit 5))
  (lambda (hits matched scanned malformed)
    (test-equal "search scans durable history case-insensitively" 1 matched)
    (test-equal "search returns a compact stable span reference"
      (trace-span-id named-span)
      (json-object-ref (car hits) "span_id"))
    (test-equal "search returns the generating turn" 17
      (json-object-ref (car hits) "turn"))
    (test-equal "valid trace file has no malformed lines" 0 malformed)))

(call-with-values
    (lambda ()
      (trace-search named-tracer #:span-id (trace-span-id named-span) #:limit 1))
  (lambda (spans matched scanned malformed)
    (test-equal "exact span lookup returns full stored attributes"
      "Use port 4317 after compaction."
      (json-object-ref
       (json-object-ref (car spans) "attributes") "output.value"))))
(system* "mkdir" "-p" (string-append test-root "/other"))
(define other-tracer (make-tracer (string-append test-root "/other") #f "other-session-id" "other"))
(define other-span (trace-start! other-tracer "tool.read" "TOOL" '((turn.number . 3) (input.value . "port 4317 again"))))
(trace-end! other-span "OK" '((output.value . "newer")))
(call-with-values
    (lambda ()
      (trace-recall (list (cons "dogfood" (tracer-path named-tracer))
                          (cons "other" (tracer-path other-tracer)))
                    #:query "port 4317" #:limit 5))
  (lambda (hits matched scanned malformed)
    (test-equal "recall searches every session file" 2 matched)
    (test-equal "recall tags hits with their session and orders newest first"
      '("other" "dogfood")
      (map (lambda (hit) (json-object-ref hit "session")) hits))))
(call-with-values
    (lambda () (trace-recall (list (cons "other" (tracer-path other-tracer))) #:query "4317" #:errors-only? #t))
  (lambda (hits matched scanned malformed)
    (test-equal "recall honours the errors filter" 0 matched)))
(trace-close! other-tracer)
(trace-close! named-tracer)

(test-end "trace")
