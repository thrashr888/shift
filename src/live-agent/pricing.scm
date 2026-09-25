;; Price-weighted cost for a turn. Raw token counts mislead: on published
;; Anthropic multiples a cached input token bills at a tenth of an uncached one
;; and an output token at five times it, so a change that trades output for
;; prompt can read as a saving and cost more. Cost per completed task, not
;; tokens per request, is the number a harness change has to move.
;;
;; Rates are not built in. Providers change prices without warning, and a rate
;; compiled into the harness would go stale silently and quietly falsify every
;; comparison drawn from it. The `token-prices` setting is the only source of
;; rates, in dollars per million tokens. A model with no row is unpriced, never
;; priced at zero: a turn that reports no cost is honest, while one that
;; reports $0 sums into a session total as though it were free.
;;
;; The single exception is local inference, which bills nothing. That is a fact
;; about the provider rather than a price that can go out of date.
(define-module (live-agent pricing)
  #:use-module (srfi srfi-1)
  #:export (listed-prices configured-prices model-price token-cost price-row))

;; Rows of (PROVIDER MODEL-PREFIX input cache-read cache-write output). The
;; longest matching prefix within the provider wins, so a family row covers its
;; dated releases until a more specific row overrides it.
(define listed-prices
  '((ollama "" 0 0 0 0)))

;; User rows, as the `token-prices` setting supplies them. Held here rather
;; than read from settings directly so this module stays data-only and the
;; caller decides when preferences are loaded.
(define configured-prices (make-parameter '()))

(define (row-provider row) (car row))
(define (row-prefix row) (cadr row))

;; Longest prefix match within the provider. Configured rows are searched
;; first so a user row of equal length still wins.
(define (find-row rows provider model)
  (let ((matches
         (filter (lambda (row)
                   (and (eq? (row-provider row) provider)
                        (string-prefix? (row-prefix row) model)))
                 rows)))
    (if (null? matches)
        #f
        (fold (lambda (row best)
                (if (> (string-length (row-prefix row))
                       (string-length (row-prefix best)))
                    row
                    best))
              (car matches)
              matches))))

;; Returns (rates . source) or #f, where rates is (input read write output).
;; The source is 'configured for a user row and 'listed for the built-in
;; local-inference row, so a cost is never anonymous about where it came from.
(define (price-row provider model)
  (let ((provider (if (symbol? provider) provider (string->symbol (or provider ""))))
        (model (or model "")))
    (cond
     ((find-row (configured-prices) provider model)
      => (lambda (row) (cons (cddr row) 'configured)))
     ((find-row listed-prices provider model)
      => (lambda (row) (cons (cddr row) 'listed)))
     (else #f))))

(define (model-price provider model)
  (let ((row (price-row provider model)))
    (and row (car row))))

;; `usage` is the receipt's token alist: uncached, cached, cache_write and
;; completion. Returns (cost . source) in dollars, or #f when the model is
;; unpriced. Cost stays exact here; formatting rounds at the edge.
(define (token-cost provider model usage)
  (let ((row (price-row provider model)))
    (and row
         (let* ((rates (car row))
                (count (lambda (key) (let ((value (assq-ref usage key)))
                                       (if (number? value) value 0))))
                (rate (lambda (index) (list-ref rates index))))
           (cons (/ (+ (* (count 'uncached) (rate 0))
                       (* (count 'cached) (rate 1))
                       (* (count 'cache_write) (rate 2))
                       (* (count 'completion) (rate 3)))
                    1000000)
                 (cdr row))))))
