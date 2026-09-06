(use-modules (srfi srfi-64) (live-agent generation) (live-agent runtime))
(test-begin "context repair")
(define root (string-append "/tmp/shift-context-test-" (number->string (getpid))))
(define runtime (make-runtime "demo/context-selection/agent.scm" root))
(define before (generation-fingerprint (runtime-current runtime)))
(test-error "port-only repair fails the deployment cases"
  #t
  (runtime-eval! runtime
    "(define (agent-select-context text) (if (string-contains? (string-downcase text) \"port\") '(\"demo/context-selection/context/current-runbook.md\") '()))"))
(test-equal "failed behavior check never activates" before
  (generation-fingerprint (runtime-current runtime)))
(runtime-eval! runtime
  "(define (agent-select-context text) (let ((query (string-downcase text))) (if (or (string-contains? query \"port\") (string-contains? query \"deploy\")) '(\"demo/context-selection/context/current-runbook.md\") '())))")
(for-each
 (lambda (entry)
   (test-equal (car entry) (cadr entry)
     (generation-call (runtime-current runtime) 'agent-select-context (car entry))))
 (generation-ref (runtime-current runtime) 'agent-context-cases))
(runtime-rollback! runtime)
(test-equal "rollback restores the intentional baseline" before
  (generation-fingerprint (runtime-current runtime)))
(test-end "context repair")
