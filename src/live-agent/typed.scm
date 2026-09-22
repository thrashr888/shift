;; Typed judgments beyond the judge: rank tool_search candidates and suggest
;; a skill for a turn. Both build a state and questions for Jev and turn the
;; answers into a decision code can act on; neither is on unless the judge
;; is typesafe (docs/jev-rfc.md phases 3 and 4).
(define-module (live-agent typed)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent typesafe)
  #:export (rank-threshold rank-state rank-questions rank-from-answers typed-rank-tools
            skill-hint-state skill-hint-questions skill-hint-from-answers typed-skill-hint skill-hint-line))

;; --- tool_search --------------------------------------------------------------------
;; A tool stays when the model is at least this sure it does what the query asks.
(define rank-threshold 0.5)
(define rank-candidates 24)
;; tools: ((name . description) ...)
(define (rank-state query tools)
  (json-object (cons "query" query)
               (cons "tools" (apply json-array (map (lambda (t) (json-object (cons "name" (car t)) (cons "description" (cdr t)))) tools)))))
(define (rank-questions tools)
  (map (lambda (t)
         (cons (car t)
               (noul (format #f "Does the tool named `~a` in `tools` do what `query` asks for? Judge by its name and description only; a tool that could be used along the way but does not do the asked thing does not count." (car t)))))
       tools))
;; answers → names in probability order, only those at or above the threshold.
(define (rank-from-answers answers names)
  (let ((scored (filter-map (lambda (name)
                              (let ((p (json-object-ref (json-object-ref answers name (json-object)) "noul" 0)))
                                (and (>= p rank-threshold) (cons name p))))
                            names)))
    (map car (sort scored (lambda (a b) (> (cdr a) (cdr b)))))))
;; candidates: ((name . description) ...) in the lexical order; returns the
;; typed order, or the candidates unchanged when nothing clears the threshold.
(define (typed-rank-tools base-url api-key query candidates)
  (let* ((tools (if (> (length candidates) rank-candidates) (take candidates rank-candidates) candidates))
         (reply (typesafe-ask base-url api-key (rank-state query tools) (rank-questions tools)))
         (kept (rank-from-answers (json-object-ref reply "answers" (json-object)) (map car tools))))
    (if (null? kept) (map car candidates) kept)))

;; --- skills -------------------------------------------------------------------------
;; skills: ((name . description) ...)
(define (skill-hint-state request skills)
  (json-object (cons "request" request)
               (cons "skills" (apply json-array (map (lambda (s) (json-object (cons "name" (car s)) (cons "description" (cdr s)))) skills)))))
(define (skill-hint-questions skills)
  (list
   (cons "skill"
         (choice "Which of `skills` is the documented procedure for what `request` asks the assistant to do? Pick `none` when no skill is about this request, when the request is a question a knowledgeable generalist answers in prose, or when a skill merely touches the same subject."
                 (append (map (lambda (s) (cons (car s) (cdr s))) skills)
                         '(("none" . "No listed skill is the procedure for this request.")))))
   (cons "procedure"
         (noul "Would a careful expert handling `request` follow a specific documented procedure, rather than answer from general knowledge or read the code and act?"))))
;; The skill name when the choice is confident and a procedure is wanted at all; else #f.
(define (skill-hint-from-answers answers)
  (let* ((skill (json-object-ref answers "skill" (json-object)))
         (name (json-object-ref skill "choice" "none"))
         (confidence (json-object-ref skill "confidence" 0))
         (procedure (json-object-ref (json-object-ref answers "procedure" (json-object)) "noul" 0)))
    (and (not (equal? name "none")) (>= confidence 0.5) (>= procedure 0.5) name)))
(define (typed-skill-hint base-url api-key request skills)
  (let ((reply (typesafe-ask base-url api-key (skill-hint-state request skills) (skill-hint-questions skills))))
    (skill-hint-from-answers (json-object-ref reply "answers" (json-object)))))
(define (skill-hint-line name)
  (string-append "\n\n<skill_relevance>Relevant to this request: " name ". Load it with the skill tool if it fits; ignore this if it does not.</skill_relevance>"))
