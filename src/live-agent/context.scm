(define-module (live-agent context)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent tools)
  #:export (estimate-input-tokens context-over-budget?))
;; Deliberately labeled heuristic, not a tokenizer count. Includes tool schemas
;; and JSON framing. Keep a 20% margin and reserve output separately.
(define (estimate-input-tokens messages tools)
  (ceiling (/ (bytevector-length (string->utf8
    (json-write (json-object (cons "messages" (apply json-array messages))
                            (cons "tools" (apply json-array (map tool-schema tools))))))) 3)))
(define (context-over-budget? tokens limit reserve)
  (and limit (> (+ tokens reserve) (* limit 0.8))))
