(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (live-agent generation)
             (live-agent json)
             (live-agent provider)
             (live-agent runtime)
             (live-agent session))

(define fixture-source
  (string-append
   "(define agent-name \"session-fixture\")\n"
   "(define agent-provider 'ollama)\n"
   "(define agent-model \"demo\")\n"
   "(define agent-base-url \"http://127.0.0.1:9999\")\n"
   "(define agent-api-key-environment #f)\n"
   "(define agent-stream? #t)\n"
   "(define agent-thinking #f)\n"
   "(define agent-keep-alive \"10m\")\n"
   "(define agent-max-tool-rounds 2)\n"
   "(define agent-compaction-threshold 12)\n"
   "(define agent-compaction-keep-recent 4)\n"
   "(define agent-system-prompt \"fixture prompt\")\n"
   "(define agent-tools '(read))\n"
   "(define agent-shell-policy 'deny)\n"
   "(define (agent-select-context text) '())\n"
   "(define (agent-transform-user text) text)\n"
   "(define (agent-demo-response text) (string-append \"session: \" text))\n"))

(define test-root
  (string-append "/tmp/shift-session-test-" (number->string (getpid))))
(define source-path (string-append test-root "/agent.scm"))

(system* "mkdir" "-p" test-root)
(call-with-output-file source-path
  (lambda (port) (display fixture-source port)))

(test-begin "durable session")

