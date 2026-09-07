;; Trusted coding built-in: structured status and diff over the change ledger
;; and, when present, Git. apply_patch and run join this module in later
;; steps of docs/coding-workflow-rfc.md. Nothing here goes through a shell.
(define-module (shift coding)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent tools)
  #:use-module (live-agent changes)
  #:use-module (live-agent diff)
  #:use-module (live-agent patch)
  #:export (coding-tool-schema coding-execute coding-prepare run-argv))

(define max-output (* 64 1024))
(define max-patch-input (* 512 1024))

(define (bounded text)
  (if (> (string-length text) max-output)
      (string-append (substring text 0 max-output)
                     "\n…[output truncated; original chars="
                     (number->string (string-length text)) "]")
      text))

;; argv is executed directly with stdout and stderr captured together.
;; Returns (exit-code . output).
(define (run-argv argv)
  (let* ((ends (pipe))
         (pid (spawn (car argv) argv #:output (cdr ends) #:error (cdr ends))))
    (close-port (cdr ends))
    (let* ((output (get-string-all (car ends)))
           (code (status:exit-val (cdr (waitpid pid)))))
      (close-port (car ends))
      (cons (or code -1) output))))

(define (git-lines argv)
  (let ((result (run-argv argv)))
    (and (= 0 (car result))
         (filter (lambda (line) (not (string-null? line)))
                 (string-split (cdr result) #\newline)))))

;; #f outside a checkout, otherwise (branch . dirty-paths).
(define (git-state root)
  (and (git-lines (list "git" "-C" root "rev-parse" "--is-inside-work-tree"))
       (let ((branch (git-lines (list "git" "-C" root "symbolic-ref" "--short" "-q" "HEAD")))
             (status (git-lines (list "git" "-C" root "status" "--porcelain" "--untracked-files=all"))))
         (cons (if (and branch (pair? branch)) (car branch) "detached")
               ;; Shift's own state directory is never the user's dirt.
               (filter (lambda (path)
                         (not (or (string-prefix? ".shift/" path)
                                  (string-prefix? ".lisp-agent/" path))))
                       (map (lambda (line)
                              (let* ((path (substring line (min 3 (string-length line))))
                                     (arrow (string-contains path " -> ")))
                                (if arrow (substring path (+ arrow 4)) path)))
                            (or status '())))))))

(define (valid-relative-path? path)
  (and (string? path)
       (not (string-null? path))
       (not (absolute-file-name? path))
       (not (any (lambda (segment) (string=? segment ".."))
                 (string-split path #\/)))))

(define (current-text root path)
  (let ((absolute (string-append root "/" path)))
    (and (file-exists? absolute)
         (not (eq? 'directory (stat:type (stat absolute))))
         (call-with-input-file absolute get-string-all))))

;; Group committed entries per path: earliest pre-image, the turns involved.
(define (grouped-changes entries)
  (let loop ((remaining entries) (groups '()))
    (if (null? remaining)
        (reverse groups)
        (let* ((entry (car remaining))
               (path (assq-ref entry 'path))
               (existing (assoc path groups)))
          (if existing
              (loop (cdr remaining)
                    (map (lambda (group)
                           (if (eq? group existing)
                               (list path (cadr group)
                                     (delete-duplicates
                                      (append (caddr group) (list (assq-ref entry 'turn)))))
                               group))
                         groups))
              (loop (cdr remaining)
                    (cons (list path (assq-ref entry 'before) (list (assq-ref entry 'turn)))
                          groups)))))))

(define (scope-entries ledger turn scope)
  (filter (lambda (entry)
            (and (eq? (assq-ref entry 'state) 'committed)
                 (or (eq? scope 'session) (= (assq-ref entry 'turn) turn))))
          (ledger-entries ledger)))

;; One unified diff per changed path against the earliest pre-image.
(define (ledger-diffs ledger root groups)
  (map (lambda (group)
         (let* ((path (car group))
                (before (and (cadr group) (ledger-read-blob ledger (cadr group))))
                (after (current-text root path))
                (text (unified-diff before after
                                    (string-append "a/" path) (string-append "b/" path))))
           (list path text (diffstat text) (caddr group))))
       groups))

(define (format-turns turns)
  (string-join (map number->string (sort turns <)) ", "))

(define (total-diffstat diffs)
  (fold (lambda (entry total)
          (cons (+ (car total) (car (caddr entry)))
                (+ (cdr total) (cdr (caddr entry)))))
        '(0 . 0) diffs))

(define (execute-status root ledger turn)
  (let* ((git (git-state root))
         (session (ledger-diffs ledger root (grouped-changes (scope-entries ledger turn 'session))))
         (current (filter (lambda (entry) (member turn (cadddr entry))) session))
         (touched (map car session))
         (untouched (if git
                        (filter (lambda (path) (not (member path touched))) (cdr git))
                        '()))
         (port (open-output-string)))
    (if git
        (format port "git ~a · ~a dirty file~a~%" (car git) (length (cdr git))
                (if (= 1 (length (cdr git))) "" "s"))
        (display "not a git repository\n" port))
    (format port "changed this turn (turn ~a): ~a~%" turn
            (if (null? current) "nothing" (format-diffstat (total-diffstat current))))
    (for-each (lambda (entry)
                (format port "  ~a ~a~%" (car entry) (format-diffstat (caddr entry))))
              current)
    (format port "changed this session: ~a file~a~a~%"
            (length session) (if (= 1 (length session)) "" "s")
            (if (null? session) ""
                (format #f " in turn~a ~a"
                        (if (= 1 (length (delete-duplicates (append-map cadddr session)))) "" "s")
                        (format-turns (delete-duplicates (append-map cadddr session))))))
    (for-each (lambda (entry)
                (unless (member entry current)
                  (format port "  ~a ~a turn~a ~a~%" (car entry) (format-diffstat (caddr entry))
                          (if (= 1 (length (cadddr entry))) "" "s") (format-turns (cadddr entry)))))
              session)
    (unless (null? untouched)
      (format port "dirty in git but not touched by shift: ~a~%" (length untouched))
      (for-each (lambda (path) (format port "  ~a~%" path)) untouched))
    (make-tool-result #t (bounded (get-output-string port)))))

(define (parse-paths arguments)
  (let ((value (json-object-ref arguments "paths" #f)))
    (cond
     ((not value) '())
     ((json-array? value)
      (let ((paths (json-array-items value)))
        (unless (every valid-relative-path? paths)
          (error "paths must be project-relative file paths without .."))
        paths))
     (else (error "paths must be an array of strings")))))

(define (execute-diff arguments root ledger turn)
  (let* ((scope-name (json-object-ref arguments "scope" "turn"))
         (scope (cond ((equal? scope-name "turn") 'turn)
                      ((equal? scope-name "session") 'session)
                      ((equal? scope-name "git") 'git)
                      (else (error "scope must be turn, session, or git" scope-name))))
         (paths (parse-paths arguments)))
    (if (eq? scope 'git)
        (let ((git (git-state root)))
          (unless git (error "not a git repository; use scope turn or session"))
          (let* ((argv (append (list "git" "-C" root "diff" "HEAD" "--") paths))
                 (result (run-argv argv))
                 (result (if (= 0 (car result))
                             result
                             (run-argv (append (list "git" "-C" root "diff" "--") paths)))))
            (unless (= 0 (car result)) (error "git diff failed" (cdr result)))
            (make-tool-result
             #t
             (if (string-null? (string-trim-both (cdr result)))
                 "No uncommitted changes in git."
                 (bounded (string-append (format-diffstat (diffstat (cdr result)))
                                         " against HEAD\n" (cdr result)))))))
        (let* ((entries (filter (lambda (entry)
                                  (or (null? paths) (member (assq-ref entry 'path) paths)))
                                (scope-entries ledger turn scope)))
               (diffs (filter (lambda (entry) (not (string-null? (cadr entry))))
                              (ledger-diffs ledger root (grouped-changes entries)))))
          (make-tool-result
           #t
           (if (null? diffs)
               (format #f "No changes in scope ~a." scope-name)
               (bounded
                (string-append
                 (format #f "~a file~a changed ~a~%"
                         (length diffs) (if (= 1 (length diffs)) "" "s")
                         (format-diffstat (total-diffstat diffs)))
                 (string-join (map cadr diffs) "")))))))))

;; One file section becomes one prepared change, or two for a rename, which
;; is expressed as a delete plus a create so undo needs no special case.
(define (prepare-section file root)
  (let ((old (file-patch-old-path file))
        (new (file-patch-new-path file)))
    (if (not old)
        (let* ((resolved (resolve-write-path new root))
               (absolute (cadr resolved)))
          (when (file-exists? absolute)
            (error "patch creates a file that already exists" new))
          (list (prepare-file-change "apply_patch" (car resolved) absolute
                                     #f (apply-file-patch #f file)
                                     (string-append "created " new))))
        (let* ((resolved (resolve-existing-path old root "apply_patch"))
               (absolute (cadr resolved)))
          (when (> (stat:size (stat absolute)) max-patch-input)
            (error "patched file exceeds the 512 KiB limit" old))
          (let* ((before (call-with-input-file absolute get-string-all))
                 (after (apply-file-patch before file)))
            (cond
             ((not new)
              (unless (string-null? after)
                (error "a patch that deletes a file must remove every line" old))
              (list (prepare-file-change "apply_patch" (car resolved) absolute
                                         before #f (string-append "deleted " old))))
             ((string=? old new)
              (list (prepare-file-change "apply_patch" (car resolved) absolute
                                         before after (string-append "patched " old))))
             (else
              (let* ((target (resolve-write-path new root))
                     (target-absolute (cadr target)))
                (when (file-exists? target-absolute)
                  (error "patch renames onto a file that already exists" new))
                (list (prepare-file-change "apply_patch" (car resolved) absolute
                                           before #f (string-append "deleted " old))
                      (prepare-file-change "apply_patch" (car target) target-absolute
                                           #f after (string-append "created " new)))))))))))

;; Parses and applies the whole patch in memory; nothing is written here.
(define (coding-prepare arguments root)
  (let ((text (json-object-ref arguments "patch" #f)))
    (unless (and (string? text) (not (string-null? (string-trim-both text))))
      (error "patch must be a non-empty unified diff"))
    (when (> (string-length text) max-patch-input)
      (error "patch exceeds the 512 KiB limit"))
    (let* ((changes (append-map (lambda (file) (prepare-section file root))
                                (parse-patch text)))
           (paths (map prepared-change-path changes)))
      (unless (= (length paths) (length (delete-duplicates paths)))
        (error "patch touches the same path more than once"))
      changes)))

(define (error-detail key arguments)
  (catch #t
    (lambda ()
      (if (and (>= (length arguments) 3) (string? (cadr arguments)) (list? (caddr arguments)))
          (apply format #f (cadr arguments) (caddr arguments))
          (format #f "~a: ~s" key arguments)))
    (lambda _ (format #f "~a: ~s" key arguments))))

(define (coding-execute name arguments root ledger turn)
  (catch #t
    (lambda ()
      (cond
       ((string=? name "status") (execute-status root ledger turn))
       ((string=? name "diff") (execute-diff arguments root ledger turn))
       ((string=? name "apply_patch")
        (error "apply_patch is a mutation and runs through the prepare/approve/commit path"))
       (else (error "coding tool is not implemented yet" name))))
    (lambda (key . detail)
      (if (eq? key 'turn-cancelled)
          (apply throw key detail)
          (make-tool-result #f (string-append "tool error: " (error-detail key detail)))))))

(define (coding-tool-schema name)
  (cond
   ((string=? name "status")
    (function-tool
     "status"
     (string-append
      "Show what this session changed on disk, per turn, with diffstats, plus "
      "the git branch and files dirty in git that shift did not touch. Use it "
      "before reporting work as done and whenever the repository state matters.")
     (json-object)
     '()))
   ((string=? name "diff")
    (function-tool
     "diff"
     (string-append
      "Show unified diffs. scope turn (default) covers files changed in the current "
      "turn, session covers every turn of this session, and git compares the working "
      "tree with HEAD. Optional paths restrict the output.")
     (json-object
      (cons "scope"
            (json-object (cons "type" "string")
                         (cons "enum" (json-array "turn" "session" "git"))
                         (cons "description" "turn, session, or git; defaults to turn")))
      (cons "paths"
            (json-object (cons "type" "array")
                         (cons "items" (json-object (cons "type" "string")))
                         (cons "description" "Optional project-relative paths to include"))))
     '()))
   ((string=? name "apply_patch")
    (function-tool
     "apply_patch"
     (string-append
      "Apply one unified diff to project files, possibly several. Use the exact "
      "--- a/PATH, +++ b/PATH, @@ hunk format that git diff and diff -u produce, "
      "with /dev/null for creates and deletes. Every hunk must match its context "
      "exactly and the whole patch is applied or nothing is. Prefer edit for one "
      "exact replacement and apply_patch for multi-hunk or multi-file changes.")
     (json-object (cons "patch" (string-parameter "Unified diff text")))
     '("patch")))
   (else (error "unknown coding tool" name))))
