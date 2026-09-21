;; TypeSafe's System One API: a state and a map of typed questions in, typed
;; answers with calibrated probabilities out. Jev generates no text, so there
;; is nothing to parse; every answer is validated against its question before
;; any is returned. Process-owned; the live image cannot change it.
(define-module (live-agent typesafe)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:export (typesafe-model typesafe-api-key typesafe-key-file typesafe-transport
            noul choice typesafe-ask typesafe-validate typesafe-failure-permanent?))

;; Every failure is thrown as (typesafe-error CLASS STATUS DETAIL) so a caller
;; can tell a dead key or an empty balance, which will not heal by retrying,
;; from an overloaded service, which might.
;;   no-key auth credits request  permanent for the session
;;   transient network malformed  this call only
(define (fail class status detail) (throw 'typesafe-error class status detail))
(define (typesafe-failure-permanent? class) (and (memq class '(no-key auth credits request)) #t))
(define (status-class status)
  (cond ((eqv? status 401) 'auth)
        ((memv status '(402 403)) 'credits)   ; TypeSafe's docs list neither; a balance or plan refusal lands here
        ((eqv? status 422) 'request)
        (else 'transient)))

;; Pinned: jev-latest moves, and thresholds tuned against one version should
;; not drift with it. The response's own model field is logged beside it.
(define typesafe-model "jev-1.13.0")

;; --- credentials ----------------------------------------------------------------
;; The environment first, then the file clue and Alchemy share. Never settings.
(define typesafe-key-file
  (make-parameter (string-append (or (getenv "HOME") "") "/.config/typesafe/api-key")))
(define (typesafe-api-key from-environment)
  (cond
   ((and (string? from-environment) (not (string-null? from-environment))) from-environment)
   ((file-exists? (typesafe-key-file))
    (let ((text (string-trim-both (call-with-input-file (typesafe-key-file) get-string-all))))
      (and (not (string-null? text)) text)))
   (else #f)))

;; --- questions ------------------------------------------------------------------
(define (noul instructions)
  (json-object (cons "type" "noul") (cons "instructions" instructions)
               (cons "criteria" (json-object (cons "true" "This condition holds.") (cons "false" "It does not.")))))
;; criteria: ((option . description) ...)
(define (choice instructions criteria)
  (json-object (cons "type" "choice") (cons "instructions" instructions)
               (cons "criteria" (apply json-object criteria))))

;; --- transport ------------------------------------------------------------------
;; (transport base-url api-key body-text timeout) → (values http-status body-text).
;; A parameter so tests answer without a network; the default is one curl.
(define (temporary name)
  (let* ((port (mkstemp (string-append "/tmp/shift-typesafe-" name "-XXXXXX"))) (path (port-filename port)))
    (close-port port) path))
(define (curl-transport base-url api-key body timeout)
  (let ((payload (temporary "payload")) (out (temporary "body")) (headers (temporary "headers")))
    (call-with-output-file payload (lambda (p) (display body p)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let* ((status (system* "curl" "-sS" "-m" (number->string timeout) "-o" out "-D" headers
                                "-H" "Content-Type: application/json"
                                "-H" (string-append "Authorization: Bearer " api-key)
                                "--data-binary" (string-append "@" payload)
                                (string-append base-url "/systemone")))
               (code (status:exit-val status)))
          (unless (eqv? code 0) (fail 'network 0 (format #f "curl exited ~a" code)))
          (let* ((first (let ((lines (string-split (call-with-input-file headers get-string-all) #\newline)))
                          (and (pair? lines) (string-tokenize (car lines)))))
                 (http-status (and first (>= (length first) 2) (string->number (cadr first)))))
            (values (or http-status 0) (call-with-input-file out get-string-all)))))
      (lambda () (for-each (lambda (f) (when (file-exists? f) (delete-file f))) (list payload out headers))))))
(define typesafe-transport (make-parameter curl-transport))

;; --- the request ----------------------------------------------------------------
;; questions: ((id . question-json) ...). Returns the answers object; raises on
;; transport failure, a non-2xx status, or an answer that fails validation.
;; One retry on 429 and 529, which the API documents as backoff cases.
(define* (typesafe-ask base-url api-key state questions #:key (timeout 10) (model typesafe-model))
  (unless (and (string? api-key) (not (string-null? api-key)))
    (fail 'no-key 0 "no TypeSafe API key in TYPESAFE_API_KEY or ~/.config/typesafe/api-key"))
  (let ((body (json-write (json-object (cons "model" model) (cons "state" state)
                                       (cons "questions" (apply json-object questions))))))
    (let attempt ((tries 0))
      (call-with-values (lambda () ((typesafe-transport) base-url api-key body timeout))
        (lambda (status text)
          (cond
           ((and (memv status '(429 529)) (< tries 1)) (usleep 500000) (attempt (+ tries 1)))
           ((not (and (>= status 200) (< status 300)))
            (fail (status-class status) status
                  (format #f "HTTP ~a: ~a" status
                          (let ((t (string-trim-both text))) (if (> (string-length t) 200) (substring t 0 200) t)))))
           (else
            (let ((reply (catch #t (lambda () (json-read text)) (lambda _ #f))))
              (unless (json-object? reply) (fail 'malformed status "the reply was not a JSON object"))
              (let ((answers (json-object-ref reply "answers" #f)))
                (typesafe-validate questions answers)
                ;; The model the service actually used rides along for the log.
                (json-object (cons "answers" answers)
                             (cons "model" (json-object-ref reply "model" model))
                             (cons "usage" (json-object-ref reply "usage" (json-object)))))))))))))

;; --- validation -----------------------------------------------------------------
(define (probability? x) (and (real? x) (>= x 0) (<= x 1)))
(define (validate-one id question answer)
  (define (fail why) (throw 'typesafe-error 'malformed 200 (format #f "answer ~a: ~a" id why)))
  (unless (json-object? answer) (fail "missing"))
  (let ((type (json-object-ref question "type" "")))
    (unless (equal? (json-object-ref answer "type" type) type) (fail "type does not match the question"))
    (cond
     ((equal? type "noul")
      (unless (probability? (json-object-ref answer "noul" #f)) (fail "noul is not a probability")))
     ((equal? type "choice")
      (let* ((options (map car (json-object-entries (json-object-ref question "criteria" (json-object)))))
             (chosen (json-object-ref answer "choice" #f))
             (probabilities (json-object-ref answer "probabilities" #f)))
        (unless (member chosen options) (fail "choice is not one of the criteria"))
        (unless (json-object? probabilities) (fail "no probabilities"))
        (let ((entries (json-object-entries probabilities)))
          (unless (and (every (lambda (e) (and (member (car e) options) (probability? (cdr e)))) entries)
                       (< (abs (- 1 (apply + (map cdr entries)))) 0.02))
            (fail "probabilities do not sum to one over the criteria")))
        (unless (probability? (json-object-ref answer "confidence" #f)) (fail "confidence is not a probability"))))
     ((equal? type "score")
      (unless (real? (json-object-ref answer "score" #f)) (fail "no score")))
     (else (fail "unknown question type")))))
(define (typesafe-validate questions answers)
  (unless (json-object? answers) (throw 'typesafe-error 'malformed 200 "the reply had no answers"))
  (for-each (lambda (q) (validate-one (car q) (cdr q) (json-object-ref answers (car q) #f))) questions)
  #t)
