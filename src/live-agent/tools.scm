(define-module (live-agent tools)
  #:use-module (srfi srfi-1)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-9)
  #:use-module (live-agent json)
  #:use-module (live-agent redact)
  #:use-module (live-agent sha256)
  #:use-module (live-agent diff)
  #:use-module (live-agent builtins)
  #:export (make-tool-result
            read-roots
            external-tool-schema
            coding-tool-names
            function-tool
            string-parameter
            tool-result?
            tool-result-success?
            tool-result-output
            tool-result-changes
            prepare-change
            prepare-file-change
            commit-change!
            commit-changes!
            resolve-existing-path
            resolve-write-path
            prepared-change?
            prepared-change-tool
            prepared-change-path
            prepared-change-before-text
            prepared-change-before-hash
            prepared-change-after-text
            prepared-change-after-hash
            prepared-change-diff
            prepared-change-diffstat
            prepared-change-summary
            execute-tool
            overflow-sink
            bounded
            tool-schema))

;; `changes` lists what a tool observed or mutated on disk, as alists with a
;; `kind` of seen or mutation, so the runtime ledger never parses prose.
(define-record-type <tool-result>
  (%make-tool-result success? output changes)
  tool-result?
  (success? tool-result-success?)
  (output tool-result-output)
  (changes tool-result-changes))

