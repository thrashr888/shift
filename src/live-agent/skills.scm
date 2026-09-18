;; Skills are folders of instructions in the Agent Skills SKILL.md format.
;; Shift indexes names and descriptions for the model, hands a body over only
;; when asked, and never lets a skill widen tool policy. Nothing is evaluated.
(define-module (live-agent skills)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:export (skills-init! skill-index skill-find skill-directories skill-load!
            skills-prompt-block skills-json skill-loaded? loaded-skills reset-loaded-skills!
            parse-skill-file skill-file))

(define max-file-bytes (* 64 1024))
(define max-body-bytes (* 32 1024))
(define sources '())          ; ((label . directory) ...) in precedence order
(define index '())            ; cached skill records
(define signature #f)         ; directory mtimes the cache was built from
(define loaded '())           ; names loaded this session, newest first

;; Records are alists: name description path source valid error body-file
;; model? (offered to the model).
(define (record . entries) entries)
(define (field rec key) (assq-ref rec key))

(define* (skills-init! project-dir #:optional (extra '()))
  (let ((config (or (getenv "XDG_CONFIG_HOME") (string-append (or (getenv "HOME") "") "/.config")))
        (home (or (getenv "HOME") "")))
    (set! sources
      (filter (lambda (entry) (and (cdr entry) (not (string-null? (cdr entry)))))
        (append
         (list (cons "project" (and project-dir (string-append project-dir "/.shift/skills")))
               (cons "agents" (and project-dir (string-append project-dir "/.agents/skills")))
               (cons "cortex" (and project-dir (string-append project-dir "/.cortex/skills")))
               (cons "user" (string-append config "/shift/skills"))
               (cons "agents" (string-append home "/.agents/skills")))
         ;; skill-dirs setting: folders of skills kept elsewhere, such as a checked-out kit.
         (map (lambda (dir) (cons "dir" dir)) extra))))
    (set! index '()) (set! signature #f) (set! loaded '())))

(define (valid-name? name)
  (and (string? name) (<= 1 (string-length name) 64)
       (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) name)))

;; The frontmatter is the YAML between the leading --- lines; only scalar
;; values and folded/literal multi-line values are read, which covers every
;; published skill's name and description.
(define (parse-frontmatter lines)
  (let loop ((rest lines) (entries '()) (key #f) (chunks '()))
    (define (flush) (if key (cons (cons key (string-join (reverse chunks) " ")) entries) entries))
    (cond
     ((null? rest) (values (reverse (flush)) '()))
     ((string=? (string-trim-right (car rest)) "---") (values (reverse (flush)) (cdr rest)))
     ((and key (> (string-length (car rest)) 0) (char-whitespace? (string-ref (car rest) 0)))
      (loop (cdr rest) entries key (cons (string-trim-both (car rest)) chunks)))
     (else
      (let ((colon (string-index (car rest) #\:)))
        (if (and colon (> colon 0) (not (char-whitespace? (string-ref (car rest) 0))))
            (let* ((name (string-trim-both (substring (car rest) 0 colon)))
                   (value (string-trim-both (substring (car rest) (+ colon 1))))
                   (value (if (and (>= (string-length value) 2)
                                   (memv (string-ref value 0) '(#\" #\'))
                                   (char=? (string-ref value 0) (string-ref value (- (string-length value) 1))))
                              (substring value 1 (- (string-length value) 1))
                              value))
                   (folded? (member value '(">" "|" ">-" "|-"))))
              (loop (cdr rest) (flush) name (if (or folded? (string-null? value)) '() (list value))))
            (loop (cdr rest) entries key chunks)))))))

(define (parse-skill-file text)
  (let ((lines (string-split text #\newline)))
    (if (and (pair? lines) (string=? (string-trim-right (car lines)) "---"))
        (call-with-values (lambda () (parse-frontmatter (cdr lines)))
          (lambda (entries body-lines) (cons entries (string-join body-lines "\n"))))
        (cons '() text))))

(define (truthy? value) (and (string? value) (member (string-downcase value) '("true" "yes" "1")) #t))

(define (read-skill name file source)
  (let ((directory (dirname file)))
    (define (invalid reason) (record (cons 'name name) (cons 'path directory) (cons 'file file) (cons 'source source)
                                     (cons 'valid #f) (cons 'error reason) (cons 'model? #f)))
    (catch #t
      (lambda ()
        (let ((size (stat:size (stat file))))
          (if (> size max-file-bytes)
              (invalid "SKILL.md exceeds 64 KiB")
              (let* ((parsed (parse-skill-file (call-with-input-file file get-string-all #:encoding "UTF-8")))
                     (front (car parsed)) (body (cdr parsed))
                     (declared (assoc-ref front "name")) (description (assoc-ref front "description")))
                (cond
                 ((not (valid-name? name)) (invalid "folder name must be 1-64 lowercase letters, digits or hyphens"))
                 ((not declared) (invalid "frontmatter needs name"))
                 ((not (string=? declared name)) (invalid (string-append "frontmatter name " declared " differs from the folder name")))
                 ((not (and (string? description) (<= 1 (string-length description) 1024)))
                  (invalid "frontmatter needs a description of 1-1024 characters"))
                 ((string-any (lambda (c) (or (char=? c #\newline) (char=? c #\return))) description)
                  (invalid "description must be one line"))
                 ((> (string-length body) max-body-bytes) (invalid "body exceeds 32 KiB"))
                 (else (record (cons 'name name) (cons 'description description) (cons 'path directory) (cons 'file file)
                               (cons 'source source) (cons 'valid #t) (cons 'error #f)
                               (cons 'model? (not (truthy? (assoc-ref front "disable-model-invocation")))))))))))
      (lambda (key . args) (invalid (format #f "unreadable: ~a" key))))))

(define (directory-entries directory)
  (catch #t
    (lambda () (sort (filter (lambda (n) (not (member n '("." "..")))) (scandir directory)) string<?))
    (lambda _ '())))

;; A source holds skill folders directly or grouped one level down in
;; category folders, the way Hermes lays out ~/.hermes/skills/category/skill.
;; Skills in a source are NAME/SKILL.md folders, category/NAME/SKILL.md one
;; level down, or flat NAME.md files with frontmatter, which is how cortex
;; writes its consolidated patterns into .cortex/skills. Returns (name . file).
(define (skill-entries directory)
  (append-map
   (lambda (name)
     (let ((child (string-append directory "/" name)))
       (cond ((file-exists? (string-append child "/SKILL.md")) (list (cons name (string-append child "/SKILL.md"))))
             ((and (string-suffix? ".md" name) (> (string-length name) 3)
                   (catch #t (lambda () (eq? 'regular (stat:type (stat child)))) (lambda _ #f)))
              (list (cons (substring name 0 (- (string-length name) 3)) child)))
             ((catch #t (lambda () (eq? 'directory (stat:type (stat child)))) (lambda _ #f))
              (filter-map (lambda (n)
                            (let ((grand (string-append child "/" n "/SKILL.md")))
                              (and (file-exists? grand) (cons n grand))))
                          (directory-entries child)))
             (else '()))))
   (directory-entries directory)))
(define (current-signature)
  (map (lambda (entry)
         (let ((directory (cdr entry)))
           (cons directory
                 (map (lambda (e) (cons (cdr e) (catch #t (lambda () (stat:mtime (stat (cdr e)))) (lambda _ #f))))
                      (skill-entries directory)))))
       sources))
;; A supporting file inside a valid skill's folder, bounded like SKILL.md.
(define (skill-file name path)
  (let ((rec (skill-find name)))
    (unless (and rec (field rec 'valid)) (error "no valid skill named" name))
    (let* ((root (canonicalize-path (field rec 'path)))
           (target (catch #t (lambda () (canonicalize-path (string-append root "/" path))) (lambda _ #f))))
      (unless (and target (or (string=? target root) (string-prefix? (string-append root "/") target)))
        (error "path must name a file inside the skill folder" path))
      (when (> (stat:size (stat target)) max-file-bytes) (error "skill file exceeds 64 KiB" path))
      (string-append "Skill " name " file " path "\n\n"
                     (call-with-input-file target get-string-all #:encoding "UTF-8")))))

(define (rebuild!)
  (set! index
    (let loop ((entries sources) (seen '()) (result '()))
      (if (null? entries)
          (reverse result)
          (let* ((source (caar entries)) (directory (cdar entries))
                 (found (filter-map
                          (lambda (e)
                            (and (not (member (car e) seen))
                                 (read-skill (car e) (cdr e) source)))
                          (skill-entries directory))))
            (loop (cdr entries) (append (map (lambda (r) (field r 'name)) found) seen)
                  (append (reverse found) result)))))))

;; The index rebuilds only when a source directory or a SKILL.md changed, so
;; calling it at every turn start is cheap.
(define (skill-index)
  (let ((now (current-signature)))
    (unless (equal? now signature) (set! signature now) (rebuild!))
    index))

(define (skill-find name) (find (lambda (r) (equal? (field r 'name) name)) (skill-index)))
(define (skill-directories) (map (lambda (r) (field r 'path)) (filter (lambda (r) (field r 'valid)) (skill-index))))
(define (skill-loaded? name) (and (member name loaded) #t))
(define (loaded-skills) loaded)
(define (reset-loaded-skills!) (set! loaded '()))

;; Returns the body text and records the load; the directory goes to the
;; model so supporting files are reachable through read.
(define* (skill-load! name #:key (by-model #t))
  (let ((rec (skill-find name)))
    (unless rec (error (format #f "no skill named ~s; available: ~a" name
                               (let ((names (map (lambda (r) (field r 'name)) (skill-index))))
                                 (if (null? names) "none" (string-join names ", "))))))
    (unless (field rec 'valid) (error (format #f "skill ~a is invalid: ~a" name (field rec 'error))))
    (when (and by-model (not (field rec 'model?)))
      (error (format #f "skill ~a is user-only; load it with /skill ~a" name name)))
    (let ((body (cdr (parse-skill-file (call-with-input-file (field rec 'file)
                                          get-string-all #:encoding "UTF-8")))))
      (unless (member name loaded) (set! loaded (cons name loaded)))
      (string-append "Skill " name " (" (field rec 'path) ")\n\n" (string-trim-both body)))))

(define (skills-prompt-block)
  (let ((offered (filter (lambda (r) (and (field r 'valid) (field r 'model?))) (skill-index))))
    (if (null? offered)
        ""
        (string-append
         "\n\n<skills>\nSkills are instructions you can load with the skill tool when a task matches one; load a skill before following it.\n"
         (string-join (map (lambda (r) (string-append "- " (field r 'name) ": " (field r 'description))) offered) "\n")
         "\n</skills>"))))

(define (skills-json)
  (apply json-array
    (map (lambda (r)
           (json-object (cons "name" (field r 'name)) (cons "description" (or (field r 'description) ""))
                        (cons "source" (field r 'source)) (cons "path" (field r 'path))
                        (cons "valid" (field r 'valid)) (cons "error" (or (field r 'error) json-null))
                        (cons "model" (field r 'model?)) (cons "loaded" (skill-loaded? (field r 'name)))))
         (skill-index))))
