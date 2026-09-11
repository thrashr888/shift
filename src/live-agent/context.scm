(define-module (live-agent context)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent tools)
  #:export (estimate-input-tokens calibrate-input-estimate context-over-budget?))
;; Deliberately labeled heuristic, not a tokenizer count. Includes tool schemas
;; and JSON framing. Keep a 20% margin and reserve output separately.
(define (estimate-input-tokens messages tools)
  (ceiling (/ (bytevector-length (string->utf8
    (json-write (json-object (cons "messages" (apply json-array messages))
                            (cons "tools" (apply json-array (map tool-schema tools))))))) 3)))
;; Pair the provider's full prompt count with the raw estimate for that same
;; request. Never divide by an already calibrated estimate: doing so compounds
;; the correction across rounds. Without a valid reference, keep the heuristic.
(define (calibrate-input-estimate estimate previous-estimate previous-prompt)
  (if (and (integer? previous-estimate) (> previous-estimate 0)
           (integer? previous-prompt) (> previous-prompt 0))
      (ceiling (* estimate (/ previous-prompt previous-estimate)))
      estimate))
(define (context-over-budget? tokens limit reserve)
  (and limit (> (+ tokens reserve) (* limit 0.8))))
