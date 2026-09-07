(define-module (live-agent policy)
  #:use-module (live-agent json)
  #:export (tool-decision))
;; No live-image binding can override this decision. Auto remains conservative
;; until an approval model has passed held-out evaluation; it does not guess.
(define (tool-decision mode name arguments)
  (let ((read-only? (or (member name '("read" "rg" "traces" "status" "diff"))
                        (and (string=? name "extension")
                             (equal? (json-object-ref arguments "action" #f) "list")))))
    (case mode
      ((manual) 'ask)
      ((plan) (if read-only? 'allow 'deny))
      ((accept) (if (or read-only? (member name '("write" "edit" "apply_patch"))) 'allow 'ask))
      ((auto) (if read-only? 'allow 'ask))
      (else 'deny))))
