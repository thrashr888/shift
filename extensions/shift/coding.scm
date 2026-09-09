;; Trusted coding built-in: structured status and diff over the change ledger
;; and, when present, Git. apply_patch and run join this module in later
;; steps of docs/coding-workflow-rfc.md. Nothing here goes through a shell.
(define-module (shift coding)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 iconv)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (live-agent json)
  #:use-module (live-agent tools)
  #:use-module (live-agent changes)
  #:use-module (live-agent diff)
  #:use-module (live-agent patch)
  #:use-module (live-agent sha256)
  #:export (coding-tool-schema coding-execute coding-prepare run-argv
            executed-argv capture-process unwrap-agentkernel-output))

(define max-output (* 64 1024))
(define max-patch-input (* 512 1024))
(define default-timeout 120)
(define max-timeout 600)
(define head-bytes (* 16 1024))
(define tail-bytes (* 48 1024))
(define max-changed-check 200)

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
    (let ((runs (ledger-runs ledger)))
      (unless (null? runs)
        (let* ((last-run (last runs))
               (input (json-object-ref (json-object-ref last-run "invocation") "input"))
               (outcome (json-object-ref last-run "outcome")))
          (format port "last run (turn ~a): ~a · ~a~%"
                  (json-object-ref last-run "turn")
                  (string-join (json-array-items (json-object-ref input "command")) " ")
                  (if (json-object-ref outcome "success")
                      "exit 0"
                      (let ((error (json-object-ref outcome "error")))
                        (if (string? error) error (format #f "exit ~a" (json-object-ref outcome "exit_code")))))))))
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
    (let ((undoable (ledger-undoable-turns ledger)))
      (format port "undoable turns: ~a~%"
              (if (null? undoable) "none" (string-join (map number->string undoable) ", "))))
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

;; --- run ---------------------------------------------------------------

(define (parse-run-arguments arguments root)
  (let* ((argv-value (json-object-ref arguments "argv" #f))
         (argv (and (json-array? argv-value) (json-array-items argv-value)))
         (cwd (json-object-ref arguments "cwd" "."))
         (timeout (json-object-ref arguments "timeout_seconds" default-timeout)))
    (unless (and argv (pair? argv)
                 (every (lambda (item) (and (string? item) (not (string-null? item)))) argv))
      (error "argv must be a non-empty array of strings"))
    (unless (and (string? cwd) (valid-relative-path? cwd))
      (error "cwd must be a project-relative directory"))
    (unless (and (integer? timeout) (>= timeout 1) (<= timeout max-timeout))
      (error (format #f "timeout_seconds must be an integer from 1 through ~a" max-timeout)))
    (let* ((resolved (resolve-existing-path cwd root "run"))
           (absolute (cadr resolved)))
      (unless (eq? 'directory (stat:type (stat absolute)))
        (error "cwd is not a directory" cwd))
      (values argv
              (if (string=? absolute (car resolved))
                  "."
                  (substring absolute (+ 1 (string-length (car resolved)))))
              absolute
              timeout))))

;; The backend seam: local runs argv as given; agentkernel wraps it in
;; `agentkernel exec`, which mounts the project at /workspace so cwd maps
;; directly. It does not pass exit codes through: a failing command makes
;; agentkernel exit 1 and fold the output into an error line, which
;; unwrap-agentkernel-output undoes.
(define agentkernel-marker "Error: Command exited with code ")

(define (unwrap-agentkernel-output status code bytes)
  (if (not (and (eq? status 'exit) (= code 1)))
      (values status code bytes)
      (let* ((text (bytevector->string bytes "UTF-8" 'substitute))
             (at (string-contains text agentkernel-marker))
             (start (and at (+ at (string-length agentkernel-marker))))
             (colon (and start (string-index text #\: start)))
             (real (and colon (string->number (substring text start colon)))))
        (if (and real (exact-integer? real))
            (values 'exit real
                    (string->utf8
                     (string-append (substring text 0 at)
                                    (string-trim (substring text (+ colon 1)) #\space))))
            (values status code bytes)))))

(define (executed-argv argv workdir backend sandbox)
  (case backend
    ((agentkernel)
     (unless (and (string? sandbox) (not (string-null? sandbox)))
       (error "run-backend agentkernel needs a run-sandbox name"))
     (append (list "agentkernel" "exec" sandbox
                   "--workdir" (if (string=? workdir ".")
                                   "/workspace"
                                   (string-append "/workspace/" workdir))
                   "--")
             argv))
    ((local) argv)
    (else (error "unknown run backend" backend))))

;; spawn has no working-directory option and inherits this process's cwd,
;; which need not be the project root. The shell here only changes directory
;; and execs its positional parameters; argv is never interpolated.
(define (in-directory argv absolute)
  (if (string=? absolute (getcwd))
      argv
      (append (list "/bin/sh" "-c" "cd \"$1\" && shift && exec \"$@\"" "sh" absolute) argv)))

(define (environment-with traceparent)
  (let ((base (filter (lambda (entry) (not (string-prefix? "TRACEPARENT=" entry))) (environ))))
    (if traceparent
        (cons (string-append "TRACEPARENT=" traceparent) base)
        base)))

(define (drain! port sink)
  (let loop ()
    (let ((ready (select (list port) '() '() 0)))
      (when (pair? (car ready))
        (let ((chunk (get-bytevector-some port)))
          (unless (eof-object? chunk)
            (put-bytevector sink chunk)
            (loop)))))))

(define (terminate! pid)
  (kill pid SIGTERM)
  (let loop ((waited 0))
    (let ((reaped (waitpid pid WNOHANG)))
      (cond
       ((not (= 0 (car reaped))) (cdr reaped))
       ((>= waited 2000)
        (kill pid SIGKILL)
        (cdr (waitpid pid)))
       (else (usleep 100000) (loop (+ waited 100)))))))

;; Runs argv with combined output, a deadline, and guaranteed reaping. Output
;; is collected until the child exits; descendants that keep the pipe open
;; cannot stall the turn. Returns (values status code bytes duration-ms) where
;; status is exit, signal, or timeout.
(define (capture-process argv environment timeout-seconds)
  (let-values (((sink get-bytes) (open-bytevector-output-port)))
    (let* ((ends (pipe))
           (in (car ends))
           (started (get-internal-real-time))
           (deadline (+ started (* timeout-seconds internal-time-units-per-second)))
           (pid (spawn (car argv) argv #:output (cdr ends) #:error (cdr ends)
                       #:environment environment))
           (reaped #f))
      (close-port (cdr ends))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (let loop ()
            (let ((ready (select (list in) '() '() 0.25)))
              (when (pair? (car ready))
                (let ((chunk (get-bytevector-some in)))
                  (unless (eof-object? chunk) (put-bytevector sink chunk))))
              (let ((status (waitpid pid WNOHANG)))
                (cond
                 ((not (= 0 (car status)))
                  (set! reaped (cdr status))
                  (drain! in sink)
                  (let ((code (status:exit-val reaped))
                        (signal (status:term-sig reaped)))
                    (values (if signal 'signal 'exit)
                            (or code signal -1)
                            (get-bytes)
                            (elapsed-ms started))))
                 ((> (get-internal-real-time) deadline)
                  (set! reaped (terminate! pid))
                  (drain! in sink)
                  (values 'timeout timeout-seconds (get-bytes) (elapsed-ms started)))
                 (else (loop)))))))
        (lambda ()
          (unless reaped (set! reaped (terminate! pid)))
          (unless (port-closed? in) (close-port in)))))))

(define (elapsed-ms started)
  (quotient (* 1000 (- (get-internal-real-time) started)) internal-time-units-per-second))

(define (bounded-bytes bytes log-path)
  (let ((total (bytevector-length bytes)))
    (if (<= total (+ head-bytes tail-bytes))
        (bytevector->string bytes "UTF-8" 'substitute)
        (let ((head (make-bytevector head-bytes))
              (tail (make-bytevector tail-bytes)))
          (bytevector-copy! bytes 0 head 0 head-bytes)
          (bytevector-copy! bytes (- total tail-bytes) tail 0 tail-bytes)
          (string-append
           (bytevector->string head "UTF-8" 'substitute)
           (format #f "~%…[~a bytes omitted; full output in ~a]~%" (- total head-bytes tail-bytes) log-path)
           (bytevector->string tail "UTF-8" 'substitute))))))

(define (write-log! ledger turn bytes)
  (let* ((directory (string-append (ledger-directory ledger) "/runs"))
         (name (format #f "run-~a-~a.log" turn (+ 1 (length (ledger-runs ledger)))))
         (path (string-append directory "/" name)))
    (unless (file-exists? directory) (mkdir directory))
    (call-with-output-file path
      (lambda (port) (put-bytevector port bytes))
      #:binary #t)
    (string-append "runs/" name)))

;; Files the session had seen whose content changed during the command,
;; so the model re-reads them instead of failing a stale check later.
(define (changed-seen-files ledger root)
  (filter (lambda (path)
            (let ((seen (ledger-seen ledger path)))
              (and seen
                   (not (equal? (car seen) (file-hash (string-append root "/" path)))))))
          (let ((paths (ledger-seen-paths ledger)))
            (if (> (length paths) max-changed-check) (take paths max-changed-check) paths))))

(define (count-lines bytes)
  (let loop ((index 0) (count 0))
    (if (>= index (bytevector-length bytes))
        (if (and (> index 0) (not (= 10 (bytevector-u8-ref bytes (- index 1))))) (+ count 1) count)
        (loop (+ index 1) (if (= 10 (bytevector-u8-ref bytes index)) (+ count 1) count)))))

(define (execute-run arguments root ledger turn context)
  (let-values (((argv workdir absolute timeout) (parse-run-arguments arguments root)))
    (let* ((backend (or (assq-ref context 'backend) 'local))
           (sandbox (assq-ref context 'sandbox))
           (mapped (executed-argv argv workdir backend sandbox))
           (final (if (eq? backend 'local) (in-directory mapped absolute) mapped))
           (environment (environment-with (assq-ref context 'traceparent))))
      (let*-values (((raw-status raw-code raw-bytes duration) (capture-process final environment timeout))
                    ((status code bytes) (if (eq? backend 'agentkernel)
                                             (unwrap-agentkernel-output raw-status raw-code raw-bytes)
                                             (values raw-status raw-code raw-bytes))))
        (let* ((log (write-log! ledger turn bytes))
               (changed (changed-seen-files ledger root))
               (success? (and (eq? status 'exit) (= code 0)))
               (status-text (case status
                              ((exit) (format #f "exit ~a" code))
                              ((signal) (format #f "killed by signal ~a" code))
                              (else (format #f "timeout after ~as (killed)" code))))
               (record
                (json-object
                 (cons "invocation"
                       (json-object (cons "mode" (if (eq? backend 'local) "local" "agentkernel_exec"))
                                    (cons "input" (json-object (cons "command" (apply json-array argv))
                                                               (cons "workdir" workdir)))))
                 (cons "outcome"
                       (json-object (cons "exit_code" (if (eq? status 'exit) code -1))
                                    (cons "success" success?)
                                    (cons "output_sha256" (sha256-bytevector bytes))
                                    (cons "output_bytes" (bytevector-length bytes))
                                    (cons "error" (if (eq? status 'exit) json-null status-text))))
                 (cons "status" (symbol->string status))
                 (cons "duration_ms" duration)
                 (cons "log" log))))
          (ledger-record-run! ledger turn record)
          (make-tool-result
           success?
           (string-append
            (format #f "run ~a · ~a · ~as · ~a lines · log ~a~%"
                    (string-join argv " ") status-text
                    (/ (round (/ duration 100.0)) 10.0) (count-lines bytes) log)
            (if (null? changed)
                ""
                (format #f "files changed since you last read them: ~a~%" (string-join changed ", ")))
            (bounded-bytes bytes log))))))))

(define (error-detail key arguments)
  (catch #t
    (lambda ()
      (if (and (>= (length arguments) 3) (string? (cadr arguments)) (list? (caddr arguments)))
          (apply format #f (cadr arguments) (caddr arguments))
          (format #f "~a: ~s" key arguments)))
    (lambda _ (format #f "~a: ~s" key arguments))))

;; context carries process-owned facts: traceparent, backend, sandbox.
(define* (coding-execute name arguments root ledger turn #:optional (context '()))
  (catch #t
    (lambda ()
      (cond
       ((string=? name "status") (execute-status root ledger turn))
       ((string=? name "diff") (execute-diff arguments root ledger turn))
       ((string=? name "run") (execute-run arguments root ledger turn context))
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
   ((string=? name "run")
    (function-tool
     "run"
     (string-append
      "Run one program with an argv list, no shell: tests, builds, linters, "
      "formatters. Output is combined stdout and stderr, bounded, with the full "
      "log saved. The result reports the exit code, duration, and any files you "
      "had read that the command changed; read those again before editing. "
      "Use run instead of shell whenever the command is a plain argv.")
     (json-object
      (cons "argv"
            (json-object (cons "type" "array")
                         (cons "items" (json-object (cons "type" "string")))
                         (cons "minItems" 1)
                         (cons "description" "Program and arguments, for example [\"cargo\",\"test\"]")))
      (cons "cwd" (string-parameter "Optional project-relative working directory; defaults to the project root"))
      (cons "timeout_seconds"
            (json-object (cons "type" "integer") (cons "minimum" 1) (cons "maximum" max-timeout)
                         (cons "description" "Kill the command after this many seconds; defaults to 120"))))
     '("argv")))
   (else (error "unknown coding tool" name))))
