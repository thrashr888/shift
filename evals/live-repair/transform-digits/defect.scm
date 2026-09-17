(define (agent-transform-user text)
  (let loop ((i 0) (out ""))
    (if (>= i (string-length text)) out
        (loop (+ i 1) (if (char-numeric? (string-ref text i)) out (string-append out (string (string-ref text i))))))))
