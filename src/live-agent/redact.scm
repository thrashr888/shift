;; Secrets the process has seen never reach a tool result, a trace, a run
;; log or a receipt: values from .env and `op read` are registered here and
;; replaced by [redacted NAME] wherever text is written. The trace-content
;; setting decides how much prompt and output text traces keep at all.
(define-module (live-agent redact)
  #:use-module (srfi srfi-1)
  #:export (register-secret! forget-secrets! secret-count redact trace-content))

(define secrets '()) ; (value . name), longest first so nested values redact whole
(define minimum-secret-length 6)

(define (register-secret! name value)
  (when (and (string? value) (>= (string-length value) minimum-secret-length)
             (not (assoc value secrets)))
    (set! secrets (sort (cons (cons value name) secrets)
                        (lambda (a b) (> (string-length (car a)) (string-length (car b))))))))
(define (forget-secrets!) (set! secrets '()))
(define (secret-count) (length secrets))

(define (replace-all text needle replacement)
  (let loop ((start 0) (parts '()))
    (let ((at (string-contains text needle start)))
      (if at
          (loop (+ at (string-length needle)) (cons replacement (cons (substring text start at) parts)))
          (string-concatenate (reverse (cons (substring text start) parts)))))))

(define (redact text)
  (if (or (not (string? text)) (null? secrets))
      text
      (fold (lambda (secret out) (replace-all out (car secret) (string-append "[redacted " (cdr secret) "]")))
            text secrets)))

;; full: every attribute as recorded; bounded: content clipped to 200 chars;
;; off: content attributes dropped, names and timings kept.
(define trace-content (make-parameter 'full))
