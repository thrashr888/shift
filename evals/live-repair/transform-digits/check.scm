(define (check g)
  (let ((transform (generation-ref g 'agent-transform-user)))
    (and (equal? "port 8080" (transform "port 8080")) (equal? "v2.1 ok" (transform "v2.1 ok")))))