(define state (open-session! test-root "dogfood" 'new))
(define runtime
  (make-runtime source-path (session-directory state)
                (session-patches state) (session-generation-id state)))
(define history
  (list (make-message "user" "hello")
        (make-message "assistant" "hi")))

(runtime-eval! runtime "(set! agent-system-prompt \"remembered\")")
(save-session! state runtime history 2)
(close-session! state)

(define resumed (open-session! test-root "dogfood" 'resume))

(test-assert "resume is distinguished from a new session"
  (session-resumed? resumed))
(test-equal "session identity survives restart"
  (session-id state)
  (session-id resumed))
(test-equal "conversation history survives restart"
  "hi"
  (json-object-ref (cadr (session-history resumed)) "content"))
(test-equal "turn number survives restart" 2 (session-next-turn resumed))
(test-equal "generation number survives restart" 2 (session-generation-id resumed))
(test-equal "live patches survive restart"
  '("(set! agent-system-prompt \"remembered\")")
  (session-patches resumed))

(define restored-runtime
  (make-runtime source-path (session-directory resumed)
                (session-patches resumed) (session-generation-id resumed)
                (session-fingerprint resumed)))

(test-equal "restored patch is rebuilt into the live image"
  "remembered"
  (generation-ref (runtime-current restored-runtime) 'agent-system-prompt))
(test-equal "named session is discoverable"
  '("dogfood")
  (list-session-names test-root))
(test-error "one durable session cannot have two live owners"
  #t
  (open-session! test-root "dogfood" 'resume))

(call-with-output-file source-path
  (lambda (port)
    (display
     (string-append fixture-source "\n(define extension-source-version 2)\n")
     port)))
(define source-changed-runtime
  (make-runtime source-path (session-directory resumed)
                (session-patches resumed) (session-generation-id resumed)
                (session-fingerprint resumed)))
(test-equal "source changes while stopped advance the generation"
  3
  (generation-id (runtime-current source-changed-runtime)))
(test-error "new refuses to overwrite an existing session"
  #t
  (open-session! test-root "dogfood" 'new))
(test-error "resume requires an existing checkpoint"
  #t
  (open-session! test-root "missing" 'resume))
(test-error "session names cannot traverse directories"
  #t
  (open-session! test-root "../escape" 'auto))

(close-session! resumed)

(call-with-output-file
    (string-append (session-directory state) "/authority.json")
  (lambda (port)
    (display "{\"version\":1,\"tool_ceiling\":[\"read\"]}\n" port)))

(define forked-checkpoint
  (fork-session! test-root "dogfood" "dogfood-child"))

(test-equal "session fork preserves the checkpoint turn"
  2
  (json-object-ref forked-checkpoint "next_turn"))
(test-equal "session fork pins the parent generation fingerprint"
  (json-object-ref forked-checkpoint "fingerprint")
  (json-object-ref
   (json-object-ref forked-checkpoint "fork") "fingerprint"))
(test-equal "session fork snapshots the parent tool list"
  '("read")
  (json-array-items (json-object-ref forked-checkpoint "tools")))

(define forked (open-session! test-root "dogfood-child" 'resume))

(test-assert "session fork receives a distinct durable identity"
  (not (string=? (session-id state) (session-id forked))))
(test-equal "session fork inherits bounded conversation history"
  "hi"
  (json-object-ref (cadr (session-history forked)) "content"))
(test-equal "session fork preserves the durable authority ceiling"
  "read"
  (car
   (json-array-items
    (json-object-ref
     (json-read
      (read-source-file
       (string-append (session-directory forked) "/authority.json")))
     "tool_ceiling"))))

(close-session! forked)
(test-error "session fork refuses to overwrite a child"
  #t
  (fork-session! test-root "dogfood" "dogfood-child"))

(define held (open-session! test-root "dogfood" 'resume))
(define (summary name)
  (find (lambda (item) (equal? (json-object-ref item "name") name))
        (session-summaries test-root "dogfood-child")))
(test-equal "session summaries mark the current session" "current"
  (json-object-ref (summary "dogfood-child") "status"))
(test-equal "session summaries detect a session held by another owner" "running"
  (json-object-ref (summary "dogfood") "status"))
(test-assert "session summaries carry turn counts and checkpoint times"
  (and (number? (json-object-ref (summary "dogfood") "turns"))
       (string? (json-object-ref (summary "dogfood") "updated"))))
(close-session! held)
(test-equal "session summaries show released sessions as idle" "idle"
  (json-object-ref (summary "dogfood") "status"))

(define nested-checkpoint
  (fork-session! test-root "dogfood" "dogfood/agents/tests" #f))
(test-equal "a subagent fork starts with an empty conversation" 1
  (json-object-ref nested-checkpoint "next_turn"))
(test-equal "a subagent fork keeps the parent generation"
  (json-object-ref forked-checkpoint "generation_id")
  (json-object-ref nested-checkpoint "generation_id"))
(fork-session! test-root "dogfood/agents/tests" "dogfood/agents/tests/agents/retry")
(test-equal "session listing nests subagent folders after their parent"
  '("dogfood" "dogfood/agents/tests" "dogfood/agents/tests/agents/retry" "dogfood-child")
  (list-session-names test-root))
(test-assert "session paths only descend through agents folders"
  (and (safe-session-path? "dogfood/agents/tests")
       (not (safe-session-path? "dogfood/tests"))
       (not (safe-session-path? "dogfood/agents"))))
(define nested (open-session! test-root "dogfood/agents/tests" 'resume))
(test-equal "nested sessions open by path" "dogfood/agents/tests" (session-name nested))
(test-equal "nested sessions record their parent" "dogfood"
  (json-object-ref (session-fork nested) "parent_name"))
(close-session! nested)


;; Resuming by id. The exit line and every receipt print a session's id, so
;; pasting one back is the obvious thing to try.
(let ((root (string-append "/tmp/shift-session-ids-" (number->string (getpid)))))
  (system* "mkdir" "-p" root)
  (let* ((one (open-session! root "alpha" 'new))
         (id (session-id one)))
    ;; The id lives in the checkpoint, so a session only becomes findable by it
    ;; once one has been written — which is true of resuming by name as well.
    (save-session! one (make-runtime source-path (session-directory one)
                                     (session-patches one) (session-generation-id one))
                   '() 1)
    (close-session! one)
    (test-assert "a fresh id looks like one" (session-id-like? id))
    (test-equal "an id resolves to its session's name" "alpha"
      (resolve-session-reference root id))
    (test-equal "a name resolves to itself" "alpha"
      (resolve-session-reference root "alpha"))
    ;; Only the shape is special-cased, so an ordinary miss never reads every
    ;; checkpoint under the root.
    (test-equal "a name that does not exist is left alone" "nosuch"
      (resolve-session-reference root "nosuch"))
    (test-equal "an id nothing matches is left alone to fail as a name"
      "00000000000000000000000000000000"
      (resolve-session-reference root "00000000000000000000000000000000"))
    (test-assert "a resume by id opens the session"
      (let ((again (open-session! root (resolve-session-reference root id) 'resume)))
        (let ((ok (and (string=? (session-name again) "alpha")
                       (string=? (session-id again) id))))
          (close-session! again)
          ok)))
    ;; A session named like an id wins over another session carrying it, so an
    ;; id can never shadow a name somebody chose.
    (let ((named (open-session! root id 'new)))
      (save-session! named (make-runtime source-path (session-directory named)
                                         (session-patches named) (session-generation-id named))
                     '() 1)
      (close-session! named)
      (test-equal "an existing name wins over a matching id" id
        (resolve-session-reference root id)))))

(test-end "durable session")
