(define (check g)
  (let ((tools (generation-ref g 'agent-tools)))
    (and (memq 'rg tools) (memq 'read tools) (memq 'edit tools) (memq 'live_eval tools) #t)))
