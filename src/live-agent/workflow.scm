;; Workflows: named, durable procedures under .shift/workflows/NAME, read as
;; data and never evaluated. A workflow is an ordered list of steps, each a
;; prompt for one turn with checks that decide whether the step succeeded,
;; plus a round budget for the whole run. Runs leave one JSON record each
;; under runs/. The runtime (main.scm) drives the turns; everything here is
;; parsing, checks and records, so it is testable without a model.
(define-module (live-agent workflow)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:export (workflow-root workflow-names workflow-read workflow-file
            workflows-init! workflow-sources workflow-locate workflows-signature
            workflow-name workflow-version workflow-description workflow-budget workflow-steps
            workflow-source step-name step-prompt step-checks
            check-kind check-text evaluate-check
            workflow-run-path workflow-record-run! workflow-runs workflow-last-run
            workflow-summary workflows-json run->json
            safe-workflow-name? caught-message))

(define max-file-bytes (* 64 1024))
(define max-steps 32)
(define max-runs-listed 20)

(define (workflow-root project) (string-append project "/.shift/workflows"))
;; The project's own folder for a workflow: runs, versions and any promoted
;; copy live here even when the definition came from a plugin or the user dir.
(define (workflow-dir project name) (string-append (workflow-root project) "/" name))
(define (workflow-file project name) (string-append (workflow-dir project name) "/workflow.scm"))

