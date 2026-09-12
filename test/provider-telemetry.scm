(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (ice-9 threads)
             (live-agent main)
             (live-agent generation)
             (live-agent settings)
             (live-agent provider)
             (live-agent provider-metadata)
             (live-agent json))

(test-begin "provider-telemetry")

;; Exercise the controller's actual event emitter without starting the app,
;; loading user settings, reading .env, or opening a provider connection.
(define generation
  (build-generation 1 "test/session-agent.scm"
                    (read-source-file "test/session-agent.scm") '()))
(define events '())
(define ui-module (resolve-module '(live-agent ui)))
(define original-emit (module-ref ui-module 'ui-emit!))
(module-set! ui-module 'ui-emit!
  (lambda (type value) (set! events (cons (cons type value) events))))
(define emit (@@ (live-agent main) emit-usage-snapshot!))
(define estimate (@@ (live-agent main) session-prompt-estimate))
(define reset (@@ (live-agent main) reset-run-usage!))
(define (latest key) (json-object-ref (cdar events) key))

(settings-set! '((agent-max-tool-rounds . 6) (context-limit . 8192)))
(parameterize ((current-metadata-fetch (lambda _ (error "unexpected metadata request"))))
  (reset)
  (emit generation (estimate generation '()))
  (test-equal "controller emits frontend's real event name" "usage" (caar events))
  (test-equal "initial controller snapshot has max rounds without discovery" 6 (latest "max_rounds"))
  (test-equal "initial controller snapshot has configured limit" 8192 (latest "limit"))
  (test-equal "initial controller snapshot has zero round" 0 (latest "round"))
  (test-assert "initial controller snapshot estimates prompt" (> (latest "prompt_tokens") 0))
  (test-equal "initial controller snapshot labels estimate" "estimated" (latest "prompt_source"))
  (test-equal "initial controller snapshot has explicit unknown memory" json-null (latest "memory_bytes"))
  (test-equal "initial controller snapshot explains unmeasured memory"
    "memory-not-measured" (latest "memory_reason"))
  (let ((initial (latest "prompt_tokens")))
    (reset)
    (emit generation (estimate generation
      (list (make-message "user" "A previous session question")
            (make-message "assistant" "A previous session answer with useful history."))))
    (test-assert "resume snapshot estimates restored history" (> (latest "prompt_tokens") initial))
    (test-equal "resume is not a currently active provider round" 0 (latest "round")))
  (emit generation 9000 (json-read "{\"prompt_eval_count\":8600}") 3)
  (test-equal "completion event uses renderer prompt_tokens key" 8600 (latest "prompt_tokens"))
  (test-equal "legacy prompt key retained" 8600 (latest "prompt"))
  (test-equal "completion has same max-rounds field" 6 (latest "max_rounds"))
  (setting-set! 'mode 'plan)
  (emit generation #f)
  (test-equal "mode change does not clear latest measured prompt" 8600 (latest "prompt_tokens"))
  (test-equal "mode change does not clear latest round" 3 (latest "round"))
  (emit generation #f)
  (test-equal "repeated session publication retains measurement source" "reported" (latest "prompt_source"))
  (setting-set! 'agent-max-tool-rounds 0)
  (emit generation #f)
  (test-equal "effective zero round cap survives encoding" 0 (latest "max_rounds"))
  (setting-set! 'agent-base-url "http://localhost:11435")
  (emit generation 125)
  (test-equal "endpoint change invalidates stale measured prompt" 125 (latest "prompt_tokens"))
  (test-equal "endpoint change resets round" 0 (latest "round"))
  (emit generation 250 (json-object) 0)
  (test-equal "new turn marks prompt as estimated" "estimated" (latest "prompt_source"))
  (test-equal "new turn starts at round zero" 0 (latest "round")))

(module-set! ui-module 'ui-emit! original-emit)

;; Run the real REPL startup publisher into the actual JSON event serializer.
;; In-memory runtime/session records avoid main's filesystem and .env setup.
(define main-module (resolve-module '(live-agent main)))
(define old-print (module-ref main-module 'print-mode?))
(define old-mcp (module-ref main-module 'mcp-http?))
(define old-port (module-ref ui-module 'event-port))
(define event-output (open-output-string))
(module-set! main-module 'print-mode? #t)
(module-set! main-module 'mcp-http? #f)
(module-set! ui-module 'event-port event-output)
(settings-set! '((agent-model . "demo") (context-limit . 8192) (agent-max-tool-rounds . 6)))
(define restored-history
  (list (make-message "user" "Earlier read request")
        (make-message "assistant" "Earlier answer")))
(define runtime
  ((@@ (live-agent runtime) %make-runtime) generation '() 2 #f (make-mutex)))
(define session
  ((@@ (live-agent session) %make-session-state)
   "resumed-fixture" "fixture-id" #f restored-history 4 1
   (generation-fingerprint generation) '() "fixture-date" #t #f #f #f))
(reset)
(parameterize ((current-metadata-fetch (lambda _ (error "resume must not probe demo"))))
  ((@@ (live-agent main) repl) runtime #f #f session (lambda _ #f) #f))
(define wire-events
  (map (lambda (line) (json-read (string-copy line)))
       (filter (lambda (line) (> (string-length line) 0))
               (string-split (get-output-string event-output) #\newline))))
(define initial-wire (car wire-events))
(test-equal "real resume wire starts with authoritative usage snapshot"
  "usage" (json-object-ref initial-wire "type"))
(test-equal "real resume snapshot carries renderer's exact prompt key"
  (estimate generation restored-history)
  (json-object-ref (json-object-ref initial-wire "value") "prompt"))
(test-equal "real initial snapshot carries max rounds before metadata"
  6 (json-object-ref (json-object-ref initial-wire "value") "max_rounds"))
(test-equal "real initial snapshot carries configured limit before metadata"
  8192 (json-object-ref (json-object-ref initial-wire "value") "limit"))
(test-equal "real initial wire does not omit zero round"
  0 (json-object-ref (json-object-ref initial-wire "value") "round"))
(test-equal "real initial wire does not omit unknown memory"
  json-null (json-object-ref (json-object-ref initial-wire "value") "memory_bytes"))
(test-equal "startup publishes both initial and enriched snapshots" 2
  (count (lambda (event) (equal? (json-object-ref event "type") "usage")) wire-events))
(test-equal "resumed session history is preserved without invented work"
  (json-write (apply json-array restored-history))
  (json-write (json-object-ref
    (find (lambda (event) (equal? (json-object-ref event "type") "history")) wire-events)
    "value")))
(test-assert "startup does not fabricate tool/file/receipt events"
  (not (any (lambda (event)
              (member (json-object-ref event "type") '("tool" "tool-result" "diff" "receipt")))
            wire-events)))
(module-set! main-module 'print-mode? old-print)
(module-set! main-module 'mcp-http? old-mcp)
(module-set! ui-module 'event-port old-port)
(close-port event-output)
(test-end "provider-telemetry")
