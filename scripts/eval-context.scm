;; Usage: guile --no-auto-compile -L src -L extensions scripts/eval-context.scm SESSION_JSON
;; Evaluate the captured model patch against cases owned by the base demo image.
(use-modules (ice-9 textual-ports) (ice-9 format)
             (live-agent generation) (live-agent json))
(define source "demo/context-selection/agent.scm")
(define baseline (build-generation 1 source (read-source-file source) '()))
(define cases (generation-ref baseline 'agent-context-cases))
(define checkpoint
  (call-with-input-file (cadr (command-line))
    (lambda (port) (json-read (get-string-all port)))))
(define candidate
  (build-generation (json-object-ref checkpoint "generation_id")
                    source (read-source-file source)
                    (json-array-items (json-object-ref checkpoint "patches"))))
(define passed 0)
(define baseline-passed 0)
(for-each
 (lambda (entry)
   (let* ((query (car entry)) (expected (cadr entry))
          (old (generation-call baseline 'agent-select-context query))
          (actual (generation-call candidate 'agent-select-context query))
          (ok? (equal? expected actual)))
     (when (equal? expected old) (set! baseline-passed (+ baseline-passed 1)))
     (when ok? (set! passed (+ passed 1)))
     (format #t "~a ~s -> ~s~%" (if ok? "PASS" "FAIL") query actual)))
 cases)
(format #t "baseline ~a/~a; captured candidate ~a/~a; generation ~a; fingerprint ~a~%"
        baseline-passed (length cases) passed (length cases)
        (generation-id candidate) (generation-fingerprint candidate))
(exit (if (= passed (length cases)) 0 1))
