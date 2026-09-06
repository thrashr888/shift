;; Run one SRFI-64 suite and propagate assertion failures to make/CI.
(use-modules (srfi srfi-64))
(define runner (test-runner-simple))
(test-runner-factory (lambda () runner))
(primitive-load (cadr (command-line)))
(exit (if (and (= 0 (test-runner-fail-count runner))
               (= 0 (test-runner-xpass-count runner))) 0 1))
