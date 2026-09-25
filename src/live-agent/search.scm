;; One word ranking, used for every catalog a turn can search: MCP tools, a
;; plugin's declared tools, and skills. They are all name-plus-description
;; lists, and having one heuristic means a query that finds a tool finds the
;; skill that explains it.
(define-module (live-agent search)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-14)
  #:export (search-tokens search-ranked))

(define (search-tokens text)
  (filter (lambda (w) (>= (string-length w) 3))
          (string-tokenize (string-downcase text) char-set:letter+digit)))
(define (search-ranked query tools description)
  (let ((needle (string-downcase query)) (words (search-tokens query)))
    (if (string-null? needle) tools
        (let* ((scored
                (filter-map
                 (lambda (t)
                   (let* ((full (string-downcase (car t)))
                          (server (let ((at (string-contains full "__"))) (if at (substring full 0 at) "")))
                          (bare (let ((at (string-contains full "__"))) (if at (substring full (+ at 2)) full)))
                          (text (string-downcase (description t)))
                          (score (+ (if (or (string-contains full needle) (string-contains text needle)) 2 0)
                                    (apply + (map (lambda (w)
                                                    (+ (if (string=? w server) 3 0)
                                                       (if (string-contains bare w) 2 0)
                                                       (if (string-contains text w) 1 0)))
                                                  words)))))
                     (and (> score 0) (cons score t))))
                 tools)))
          (map cdr (sort scored (lambda (a b) (> (car a) (car b)))))))))

