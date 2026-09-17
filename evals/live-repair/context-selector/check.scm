(define (check g)
  (let ((select (generation-ref g 'agent-select-context)))
    (and (equal? '("docs/runbook.md") (select "what does the runbook say about ports?"))
         (null? (select "hello there")))))