(define* (make-tool-result success? output #:optional (changes '()))
  ;; Every tool result passes here, so this is where secrets are redacted.
  (%make-tool-result success? (redact output) changes))

;; A mutation is prepared without touching the project, shown for approval,
;; then committed only if the target still matches the prepared pre-image.
(define-record-type <prepared-change>
  (make-prepared-change tool path absolute before-text before-hash
                        after-text after-hash diff summary)
  prepared-change?
  (tool prepared-change-tool)
  (path prepared-change-path)
  (absolute prepared-change-absolute)
  (before-text prepared-change-before-text)
  (before-hash prepared-change-before-hash)
  (after-text prepared-change-after-text)
  (after-hash prepared-change-after-hash)
  (diff prepared-change-diff)
  (summary prepared-change-summary))

(define (prepared-change-diffstat prepared)
  (diffstat (prepared-change-diff prepared)))

(define (relative-path root candidate)
  (if (string=? root candidate)
      "."
      (substring candidate (+ 1 (string-length root)))))

(define (current-file-hash path)
  (and (file-exists? path)
       (not (eq? 'directory (stat:type (stat path))))
       (sha256-file path)))

;; Implemented by the trusted (shift coding) built-in; the names are stable
;; runtime data so ceilings and policy can refer to them even when disabled.
(define coding-tool-names '("status" "diff" "apply_patch" "run" "job"))

(define spawn-lock (make-mutex))
(define max-tool-output (* 64 1024))
(define max-write-input (* 256 1024))
(define max-edit-input (* 512 1024))

;; Output over the cap is written whole to a file and the tool returns a
;; window onto it. Truncating keeps the head and drops the tail, which is
;; where a command usually says why it failed, and the dropped text cannot be
;; recovered without running the command again. A file costs one path in the
;; transcript and leaves everything reachable by `read` and `rg`.
;;
;; The sink takes a label and the full text and returns a project-relative
;; path, or #f when this session has nowhere durable to write. A session
;; without a sink still gets a window; it just has to say the middle is gone.
(define overflow-sink (make-parameter (lambda (label text) #f)))

;; Head and tail together stay well under the cap, so a spilled result is
;; smaller in context than the truncation it replaces.
(define overflow-head (* 24 1024))
(define overflow-tail (* 8 1024))

(define (spill-notice shown total path)
  (if path
      (format #f "~%…[~:d of ~:d chars shown. Full output: ~a — read it, or rg it for what you need.]~%"
              shown total path)
      (format #f "~%…[~:d of ~:d chars shown; the elided middle is not recorded anywhere.]~%"
              shown total)))

(define* (bounded value #:optional (label "output"))
  (let ((total (string-length value)))
    (if (<= total max-tool-output)
        value
        (let ((path (catch #t
                      (lambda () ((overflow-sink) label value))
                      (lambda (key . arguments) #f))))
          (string-append
           (substring value 0 overflow-head)
           (spill-notice (+ overflow-head overflow-tail) total path)
           (substring value (- total overflow-tail)))))))

(define (inside-root? path root)
  (or (string=? path root)
      (string-prefix? (string-append root "/") path)))
;; Schemas for tools the process learned about at runtime (MCP servers);
;; the runtime installs the lookup, and unknown names still error.
(define external-tool-schema (make-parameter (lambda (name) #f)))
;; Directories outside the project that `read` may enter: the process sets
;; this to the valid skill folders, and nothing else widens the boundary.
(define read-roots (make-parameter (lambda () '())))

(define (require-string arguments key)
  (let ((value (json-object-ref arguments key #f)))
    (unless (string? value)
      (error "tool argument must be a string" key))
    value))


;; Inside an agentkernel sandbox the project is mounted at /workspace, and a
;; model that has seen that path in run output uses it. On a host with no
;; /workspace the prefix means the project root.
(define (unalias-workspace requested)
  (cond
   ((not (string? requested)) requested)
   ((file-exists? "/workspace") requested)
   ((string=? requested "/workspace") ".")
   ((string-prefix? "/workspace/" requested) (substring requested 11))
   (else requested)))

(define (resolve-existing-path requested working-directory label)
  (unless (and (string? requested) (not (string-null? requested)))
    (error "path must be a non-empty string" requested))
  (let* ((requested (unalias-workspace requested))
         (root (canonicalize-path working-directory))
         (candidate
          (canonicalize-path
           (if (absolute-file-name? requested)
               requested
               (string-append root "/" requested)))))
    (unless (or (inside-root? candidate root)
                (and (string=? label "read")
                     (let loop ((roots ((read-roots))))
                       (and (pair? roots) (or (inside-root? candidate (car roots)) (loop (cdr roots)))))))
      (error (string-append label " path escapes the project root") requested))
    (list root candidate)))

;; The canonical form of a folder that may not exist yet: the deepest existing
;; ancestor canonicalized, plus the missing segments, none of which may be
;; . or .. (they would defeat the root check).
(define (canonicalize-missing path)
  (let loop ((current path) (tail '()))
    (if (file-exists? current)
        (let ((base (canonicalize-path current)))
          (for-each (lambda (segment)
                      (when (member segment '("" "." ".."))
                        (error "new folders in a write path must be plain names" path)))
                    tail)
          (if (null? tail) base (string-append base "/" (string-join tail "/"))))
        (loop (dirname current) (cons (basename current) tail)))))
(define (resolve-write-path requested working-directory)
  (unless (and (string? requested) (not (string-null? requested)))
    (error "path must be a non-empty string" requested))
  (let* ((requested (unalias-workspace requested))
         (root (canonicalize-path working-directory))
         (unresolved
          (if (absolute-file-name? requested)
              requested
              (string-append root "/" requested)))
         (leaf (basename unresolved))
         (parent (canonicalize-missing (dirname unresolved)))
         (candidate (string-append parent "/" leaf)))
    (unless (inside-root? parent root)
      (error "write path escapes the project root" requested))
    (when (member leaf '("" "." ".."))
      (error "write path must name a file" requested))
    (when (and (file-exists? candidate)
               (not (inside-root? (canonicalize-path candidate) root)))
      (error "write path escapes the project root" requested))
    (list root candidate)))

(define (shell-quote value)
  (call-with-output-string
   (lambda (port)
     (write-char #\' port)
     (string-for-each
      (lambda (character)
        (if (char=? character #\')
            (display "'\\''" port)
            (write-char character port)))
      value)
     (write-char #\' port))))

;; A file larger than the cap is read as a window rather than truncated. The
;; rest stays on disk and the header gives the exact offset that continues it,
;; so nothing needs copying elsewhere to remain reachable.
(define (read-project-file arguments working-directory)
  (let* ((requested (require-string arguments "path"))
         (resolved (resolve-existing-path requested working-directory "read"))
         (root (car resolved))
         (candidate (cadr resolved))
         (offset (let ((value (json-object-ref arguments "offset" 0)))
                   (if (and (integer? value) (>= value 0)) value 0))))
    (let* ((size (stat:size (stat candidate)))
           (content
            (call-with-input-file
                candidate
              (lambda (port)
                (when (> offset 0)
                  (when (>= offset size)
                    (error "read offset is past the end of the file" offset size))
                  ;; An offset this tool reported always lands on a character
                  ;; boundary. One invented by hand may not, and a decode
                  ;; failure here is clearer than a mangled window.
                  (seek port offset SEEK_SET))
                (let ((value (get-string-n port max-tool-output)))
                  (if (eof-object? value) "" value)))))
           (consumed (bytevector-length (string->utf8 content)))
           (next (+ offset consumed))
           (hash (sha256-file candidate))
           (relative (relative-path root candidate)))
      (make-tool-result
       #t
       (string-append
        (format #f "# ~a · ~a bytes · sha256 ~a~a~%"
                relative size (substring hash 0 12)
                (if (or (> offset 0) (< next size))
                    (format #f " · bytes ~:d–~:d" offset next)
                    ""))
        content
        (if (< next size)
            (format #f "~%…[~:d bytes remain; read this path again with offset=~a for the next window]"
                    (- size next) next)
            ""))
       (list `((kind . seen) (path . ,relative) (hash . ,hash)))))))

(define (atomic-write-file path content)
  (let ((temporary
         (string-append (dirname path) "/.shift-write-"
                        (number->string (getpid)) "-XXXXXX")))
    (let* ((port (mkstemp temporary))
           (actual (port-filename port)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (display content port)
          (force-output port)
          (close-port port)
          (rename-file actual path))
        (lambda ()
          (unless (port-closed? port) (close-port port))
          (when (file-exists? actual) (delete-file actual)))))))

;; before #f means the file is created; after #f means it is deleted.
(define (prepare-file-change tool root candidate before after summary)
  (let ((relative (relative-path root candidate)))
    (when (and after (> (string-length after) max-write-input))
      (error "resulting content exceeds the 256 KiB write limit" relative))
    (make-prepared-change
     tool relative candidate
     before (and before (sha256-string before))
     after (and after (sha256-string after))
     (unified-diff before after
                   (string-append "a/" relative) (string-append "b/" relative))
     summary)))

(define finish-change prepare-file-change)

(define (prepare-write arguments working-directory)
  (let* ((requested (require-string arguments "path"))
         (content (require-string arguments "content"))
         (resolved (resolve-write-path requested working-directory))
         (root (car resolved))
         (candidate (cadr resolved)))
    (when (> (string-length content) max-write-input)
      (error "write content exceeds the 256 KiB limit" (string-length content)))
    (when (and (file-exists? candidate)
               (eq? 'directory (stat:type (stat candidate))))
      (error "write path is a directory" requested))
    (finish-change
     "write" root candidate
     (and (file-exists? candidate)
          (call-with-input-file candidate get-string-all))
     content
     (format #f "wrote ~a chars to ~a" (string-length content) requested))))

(define (occurrence-count text fragment)
  (let loop ((start 0) (count 0))
    (let ((index (string-contains text fragment start)))
      (if index
          (loop (+ index (string-length fragment)) (+ count 1))
          count))))

(define (replace-occurrences text old-text new-text)
  (let ((port (open-output-string)))
    (let loop ((start 0))
      (let ((index (string-contains text old-text start)))
        (if index
            (begin
              (display (substring text start index) port)
              (display new-text port)
              (loop (+ index (string-length old-text))))
            (display (substring text start) port))))
    (get-output-string port)))

(define (prepare-edit arguments working-directory)
  (let* ((requested (require-string arguments "path"))
         (old-text (require-string arguments "old_text"))
         (new-text (require-string arguments "new_text"))
         (replace-all? (json-object-ref arguments "replace_all" #f))
         (resolved (resolve-existing-path requested working-directory "edit"))
         (root (car resolved))
         (candidate (cadr resolved))
         (size (stat:size (stat candidate))))
    (when (string-null? old-text)
      (error "old_text cannot be empty"))
    (when (> size max-edit-input)
      (error "edit file exceeds the 512 KiB limit" size))
    (let* ((content (call-with-input-file candidate get-string-all))
           (count (occurrence-count content old-text))
           (loose (and (= count 0) (not replace-all?) (loose-window content old-text))))
      (when (and (= count 0) (not loose))
        (error (string-append "old_text was not found in " requested (nearest-line-hint content old-text))))
      (when (and (> count 1) (not replace-all?))
        (error "old_text is ambiguous; set replace_all to true" count))
      (let ((updated (if loose
                         (string-append (substring content 0 (car loose))
                                        (reindent new-text (cadr loose) (caddr loose))
                                        (substring content (cadddr loose)))
                         (replace-occurrences content old-text new-text))))
        (when (> (string-length updated) max-write-input)
          (error "edited content exceeds the 256 KiB write limit"
                 (string-length updated)))
        (finish-change
         "edit" root candidate content updated
         (if loose
             (format #f "edited 1 occurrence in ~a (matched ignoring surrounding whitespace)" requested)
             (format #f "edited ~a occurrence~a in ~a"
                     count (if (= count 1) "" "s") requested)))))))

;; When old_text is not in the file verbatim, one window of lines that
;; matches after trimming each line is still an unambiguous target: models
;; drop or add indentation far more often than they misremember words.
;; Returns (start file-indent old-indent end) as character offsets, or #f.
(define (loose-window content old-text)
  (let* ((old-lines (let ((ls (string-split old-text #\newline)))
                      (if (and (> (length ls) 1) (string-null? (last ls))) (drop-right ls 1) ls)))
         (wanted (map string-trim-both old-lines))
         (lines (string-split content #\newline))
         (n (length wanted)))
    (and (pair? wanted) (not (every string-null? wanted)) (<= n (length lines))
         (let loop ((i 0) (offset 0) (rest lines) (found '()))
           (if (< (- (length lines) i) n)
               (and (= (length found) 1)
                    (let* ((start (caar found)) (window (take (list-tail lines (cdar found)) n))
                           (end (+ start (apply + (map string-length window)) (- n 1)))
                           ;; old_text ending in a newline replaces the file's newline too.
                           (end (if (and (string-suffix? "\n" old-text) (< end (string-length content))) (+ end 1) end)))
                      (list start (leading-space (car window)) (leading-space (car old-lines)) end)))
               (let ((match? (every (lambda (a b) (string=? (string-trim-both a) b)) (take rest n) wanted)))
                 (loop (+ i 1) (+ offset (string-length (car rest)) 1) (cdr rest)
                       (if match? (cons (cons offset i) found) found))))))))
(define (leading-space line)
  (substring line 0 (- (string-length line) (string-length (string-trim line)))))
(define (reindent text file-indent old-indent)
  (if (string=? file-indent old-indent) text
      (string-join
       (map (lambda (line)
              (if (and (not (string-null? line)) (string-prefix? old-indent line))
                  (string-append file-indent (substring line (string-length old-indent)))
                  line))
            (string-split text #\newline))
       "\n")))
(define (nearest-line-hint content old-text)
  (let* ((first (find (lambda (l) (not (string-null? l))) (map string-trim-both (string-split old-text #\newline))))
         (lines (string-split content #\newline))
         (at (and first (list-index (lambda (l) (string-contains l first)) lines))))
    (cond ((not first) "")
          (at (format #f "; its first line appears at line ~a, read that region and retry with the exact text" (+ at 1)))
          (else "; none of its first line appears in the file, read the file again"))))

(define (prepare-change name arguments working-directory)
  (cond
   ((string=? name "write") (prepare-write arguments working-directory))
   ((string=? name "edit") (prepare-edit arguments working-directory))
   (else (error "tool does not prepare file changes" name))))

;; A new file may sit in a folder that does not exist yet; the path was
;; already confined to the project root, so its parents are created here.
(define (ensure-parent! path)
  (let ((parent (dirname path)))
    (unless (file-exists? parent)
      (ensure-parent! parent)
      (mkdir parent))))
(define (put-content! absolute text)
  (if text
      (begin (ensure-parent! absolute) (atomic-write-file absolute text))
      (when (file-exists? absolute) (delete-file absolute))))

(define (check-unchanged! prepared)
  (unless (equal? (current-file-hash (prepared-change-absolute prepared))
                  (prepared-change-before-hash prepared))
    (error "file changed since the change was prepared; read it again and retry"
           (prepared-change-path prepared))))

(define (change-record prepared)
  (let ((stat (prepared-change-diffstat prepared)))
    `((kind . mutation)
      (tool . ,(prepared-change-tool prepared))
      (path . ,(prepared-change-path prepared))
      (before . ,(prepared-change-before-hash prepared))
      (after . ,(prepared-change-after-hash prepared))
      (added . ,(car stat))
      (removed . ,(cdr stat))
      (diff . ,(prepared-change-diff prepared)))))

(define (change-line prepared)
  (string-append (prepared-change-summary prepared) " "
                 (format-diffstat (prepared-change-diffstat prepared))))

;; Every target is re-hashed before any write. A failure part-way restores
;; the files already written, so a multi-file patch is all or nothing.
(define (commit-changes! changes)
  (for-each check-unchanged! changes)
  (let loop ((remaining changes) (done '()))
    (if (null? remaining)
        (let ((records (map change-record changes)))
          (make-tool-result
           #t
           (if (= 1 (length changes))
               (change-line (car changes))
               (string-append
                (format #f "applied ~a files ~a~%" (length changes)
                        (format-diffstat
                         (cons (apply + (map (lambda (r) (assq-ref r 'added)) records))
                               (apply + (map (lambda (r) (assq-ref r 'removed)) records)))))
                (string-join (map (lambda (p) (string-append "  " (change-line p))) changes) "\n")))
           records))
        (let ((prepared (car remaining)))
          (catch #t
            (lambda ()
              (put-content! (prepared-change-absolute prepared)
                            (prepared-change-after-text prepared)))
            (lambda (key . arguments)
              (for-each (lambda (applied)
                          (put-content! (prepared-change-absolute applied)
                                        (prepared-change-before-text applied)))
                        done)
              (apply throw key arguments)))
          (loop (cdr remaining) (cons prepared done))))))

(define (commit-change! prepared)
  (commit-changes! (list prepared)))

(define (run-rg arguments working-directory)
  (let* ((query (require-string arguments "query"))
         (requested (json-object-ref arguments "path" "."))
         (glob (json-object-ref arguments "glob" #f))
         (regex? (json-object-ref arguments "regex" #f)))
    (when (string-null? query) (error "rg query cannot be empty"))
    (unless (string? requested) (error "rg path must be a string"))
    (unless (or (not glob) (string? glob))
      (error "rg glob must be a string"))
    (unless (boolean? regex?)
      (error "rg regex must be a boolean"))
    (let* ((resolved (resolve-existing-path requested working-directory "rg"))
           (root (car resolved))
           (candidate (cadr resolved))
           (arguments
            (append
             '("--line-number" "--color=never" "--no-heading"
               "--max-count" "200" "--max-filesize" "1M")
             (if regex? '() '("--fixed-strings"))
             (if glob (list "--glob" glob) '())
             (list "--" query candidate)))
           (error-template
            (string-append "/tmp/shift-rg-error-"
                           (number->string (getpid)) "-XXXXXX"))
           (error-port (mkstemp error-template))
           (error-path (port-filename error-port))
           (result
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                ;; Parallel prefetch runs rg from several threads; spawning
                ;; concurrently has produced exec failures (exit 127) with
                ;; no stderr, so spawns are serialized and retried once.
                (let* ((run (lambda ()
                              (let* ((port (with-mutex spawn-lock
                                             (with-error-to-port error-port
                                               (lambda () (apply open-pipe* OPEN_READ "rg" arguments)))))
                                     (output (get-string-all port)))
                                (cons output (close-pipe port)))))
                       (first (run))
                       (attempt (if (eqv? 127 (status:exit-val (cdr first))) (begin (usleep 50000) (run)) first))
                       (output (car attempt))
                       (status (cdr attempt)))
                  (force-output error-port)
                  (seek error-port 0 SEEK_SET)
                  (list output (get-string-all error-port)
                        (status:exit-val status))))
              (lambda ()
                (unless (port-closed? error-port) (close-port error-port))
                (when (file-exists? error-path) (delete-file error-path)))))
           (output (car result))
           (error-output (cadr result))
           (exit-code (caddr result)))
      (cond
       ((= exit-code 0)
        (bounded
         (replace-occurrences output (string-append root "/") "")
         "rg"))
       ((= exit-code 1) "No matches.")
       (else
        (error
         (if regex?
             "rg regular expression is invalid or rg failed"
             "rg failed")
         exit-code
         (bounded
          (if (string-null? error-output) output error-output)
          "rg")))))))

(define (run-shell arguments working-directory policy confirm)
  (let ((command (json-object-ref arguments "command")))
    (when (eq? policy 'deny)
      (error "shell capability is denied by the live image"))
    (unless (and (eq? policy 'ask) (confirm command))
      (error "shell command was not approved"))
    (let* ((wrapped
            (string-append "cd "
                           (shell-quote working-directory)
                           " && " command " 2>&1"))
           (port (open-pipe* OPEN_READ "/bin/zsh" "-lc" wrapped))
           (output (get-string-all port))
           (status (close-pipe port))
           (exit-code (status:exit-val status)))
      (format #f "exit=~a~%~a" exit-code (bounded output "shell")))))

(define (execute-tool name arguments working-directory shell-policy confirm)
  (catch #t
    (lambda ()
      (let ((value
             (cond
              ((string=? name "read")
               (read-project-file arguments working-directory))
              ((string=? name "rg")
               (run-rg arguments working-directory))
              ((or (string=? name "write") (string=? name "edit"))
               (commit-change! (prepare-change name arguments working-directory)))
              ((string=? name "shell")
               (run-shell arguments working-directory shell-policy confirm))
              (else (error "tool is not implemented" name)))))
        (if (tool-result? value) value (make-tool-result #t value))))
    (lambda (key . args)
      (make-tool-result #f (format #f "tool error (~a): ~s" key args)))))

(define (function-tool name description properties required)
  (json-object
   (cons "type" "function")
   (cons "function"
         (json-object
          (cons "name" name)
          (cons "description" description)
          (cons "parameters"
                (json-object
                 (cons "type" "object")
                 (cons "properties" properties)
                 (cons "required" (apply json-array required))
                 (cons "additionalProperties" #f)))))))

(define (string-parameter description)
  (json-object (cons "type" "string") (cons "description" description)))

(define (tool-schema name)
  (cond
   ((string=? name "ui")
    (function-tool "ui"
      "Inspect or change your live terminal UI without restarting. Actions get, patch, undo, reload, save. Get returns valid keys, theme_path, config, revision. Patch accepts only UI preference keys; identity replaces the theme label, branding replace replaces shift. Themes acid, paddock, blueprint or a custom Scheme data pack. Placement left/right/top/bottom/modal; sidebar auto/on/off; density compact/comfortable. Colors are ANSI indices 0..255. Saving a valid theme_path edit hot-reloads it. UI preferences persist for this session; save promotes them to user or project scope. UI changes do not change tool permissions."
      (json-object (cons "action" (string-parameter "get, patch, undo, reload, save"))
                   (cons "patch" (json-object (cons "type" "object")
                                              (cons "description" "UI keys returned by get, with replacement values")))
                   (cons "scope" (string-parameter "user or project, for save"))) '("action")))
   ((string=? name "tool_search")
    (function-tool
     "tool_search"
     "Find tools on the session's MCP servers. Pass a few words about what you need, or select:SERVER__TOOL for exact names. Matching tools (up to 8) become callable for the rest of this turn; call them by the returned names."
     (json-object (cons "query" (string-parameter "Words to match against tool names and descriptions, or select:NAME,NAME")))
     '("query")))
   ((string=? name "skill")
    (function-tool
     "skill"
     "Search skills by a few words, or load one by name. The system prompt lists the names; a search says what each covers. Load a skill before following it."
     (json-object (cons "query" (string-parameter "Words about the task, to see which skills cover it"))
                  (cons "name" (string-parameter "Skill name to load"))
                  (cons "path" (string-parameter "Optional file inside the skill folder, such as references/api.md")))
     '()))
   ((string=? name "read")
    (function-tool
     "read"
     "Read one exact UTF-8 text file inside the current project. Try the most likely path first; only try another path if it fails."
     (json-object (cons "path" (string-parameter "Project-relative file path"))
                  ;; The window itself reports the offset that continues it, so
                  ;; the schema carries the parameter and not the instructions.
                  (cons "offset"
                        (json-object
                         (cons "type" "integer")
                         (cons "minimum" 0)
                         (cons "description" "Byte offset to resume an oversized read from"))))
     '("path")))
   ((string=? name "rg")
    (function-tool
     "rg"
     (string-append
      "Search project text with ripgrep without invoking a shell. Queries are "
      "literal by default, so punctuation such as Scheme parentheses is safe. "
      "For Guile module imports, search the literal forms #:use-module and "
      "(use-modules separately. "
      "Set regex to true only when regular-expression behavior is intentional. "
      "Results are bounded and project-confined.")
     (json-object
      (cons "query" (string-parameter "Text to find; interpreted literally unless regex is true"))
      (cons "path" (string-parameter "Optional project-relative file or directory; defaults to ."))
      (cons "glob" (string-parameter "Optional ripgrep glob such as *.scm"))
      (cons "regex"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Interpret query as a regular expression; defaults to false"))))
     '("query")))
   ((string=? name "write")
    (function-tool
     "write"
     "Atomically create or replace one UTF-8 text file inside the project. Parent directories must already exist."
     (json-object
      (cons "path" (string-parameter "Project-relative file path"))
      (cons "content" (string-parameter "Complete new file content")))
     '("path" "content")))
   ((string=? name "edit")
    (function-tool
     "edit"
     "Atomically edit one project text file by exact replacement. By default old_text must occur exactly once."
     (json-object
      (cons "path" (string-parameter "Project-relative file path"))
      (cons "old_text" (string-parameter "Exact text to replace"))
      (cons "new_text" (string-parameter "Replacement text"))
      (cons "replace_all"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Replace every occurrence; defaults to false"))))
     '("path" "old_text" "new_text")))
   ((string=? name "shell")
    (json-object
     (cons "type" "function")
     (cons "function"
           (json-object
            (cons "name" "shell")
            (cons "description"
                  (string-append
                   "Run a shell command after explicit user approval. Use only "
                   "when read cannot accomplish the task; do not use shell to "
                   "discover or read a conventional project file."))
            (cons "parameters"
                  (json-object
                   (cons "type" "object")
                   (cons "properties"
                         (json-object
                          (cons "command"
                                (json-object
                                 (cons "type" "string")
                                 (cons "description" "Command to run from the project root")))))
                   (cons "required" (json-array "command"))
                   (cons "additionalProperties" #f)))))))
   ((string=? name "live_eval")
    (function-tool
     "live_eval"
     (string-append
      "Transactionally change your live Scheme behavior. Before calling, explain "
      "to the user what binding will change, why, and the expected effect. Top-level "
      "forms are limited to define, define*, set!, or begin and may target only "
      "agent-* or extension-* bindings. The next user turn sees the generation; "
      "/rollback undoes it. After the result, explain the before/after generations "
      "and whether the expected behavior was achieved or still needs a retry.")
     (json-object
      (cons "expression"
            (string-parameter "One or more restricted Scheme definitions or assignments"))
      (cons "summary"
            (string-parameter "Plain-language description of exactly what changes"))
      (cons "expected_behavior"
            (string-parameter "Observable behavior expected on the next user turn")))
     '("expression" "summary" "expected_behavior")))
   ((string=? name "traces")
    (function-tool
     "traces"
     (string-append
      "Inspect this running session's own completed trace spans. Use this to "
      "verify tool outcomes, errors, generation identity, context selection, "
      "compaction, and cancellation instead of trusting narration. Results "
      "are session-scoped and bounded. Search the complete durable trace after "
      "compaction, then fetch an exact span_id when full stored attributes are needed.")
     (json-object
      (cons "query"
            (json-object
             (cons "type" "string")
             (cons "maxLength" 256)
             (cons "description" "Case-insensitive literal search across stored span JSON")))
      (cons "span_id"
            (json-object
             (cons "type" "string")
             (cons "maxLength" 256)
             (cons "description" "Exact span ID to retrieve with full stored attributes")))
      (cons "name" (string-parameter "Exact span name filter, such as agent.turn"))
      (cons "kind" (string-parameter "Exact OpenInference kind filter"))
      (cons "status" (string-parameter "Exact status filter"))
      (cons "generation"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)))
      (cons "turn"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)))
      (cons "limit"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)
             (cons "maximum" 50)
             (cons "description" "Most recent spans to return; defaults to 12")))
      (cons "errors_only"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Only return ERROR or CANCELLED spans"))))
     '()))
   ((string=? name "notes")
    (function-tool
     "notes"
     (string-append
      "Your working notes for this session: files under the session's notes folder, never in the "
      "project. They survive context resets; when the window fills, the harness asks you to save "
      "progress, decisions, unresolved work and exact paths here, then resets to a fresh window "
      "that lists these files. Read them first in a new window. Actions: list, read, write, append.")
     (json-object
      (cons "action" (string-parameter "list, read, write, or append"))
      (cons "path" (string-parameter "Notes-relative file name such as plan.md (read, write, append)"))
      (cons "text" (string-parameter "Content to write or append")))
     '("action")))
   ((string=? name "workflow")
    (function-tool
     "workflow"
     (string-append
      "Durable multi-step procedures under .shift/workflows/NAME/workflow.scm, each step a prompt with checks. "
      "Actions: list (names, descriptions, last run), show NAME (steps, checks, recent runs), "
      "run NAME (starts the workflow in a subagent session and returns its job id; the run's record "
      "lands under .shift/workflows/NAME/runs/).")
     (json-object
      (cons "action" (string-parameter "list, show, or run"))
      (cons "name" (string-parameter "Workflow name (show, run)")))
     '("action")))
   ((string=? name "recall")
    (function-tool
     "recall"
     (string-append
      "Search the traces of every session in this project, including subagent "
      "sessions, for what happened before: past tool outcomes, errors, runs and "
      "answers. Literal, case-insensitive, newest first, bounded. Each hit names "
      "its session; use traces with span_id inside that session for full detail.")
     (json-object
      (cons "query"
            (json-object
             (cons "type" "string")
             (cons "maxLength" 256)
             (cons "description" "Case-insensitive literal search across stored span JSON")))
      (cons "session" (string-parameter "Only this session, or sessions under it (default/agents/tests)"))
      (cons "name" (string-parameter "Exact span name filter, such as tool.run"))
      (cons "kind" (string-parameter "Exact OpenInference kind filter"))
      (cons "status" (string-parameter "Exact status filter"))
      (cons "limit"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 1)
             (cons "maximum" 30)
             (cons "description" "Newest hits to return; defaults to 8")))
      (cons "errors_only"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Only return ERROR or CANCELLED spans"))))
     '("query")))
   ((string=? name "spawn")
    (function-tool
     "spawn"
     (string-append
      "Start a subagent on a task in the background and return at once. The child "
      "is a full session in an agents/ folder under this one, with this session's "
      "generation, patches, mode, project, skills and servers. Its stdout is its "
      "answer: use the job tool (wait, output, cancel) with the returned id. Spawn "
      "several in one turn to work in parallel. Children run unattended, so in "
      "manual mode they can only read, search and run allowlisted commands.")
     (json-object
      (cons "task" (string-parameter "The complete task, with everything the child needs to know"))
      (cons "name" (string-parameter "Short folder name, [A-Za-z0-9][A-Za-z0-9._-]*; defaults to agent-N"))
      (cons "tools"
            (json-object
             (cons "type" "array")
             (cons "items" (json-object (cons "type" "string")))
             (cons "description" "Narrower tool list for the child; defaults to this session's tools and can never widen them")))
      (cons "history"
            (json-object
             (cons "type" "boolean")
             (cons "description" "Copy this conversation into the child; default false starts it fresh with only the task")))
      (cons "model" (string-parameter "PROVIDER/MODEL override for the child"))
      (cons "timeout_seconds"
            (json-object
             (cons "type" "integer")
             (cons "minimum" 30)
             (cons "maximum" 3600)
             (cons "description" "Kill the child after this long; defaults to 600"))))
     '("task")))
   ((string=? name "extension")
    (function-tool
     "extension"
     (string-append
      "Manage persistent Scheme extension artifacts. Actions: list; create a named "
      "artifact from expression without enabling it; load it into a new generation; "
      "disable its exact patch; or export all active live patches under a name. "
      "Explain user-visible changes before create, load, disable, or export.")
     (json-object
      (cons "action"
            (json-object
             (cons "type" "string")
             (cons "enum" (json-array "list" "create" "load" "disable" "export"))))
      (cons "name" (string-parameter "Artifact name for actions other than list"))
      (cons "expression"
            (string-parameter "Restricted Scheme patch required by create"))
      (cons "description"
            (string-parameter "Short purpose recorded in the artifact header")))
     '("action")))
   ((and (member name coding-tool-names) (builtin-enabled? 'coding))
    ((builtin-ref 'coding 'coding-tool-schema) name))
   (((external-tool-schema) name) => (lambda (schema) schema))
   (else (error "unknown live tool" name))))
