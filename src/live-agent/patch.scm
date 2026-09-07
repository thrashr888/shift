;; Unified diff parsing and application, pure and in-process. Hunks must match
;; their context exactly; the applier searches outward from the stated line
;; but never applies with partial context. Anything malformed rejects the
;; whole patch before a single file is touched.
(define-module (live-agent patch)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (parse-patch
            file-patch?
            file-patch-old-path
            file-patch-new-path
            file-patch-hunks
            apply-file-patch))

(define-record-type <file-patch>
  (make-file-patch old-path new-path hunks)
  file-patch?
  (old-path file-patch-old-path)
  (new-path file-patch-new-path)
  (hunks file-patch-hunks))

;; lines is a list of (kind . text) with kind #\space, #\- or #\+.
(define-record-type <hunk>
  (make-hunk old-start old-count new-start new-count lines
             old-no-newline? new-no-newline?)
  hunk?
  (old-start hunk-old-start)
  (old-count hunk-old-count)
  (new-start hunk-new-start)
  (new-count hunk-new-count)
  (lines hunk-lines)
  (old-no-newline? hunk-old-no-newline?)
  (new-no-newline? hunk-new-no-newline?))

(define (strip-header-path value)
  (let* ((tab (string-index value #\tab))
         (path (string-trim-both (if tab (substring value 0 tab) value))))
    (cond
     ((string=? path "/dev/null") #f)
     ((or (string-prefix? "a/" path) (string-prefix? "b/" path)) (substring path 2))
     ((string-null? path) (error "patch header has an empty path"))
     (else path))))

(define (parse-range text sign)
  (unless (and (> (string-length text) 1) (char=? (string-ref text 0) sign))
    (error "malformed hunk range" text))
  (let* ((body (substring text 1))
         (comma (string-index body #\,))
         (start (string->number (if comma (substring body 0 comma) body)))
         (count (if comma (string->number (substring body (+ comma 1))) 1)))
    (unless (and (integer? start) (>= start 0) (integer? count) (>= count 0))
      (error "malformed hunk range" text))
    (cons start count)))

(define (parse-hunk-header line)
  (let ((parts (string-tokenize line)))
    (unless (and (>= (length parts) 3)
                 (string=? (car parts) "@@")
                 (or (< (length parts) 4) (string=? (cadddr parts) "@@")))
      (error "malformed hunk header" line))
    (cons (parse-range (cadr parts) #\-) (parse-range (caddr parts) #\+))))

;; Consumes hunk body lines until both counts are satisfied.
(define (parse-hunk header lines)
  (let* ((ranges (parse-hunk-header header))
         (old-start (caar ranges)) (old-count (cdar ranges))
         (new-start (cadr ranges)) (new-count (cddr ranges)))
    (let loop ((rest lines) (body '()) (old-left old-count) (new-left new-count)
               (last-kind #f) (old-no-newline? #f) (new-no-newline? #f))
      (cond
       ((and (= old-left 0) (= new-left 0))
        (if (and (pair? rest) (string-prefix? "\\" (car rest)))
            (loop (cdr rest) body 0 0 last-kind
                  (or old-no-newline? (memv last-kind '(#\space #\-)))
                  (or new-no-newline? (memv last-kind '(#\space #\+))))
            (values (make-hunk old-start old-count new-start new-count (reverse body)
                               (if old-no-newline? #t #f) (if new-no-newline? #t #f))
                    rest)))
       ((null? rest) (error "hunk ends before its declared line counts" header))
       (else
        (let* ((line (car rest))
               (kind (if (string-null? line) #\space (string-ref line 0)))
               (text (if (string-null? line) "" (substring line 1))))
          (case kind
            ((#\space)
             (when (or (= old-left 0) (= new-left 0))
               (error "hunk has more lines than its header declares" header))
             (loop (cdr rest) (cons (cons #\space text) body)
                   (- old-left 1) (- new-left 1) #\space old-no-newline? new-no-newline?))
            ((#\-)
             (when (= old-left 0) (error "hunk has more lines than its header declares" header))
             (loop (cdr rest) (cons (cons #\- text) body)
                   (- old-left 1) new-left #\- old-no-newline? new-no-newline?))
            ((#\+)
             (when (= new-left 0) (error "hunk has more lines than its header declares" header))
             (loop (cdr rest) (cons (cons #\+ text) body)
                   old-left (- new-left 1) #\+ old-no-newline? new-no-newline?))
            ((#\\)
             (loop (cdr rest) body old-left new-left last-kind
                   (or old-no-newline? (memv last-kind '(#\space #\-)))
                   (or new-no-newline? (memv last-kind '(#\space #\+)))))
            (else (error "unexpected line inside hunk" line)))))))))

(define (parse-hunks lines)
  (let loop ((rest lines) (hunks '()))
    (cond
     ((or (null? rest)
          (string-prefix? "--- " (car rest))
          (string-prefix? "diff " (car rest)))
      (values (reverse hunks) rest))
     ((string-prefix? "@@" (car rest))
      (call-with-values
          (lambda () (parse-hunk (car rest) (cdr rest)))
        (lambda (hunk remaining) (loop remaining (cons hunk hunks)))))
     ((string-null? (string-trim-both (car rest))) (loop (cdr rest) hunks))
     (else (error "expected a hunk header" (car rest))))))

(define (parse-patch text)
  (let loop ((rest (string-split text #\newline)) (files '()))
    (cond
     ((null? rest)
      (when (null? files) (error "patch contains no file sections"))
      (reverse files))
     ((string-prefix? "--- " (car rest))
      (unless (and (pair? (cdr rest)) (string-prefix? "+++ " (cadr rest)))
        (error "file header is missing its +++ line" (car rest)))
      (let ((old-path (strip-header-path (substring (car rest) 4)))
            (new-path (strip-header-path (substring (cadr rest) 4))))
        (when (and (not old-path) (not new-path))
          (error "file section has no path"))
        (call-with-values
            (lambda () (parse-hunks (cddr rest)))
          (lambda (hunks remaining)
            (when (null? hunks) (error "file section has no hunks" (or old-path new-path)))
            (loop remaining (cons (make-file-patch old-path new-path hunks) files))))))
     ;; git headers, index lines, mode lines, and blank lines are skipped.
     (else (loop (cdr rest) files)))))

(define (split-lines text)
  (cond
   ((or (not text) (string-null? text)) (values '() #t))
   ((string-suffix? "\n" text)
    (values (string-split (substring text 0 (- (string-length text) 1)) #\newline) #t))
   (else (values (string-split text #\newline) #f))))

(define (join-lines lines trailing?)
  (if (null? lines)
      ""
      (string-append (string-join lines "\n") (if trailing? "\n" ""))))

(define (hunk-side hunk keep)
  (filter-map (lambda (entry) (and (memv (car entry) keep) (cdr entry)))
              (hunk-lines hunk)))

(define (matches-at? lines position expected)
  (let loop ((rest (drop lines position)) (expected expected))
    (cond
     ((null? expected) #t)
     ((null? rest) #f)
     ((string=? (car rest) (car expected)) (loop (cdr rest) (cdr expected)))
     (else #f))))

;; Nearest exact match to the expected position, searching outward.
(define (locate lines expected position)
  (let ((limit (- (length lines) (length expected))))
    (let loop ((delta 0))
      (let ((forward (+ position delta)) (backward (- position delta)))
        (cond
         ((and (> forward limit) (< backward 0)) #f)
         ((and (<= forward limit) (>= forward 0) (matches-at? lines forward expected)) forward)
         ((and (> delta 0) (>= backward 0) (<= backward limit) (matches-at? lines backward expected)) backward)
         (else (loop (+ delta 1))))))))

(define (first-mismatch lines position expected)
  (let loop ((index 0) (rest (drop lines (min position (length lines)))) (expected expected))
    (cond
     ((null? expected) #f)
     ((null? rest) (cons (+ position index 1) (cons (car expected) "end of file")))
     ((string=? (car rest) (car expected)) (loop (+ index 1) (cdr rest) (cdr expected)))
     (else (cons (+ position index 1) (cons (car expected) (car rest)))))))

(define (apply-file-patch old-text file-patch)
  (call-with-values
      (lambda () (split-lines old-text))
    (lambda (original trailing?)
      (let loop ((hunks (file-patch-hunks file-patch)) (lines original) (offset 0)
                 (index 1) (trailing? trailing?))
        (if (null? hunks)
            (join-lines lines trailing?)
            (let* ((hunk (car hunks))
                   (old-side (hunk-side hunk '(#\space #\-)))
                   (new-side (hunk-side hunk '(#\space #\+)))
                   (expected (max 0 (+ (- (hunk-old-start hunk) 1) offset)))
                   (expected (min expected (length lines)))
                   (position (locate lines old-side expected)))
              (unless position
                (let ((mismatch (first-mismatch lines expected old-side)))
                  (error (format #f "hunk ~a does not match ~a at line ~a: expected ~s, found ~s"
                                 index (or (file-patch-old-path file-patch) (file-patch-new-path file-patch))
                                 (if mismatch (car mismatch) (+ expected 1))
                                 (if mismatch (cadr mismatch) "")
                                 (if mismatch (cddr mismatch) "")))))
              (let* ((updated (append (take lines position) new-side
                                      (drop lines (+ position (length old-side)))))
                     (reaches-end? (= (+ position (length old-side)) (length lines))))
                (loop (cdr hunks)
                      updated
                      (+ (- position (max 0 (- (hunk-old-start hunk) 1)))
                         (- (length new-side) (length old-side)))
                      (+ index 1)
                      (cond
                       ((not reaches-end?) trailing?)
                       ((hunk-new-no-newline? hunk) #f)
                       ((hunk-old-no-newline? hunk) #t)
                       (else trailing?))))))))))