;; --- sources ---------------------------------------------------------------------
;; ((label . directory) ...) in precedence order: the project first, then the
;; user's ~/.config/shift/workflows, then each plugin's folder. The first
;; source that has NAME/workflow.scm defines the workflow, as skills do.
(define sources '())
(define (workflows-init! project extra)
  (set! sources (cons (cons "project" (workflow-root project)) extra)))
(define (workflow-sources) sources)
(define (effective-sources project)
  (if (null? sources) (list (cons "project" (workflow-root project))) sources))
(define (source-names directory)
  (if (file-exists? directory)
      (filter (lambda (n) (and (safe-workflow-name? n) (file-exists? (string-append directory "/" n "/workflow.scm"))))
              (scandir directory (lambda (n) (not (member n '("." ".."))))))
      '()))
;; → (label . file) for the source that defines NAME, or #f.
(define* (workflow-locate name #:optional (project (getcwd)))
  (and (safe-workflow-name? name)
       (any (lambda (source)
              (let ((file (string-append (cdr source) "/" name "/workflow.scm")))
                (and (file-exists? file) (cons (car source) file))))
            (effective-sources project))))
;; Directory and file mtimes across every source, so a watcher can tell when
;; a workflow was added, edited or removed without reading them all.
(define (workflows-signature)
  (map (lambda (source)
         (let ((directory (cdr source)))
           (cons directory
                 (cons (catch #t (lambda () (stat:mtime (stat directory))) (lambda _ #f))
                       (map (lambda (n) (cons n (catch #t (lambda () (stat:mtime (stat (string-append directory "/" n "/workflow.scm")))) (lambda _ #f))))
                            (source-names directory))))))
       (effective-sources (getcwd))))

(define (safe-workflow-name? name)
  (and (string? name) (<= 1 (string-length name) 64)
       (char-alphabetic? (string-ref name 0))
       (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) name)))

(define (workflow-names project)
  (sort (delete-duplicates (append-map (lambda (source) (source-names (cdr source))) (effective-sources project)) string=?)
        string<?))

;; --- reading -------------------------------------------------------------------
(define (bounded-read path)
  (let ((size (stat:size (stat path))))
    (when (> size max-file-bytes) (error "workflow file is over 64 KiB" path))
    (call-with-input-file path get-string-all)))

(define (data-form text what)
  (let ((form (call-with-input-string text
                (lambda (p)
                  (let ((form (read p)))
                    (unless (eof-object? (read p)) (error (string-append what " must contain one data form")))
                    form)))))
    (unless (and (list? form) (every (lambda (e) (and (pair? e) (symbol? (car e)))) form))
      (error (string-append what " must be a list of (key ...) entries")))
    form))

(define (field form key) (assq key (cdr form)))

;; The message of a caught error, whatever shape Guile threw it in.
(define (caught-message key args)
  (cond
   ;; (error MSG IRRITANT...) throws (misc-error #f "MSG ~S" (IRRITANT...) #f).
   ((and (>= (length args) 3) (string? (cadr args)) (list? (caddr args)))
    (catch #t (lambda () (apply format #f (cadr args) (caddr args))) (lambda _ (cadr args))))
   ((and (pair? args) (pair? (cdr args)) (string? (cadr args))) (cadr args))
   ((and (pair? args) (string? (car args))) (car args))
   (else (format #f "~a" key))))

(define (parse-check spec)
  (unless (and (pair? spec) (symbol? (car spec))) (error "a check is (run ARGV...), (contains TEXT), (file PATH), (notes NAME) or (judge CRITERION)"))
  (let ((kind (car spec)) (args (cdr spec)))
    (case kind
      ((run) (unless (and (pair? args) (every string? args)) (error "(run PROGRAM ARG...) needs strings"))
             (list 'run args))
      ((contains file notes judge)
       (unless (and (= (length args) 1) (string? (car args)) (not (string-null? (car args))))
         (error (format #f "(~a TEXT) needs one non-empty string" kind)))
       (list kind (car args)))
      (else (error "unknown check kind" kind)))))

(define (parse-step entry)
  (unless (and (>= (length entry) 3) (string? (cadr entry)) (string? (caddr entry)))
    (error "a step is (step NAME PROMPT (check ...) ...)"))
  (let ((name (cadr entry)) (prompt (caddr entry)))
    (unless (safe-workflow-name? name) (error "step names are lowercase letters, digits and hyphens" name))
    (when (string-null? (string-trim-both prompt)) (error "a step needs a prompt" name))
    (list name prompt
          (map (lambda (c)
                 (unless (and (pair? c) (eq? (car c) 'check) (= (length c) 2)) (error "step checks are (check SPEC)" name))
                 (parse-check (cadr c)))
               (filter (lambda (e) (and (pair? e) (eq? (car e) 'check))) (cdddr entry))))))

;; ((name . NAME) (version . N) (description . TEXT) (budget . ROUNDS) (steps . (STEP ...)))
;; where STEP is (name prompt checks) and each check is (kind detail).
(define (parse-workflow form name)
  (let ((head (car form)))
    (unless (and (eq? (car head) 'workflow) (>= (length head) 2) (equal? (cadr head) name))
      (error (format #f "the file must start with (workflow ~s VERSION)" name)))
    (let* ((version (if (>= (length head) 3) (caddr head) 1))
           (description (let ((d (field form 'description))) (if (and d (pair? (cdr d)) (string? (cadr d))) (cadr d) "")))
           (budget (let ((b (field form 'budget)))
                     (if b
                         (let ((rounds (assq 'rounds (cdr b))))
                           (unless (and rounds (integer? (cadr rounds)) (<= 1 (cadr rounds) 400))
                             (error "(budget (rounds N)) takes 1 through 400"))
                           (cadr rounds))
                         40)))
           (steps (map parse-step (filter (lambda (e) (eq? (car e) 'step)) (cdr form)))))
      (unless (and (integer? version) (>= version 1)) (error "the version is a positive integer"))
      (when (null? steps) (error "a workflow needs at least one step"))
      (when (> (length steps) max-steps) (error "a workflow has at most 32 steps"))
      (let ((names (map car steps)))
        (unless (= (length names) (length (delete-duplicates names))) (error "step names must be distinct")))
      `((name . ,name) (version . ,version) (description . ,description) (budget . ,budget) (steps . ,steps)))))

(define (workflow-read project name)
  (unless (safe-workflow-name? name) (error "workflow names are lowercase letters, digits and hyphens" name))
  (let ((located (workflow-locate name project)))
    (unless located (error "no such workflow" name))
    (let ((w (parse-workflow (data-form (bounded-read (cdr located)) "a workflow") name)))
      (cons (cons 'source (car located)) w))))

(define (workflow-name w) (assq-ref w 'name))
(define (workflow-source w) (or (assq-ref w 'source) "project"))
(define (workflow-version w) (assq-ref w 'version))
(define (workflow-description w) (assq-ref w 'description))
(define (workflow-budget w) (assq-ref w 'budget))
(define (workflow-steps w) (assq-ref w 'steps))
(define (step-name s) (car s))
(define (step-prompt s) (cadr s))
(define (step-checks s) (caddr s))
(define (check-kind c) (car c))
(define (check-text c) (if (eq? (car c) 'run) (string-join (cadr c) " ") (cadr c)))

;; --- checks -----------------------------------------------------------------------
;; context: ((answer . TEXT) (task . STEP-PROMPT) (root . DIR) (run . (lambda (argv) (code . output)))
;;           (notes-exists? . (lambda (name) bool)) (judge . (lambda (criterion answer task) alist-or-#f)))
;; The judge answers ((holds . bool) (confidence . p) ...) or #f when no judge
;; could answer; that check then fails and says so, never passes by default.
(define (evaluate-check check context)
  (define (get k) (assq-ref context k))
  (let ((kind (check-kind check)))
    (catch #t
      (lambda ()
        (case kind
          ((run)
           (let* ((result ((get 'run) (cadr check))) (code (car result)))
             `((kind . run) (text . ,(check-text check)) (ok . ,(eqv? code 0))
               (detail . ,(format #f "exit ~a" code)))))
          ((contains)
           (let ((answer (or (get 'answer) "")))
             `((kind . contains) (text . ,(cadr check)) (ok . ,(and (string-contains answer (cadr check)) #t))
               (detail . ,(if (string-contains answer (cadr check)) "found in the answer" "not in the answer")))))
          ((file)
           (let* ((path (cadr check))
                  (full (if (string-prefix? "/" path) path (string-append (get 'root) "/" path)))
                  (ok (file-exists? full)))
             `((kind . file) (text . ,path) (ok . ,ok) (detail . ,(if ok "exists" "missing")))))
          ((notes)
           (let ((ok (and ((get 'notes-exists?) (cadr check)) #t)))
             `((kind . notes) (text . ,(cadr check)) (ok . ,ok) (detail . ,(if ok "note exists" "no such note")))))
          ((judge)
           (let* ((judge (get 'judge))
                  (verdict (and (procedure? judge) (judge (cadr check) (or (get 'answer) "") (get 'task)))))
             (if (and verdict (assq 'holds verdict))
                 `((kind . judge) (text . ,(cadr check)) (ok . ,(and (assq-ref verdict 'holds) #t))
                   (confidence . ,(assq-ref verdict 'confidence)) (model . ,(assq-ref verdict 'model))
                   (detail . ,(string-append
                               (format #f "~a (~a)" (if (assq-ref verdict 'holds) "holds" "does not hold")
                                       (let ((c (assq-ref verdict 'confidence))) (if (number? c) (format #f "confidence ~,2f" c) "no confidence")))
                               ;; A typed judge that could not answer says so beside the fallback's verdict.
                               (let ((fallback (assq-ref verdict 'fallback)))
                                 (if (string? fallback) (string-append " · after " fallback) "")))))
                 `((kind . judge) (text . ,(cadr check)) (ok . #f)
                   (detail . ,(or (and verdict (assq-ref verdict 'reason)) "no judge could answer"))))))
          (else `((kind . ,kind) (text . ,(check-text check)) (ok . #f) (detail . "unknown check")))))
      (lambda (key . args)
        `((kind . ,kind) (text . ,(check-text check)) (ok . #f)
          (detail . ,(string-append "check failed: " (caught-message key args))))))))

;; --- runs -------------------------------------------------------------------------
(define (runs-dir project name) (string-append (workflow-dir project name) "/runs"))

(define (run-files project name)
  (let ((dir (runs-dir project name)))
    (if (file-exists? dir)
        (sort (filter (lambda (n) (string-suffix? ".json" n)) (scandir dir (lambda (n) (not (member n '("." ".."))))))
              (lambda (a b) (> (run-number a) (run-number b))))
        '())))
(define (run-number file) (or (string->number (substring file 0 (- (string-length file) 5))) 0))

(define (ensure-directory! path)
  (unless (file-exists? path) (ensure-directory! (dirname path)) (mkdir path)))
(define (workflow-run-path project name)
  (let* ((dir (runs-dir project name))
         (next (+ 1 (fold max 0 (map run-number (run-files project name))))))
    (ensure-directory! dir)
    (string-append dir "/" (number->string next) ".json")))

;; record: ((workflow . NAME) (version . N) (session . NAME) (started . ISO) (status . resolved|failed|budget|error)
;;          (rounds . N) (steps . (STEP-RECORD ...)) (error . TEXT-or-#f))
;; step record: ((name . N) (status . ok|failed|skipped|limited) (rounds . N) (checks . (CHECK-RESULT ...)))
(define (run->json record)
  (define (check->json c)
    (apply json-object
           (append (list (cons "kind" (symbol->string (assq-ref c 'kind))) (cons "text" (assq-ref c 'text))
                         (cons "ok" (and (assq-ref c 'ok) #t)) (cons "detail" (or (assq-ref c 'detail) "")))
                   (if (number? (assq-ref c 'confidence)) (list (cons "confidence" (assq-ref c 'confidence))) '())
                   (if (string? (assq-ref c 'model)) (list (cons "model" (assq-ref c 'model))) '()))))
  (define (step->json s)
    (json-object (cons "name" (assq-ref s 'name)) (cons "status" (symbol->string (assq-ref s 'status)))
                 (cons "rounds" (or (assq-ref s 'rounds) 0))
                 (cons "checks" (apply json-array (map check->json (or (assq-ref s 'checks) '()))))))
  (json-object (cons "workflow" (assq-ref record 'workflow)) (cons "version" (assq-ref record 'version))
               (cons "session" (or (assq-ref record 'session) "")) (cons "started" (assq-ref record 'started))
               (cons "status" (symbol->string (assq-ref record 'status))) (cons "rounds" (or (assq-ref record 'rounds) 0))
               (cons "steps" (apply json-array (map step->json (assq-ref record 'steps))))
               (cons "error" (or (assq-ref record 'error) json-null))))

(define (workflow-record-run! project name record)
  (let ((path (workflow-run-path project name)))
    (call-with-output-file path (lambda (p) (display (json-write (run->json record)) p) (newline p)))
    path))

;; Newest first, bounded; each is the stored JSON object.
(define (workflow-runs project name)
  (let ((dir (runs-dir project name)))
    (filter-map (lambda (file)
                  (catch #t
                    (lambda () (json-read (call-with-input-file (string-append dir "/" file) get-string-all)))
                    (lambda _ #f)))
                (let ((files (run-files project name))) (if (> (length files) max-runs-listed) (take files max-runs-listed) files)))))

(define (workflow-last-run project name)
  (let ((runs (workflow-runs project name))) (and (pair? runs) (car runs))))

;; What the sidebar and /workflow show per workflow. An unreadable file is
;; listed with its error so the person sees what to fix.
(define (workflow-summary project name)
  (catch #t
    (lambda ()
      (let ((w (workflow-read project name)) (last (workflow-last-run project name)))
        (json-object (cons "name" name) (cons "version" (workflow-version w)) (cons "source" (workflow-source w))
                     (cons "description" (workflow-description w))
                     (cons "budget" (workflow-budget w))
                     (cons "steps" (apply json-array (map step-name (workflow-steps w))))
                     (cons "runs" (length (run-files project name)))
                     (cons "last" (or last json-null)))))
    (lambda (key . args)
      (json-object (cons "name" name) (cons "error" (caught-message key args))))))

(define (workflows-json project)
  (apply json-array (map (lambda (name) (workflow-summary project name)) (workflow-names project))))
