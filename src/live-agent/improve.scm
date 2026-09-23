;; The self-improvement loop's pure parts (docs/workflows-rfc.md): field notes
;; the harness appends after a turn, the facts that make a turn hard, the
;; reflection exchange that proposes one durable fix as a disabled artifact,
;; and the workflow improvement that is kept only when a measured comparison
;; says so. Nothing here talks to a model or runs a turn; main.scm does that
;; and hands the results in.
(define-module (live-agent improve)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (live-agent json)
  #:use-module (live-agent provider)
  #:use-module (live-agent workflow)
  #:export (field-notes-file field-note-candidates field-notes-append! field-notes-block field-notes-lines
            turn-flags hard-turn?
            reflection-messages reflection-parse reflection-apply!
            clean-tool-heavy? distillation-messages distillation-parse
            improve-messages improve-parse candidate-text compare-runs
            promote-candidate! reject-candidate! improve-log! improve-log
            runs-summary skill-folder))

(define max-notes 40)
(define max-note-chars 160)
(define max-block-bytes (* 8 1024))
(define rejections-for-hard 3)
(define calls-for-distillation 8)
(define repeats-for-hard 2)   ; extra identical calls: two identical reads are routine, three are not

;; --- field notes ----------------------------------------------------------------
;; A skill folder the harness writes and people edit. disable-model-invocation
;; keeps it out of the skill tool's list: every turn's system prompt carries
;; it instead, so a quirk recorded once is known in the next session.
(define (skill-folder project name) (string-append project "/.shift/skills/" name))
(define (field-notes-file project) (string-append (skill-folder project "field-notes") "/SKILL.md"))
(define field-notes-header
  (string-append "---\nname: field-notes\n"
                 "description: Tool quirks this project's sessions hit. Shift appends one line per harness rejection; edit or delete lines freely.\n"
                 "disable-model-invocation: true\n---\n"))

(define (first-line text)
  (let ((line (car (string-split text #\newline))))
    (if (> (string-length line) max-note-chars) (string-append (substring line 0 max-note-chars) "…") line)))

;; A rejection is the harness refusing a call, never a command that merely
;; exited non-zero: those prefixes are the runtime's own.
(define (rejection? output)
  (and (string? output)
       (any (lambda (prefix) (string-prefix? prefix output))
            '("tool failed" "tool error" "tool unavailable" "the arguments for"))))

;; events: ((tool arguments-json ok? output) ...) in call order → note lines, distinct.
(define (field-note-candidates events)
  (delete-duplicates
   (filter-map (lambda (event)
                 (let ((tool (car event)) (ok? (caddr event)) (output (cadddr event)))
                   (and (not ok?) (rejection? output)
                        (string-append tool ": " (first-line output)))))
               events)
   string=?))

(define (note-text line)
  ;; "- TEXT (session S, turn N)" → TEXT, so the same quirk is one line however often it recurs.
  (let* ((body (if (string-prefix? "- " line) (substring line 2) line))
         (open (string-rindex body #\()))
    (if (and open (string-suffix? ")" body) (string-prefix? "(session " (substring body open)))
        (string-trim-right (substring body 0 open))
        body)))

(define (field-notes-lines project)
  (let ((path (field-notes-file project)))
    (if (file-exists? path)
        (let* ((text (call-with-input-file path get-string-all))
               (parts (string-split text #\newline)))
          (filter (lambda (l) (string-prefix? "- " l)) parts))
        '())))

;; Appends NOTES not already present; keeps the newest max-notes. Returns how many were added.
(define (field-notes-append! project notes provenance)
  (let* ((existing (field-notes-lines project))
         (known (map note-text existing))
         (fresh (filter (lambda (n) (not (member n known))) notes)))
    (if (null? fresh)
        0
        (let* ((added (map (lambda (n) (string-append "- " n " (" provenance ")")) fresh))
               (all (append existing added))
               (kept (if (> (length all) max-notes) (list-tail all (- (length all) max-notes)) all))
               (folder (skill-folder project "field-notes")))
          (unless (file-exists? (dirname folder)) (mkdir (dirname folder)))
          (unless (file-exists? folder) (mkdir folder))
          (call-with-output-file (field-notes-file project)
            (lambda (p) (display field-notes-header p) (display (string-join kept "\n") p) (newline p)))
          (length fresh)))))

(define (field-notes-block project)
  (let ((lines (field-notes-lines project)))
    (if (null? lines)
        ""
        (let ((body (string-join (map note-text lines) "\n- " 'prefix)))
          (string-append "\n\n<field-notes>\nTool quirks earlier sessions of this project hit; the fix is in each line.\n"
                         (if (> (string-length body) max-block-bytes) (substring body 0 max-block-bytes) body)
                         "\n</field-notes>")))))

;; --- hard turns -------------------------------------------------------------------
;; status: the receipt's status string; error: its error text or #f.
(define (turn-flags status error events)
  (let* ((limit? (or (equal? status "limited")
                     (and (string? error) (or (string-contains error "limit") (string-contains error "budget")))))
         (calls (map (lambda (e) (cons (car e) (cadr e))) events))
         (repeated (fold + 0 (map (lambda (c) (- (count (lambda (o) (equal? o c)) calls) 1)) (delete-duplicates calls))))
         (rejections (count (lambda (e) (and (not (caddr e)) (rejection? (cadddr e)))) events)))
    (append (if limit? '("ended at a limit") '())
            (if (>= repeated repeats-for-hard) (list (format #f "~a repeated call~a" repeated (if (= repeated 1) "" "s"))) '())
            (if (>= rejections rejections-for-hard) (list (format #f "~a tool rejections" rejections)) '()))))

(define (hard-turn? flags) (pair? flags))

;; --- distillation ---------------------------------------------------------------
;; The other half of the loop: a turn that used many tools and ended clean, or
;; a workflow run that resolved, holds a procedure worth keeping. One exchange
;; asks the model to write it as a skill, proposed disabled like everything else.
(define (clean-tool-heavy? status events)
  (and (equal? status "ok")
       (>= (length events) calls-for-distillation)
       (not (any (lambda (e) (and (not (caddr e)) (rejection? (cadddr e)))) events))))
(define distillation-system
  (string-append
   "You are reviewing a piece of your own coding work that went well, to decide whether the procedure is worth keeping as a "
   "skill: a short SKILL.md another session of this project could follow to do the same kind of task again without "
   "rediscovering the commands, the files and the order. Keep only what generalizes: the steps, the commands that worked, "
   "what to verify, the pitfalls. Leave out anything specific to this one request. Propose none when the work was a one-off "
   "or the steps are obvious. Reply with one JSON object: {\"kind\": \"skill\" | \"none\", \"name\": \"lowercase-hyphenated\", "
   "\"description\": \"one line saying what it does and when to use it\", \"body\": \"markdown steps\", \"why\": \"one sentence\"}."))
(define (distillation-messages request events answer)
  (list
   (make-message "system" distillation-system)
   (make-message "user"
     (string-append
      "THE TASK:\n" (clip request 800)
      "\n\nTHE TOOL CALLS, IN ORDER (name, arguments, outcome):\n"
      (string-join
       (map (lambda (e) (string-append "- " (car e) " " (clip (cadr e) 160) " → " (if (caddr e) (clip (first-line (cadddr e)) 80) "failed")))
            (let ((n (length events))) (if (> n 60) (list-tail events (- n 60)) events)))
       "\n")
      "\n\nTHE FINAL ANSWER:\n" (clip answer 1200)))))
;; Skill or none; a note is not a distillation.
(define (distillation-parse text)
  (let ((p (reflection-parse text)))
    (and p (memq (assq-ref p 'kind) '(skill none)) p)))

;; --- reflection -------------------------------------------------------------------
(define reflection-system
  (string-append
   "You are reviewing one turn of your own coding session that went badly, to propose ONE durable fix, or none. "
   "A fix is either a field note (one line, under 160 characters, stating a tool's argument shape or a project quirk "
   "and the correct way, useful in any future session of this project) or a skill (a short SKILL.md procedure for a "
   "task this project repeats). Propose none when the trouble was the task itself, the model's reasoning, or something "
   "a note would not prevent. Reply with one JSON object: {\"kind\": \"note\" | \"skill\" | \"none\", \"note\": \"...\", "
   "\"name\": \"lowercase-hyphenated\", \"description\": \"one line\", \"body\": \"markdown steps\", \"why\": \"one sentence\"}."))

(define (clip text n)
  (let ((t (if (string? text) text "")))
    (if (> (string-length t) n) (string-append (substring t 0 n) "…") t)))

(define (reflection-messages request flags events)
  (list
   (make-message "system" reflection-system)
   (make-message "user"
     (string-append
      "THE REQUEST:\n" (clip request 600)
      "\n\nWHAT WENT WRONG: " (string-join flags "; ")
      "\n\nTHE TURN'S TOOL CALLS (name, arguments, outcome):\n"
      (string-join
       (map (lambda (e) (string-append "- " (car e) " " (clip (cadr e) 200) " → " (if (caddr e) "ok" (string-append "REJECTED: " (clip (first-line (cadddr e)) 200)))))
            (let ((n (length events))) (if (> n 30) (list-tail events (- n 30)) events)))
       "\n")))))

(define (safe-name? name)
  (and (string? name) (<= 1 (string-length name) 64) (char-alphabetic? (string-ref name 0))
       (string-every (lambda (c) (or (char-lower-case? c) (char-numeric? c) (char=? c #\-))) name)))

(define (json-in text)
  (let* ((t (if (string? text) text "")) (open (string-index t #\{)) (close (string-rindex t #\})))
    (and open close (< open close)
         (catch #t (lambda () (let ((o (json-read (substring t open (+ close 1))))) (and (json-object? o) o))) (lambda _ #f)))))

;; → ((kind . note) (note . TEXT) (why . TEXT)), ((kind . skill) (name . N) (description . D) (body . B) (why . W)),
;;   ((kind . none) (why . W)), or #f when the reply was not a proposal.
(define (reflection-parse text)
  (let ((object (json-in text)))
    (and object
         (let ((kind (json-object-ref object "kind" "")) (why (let ((w (json-object-ref object "why" ""))) (if (string? w) w ""))))
           (cond
            ((and (equal? kind "note") (string? (json-object-ref object "note" #f))
                  (not (string-null? (string-trim-both (json-object-ref object "note" "")))))
             `((kind . note) (note . ,(first-line (string-trim-both (json-object-ref object "note" "")))) (why . ,why)))
            ((and (equal? kind "skill") (safe-name? (json-object-ref object "name" #f))
                  (string? (json-object-ref object "body" #f)) (not (string-null? (string-trim-both (json-object-ref object "body" "")))))
             `((kind . skill) (name . ,(json-object-ref object "name" "")) (description . ,(first-line (let ((d (json-object-ref object "description" ""))) (if (string? d) d ""))))
               (body . ,(string-trim-both (json-object-ref object "body" ""))) (why . ,why)))
            ((equal? kind "none") `((kind . none) (why . ,why)))
            (else #f))))))

;; Writes the proposal as a disabled artifact and returns one line for the
;; transcript. A skill folder that exists is never overwritten.
(define* (reflection-apply! project proposal provenance #:optional (label "reflection"))
  (case (assq-ref proposal 'kind)
    ((note)
     (let ((added (field-notes-append! project (list (assq-ref proposal 'note)) (string-append label ", " provenance))))
       (if (> added 0)
           (string-append label ": noted \"" (assq-ref proposal 'note) "\" in .shift/skills/field-notes")
           (string-append label ": proposed a note that was already there"))))
    ((skill)
     (let* ((name (assq-ref proposal 'name)) (folder (skill-folder project name)))
       (if (file-exists? folder)
           (string-append label ": proposed skill " name ", which exists; nothing written")
           (begin
             (unless (file-exists? (dirname folder)) (mkdir (dirname folder)))
             (mkdir folder)
             (call-with-output-file (string-append folder "/SKILL.md")
               (lambda (p)
                 (format p "---\nname: ~a\ndescription: ~a\ndisable-model-invocation: true\n---\n" name (assq-ref proposal 'description))
                 (format p "<!-- Proposed by ~a (~a): ~a. Remove disable-model-invocation to offer it. -->\n\n" label provenance (assq-ref proposal 'why))
                 (display (assq-ref proposal 'body) p) (newline p)))
             (string-append label ": proposed skill " name " (disabled) in .shift/skills/" name "; /skills lists it")))))
    (else (string-append label ": " (if (string=? label "reflection") "no durable fix" "nothing worth keeping")
                         (let ((w (assq-ref proposal 'why))) (if (and (string? w) (not (string-null? w))) (string-append " (" w ")") ""))))))

;; --- workflow improvement -----------------------------------------------------------
(define improve-system
  (string-append
   "You maintain a workflow file for a coding agent: a Scheme data file of steps, each a prompt for one turn with checks "
   "(run PROGRAM ARG...) exit 0, (contains TEXT) in the answer, (file PATH), (notes NAME), (judge CLAIM) judged against the "
   "answer literally. Given the file and its recent runs, propose ONE change that would make the next run resolve in fewer "
   "rounds or pass a check it failed: reword a prompt so the answer contains what a check needs, tighten or loosen a check "
   "that fails on a correct answer, split or merge steps, or adjust the budget. Keep the workflow's name; raise its version "
   "by one. Reply with one JSON object: {\"change\": \"one sentence\", \"workflow\": \"the whole new file\"} or "
   "{\"change\": \"none\"} when no change is warranted."))

(define (runs-summary runs)
  (string-join
   (map (lambda (run)
          (string-append
           (json-object-ref run "started" "") " " (json-object-ref run "status" "") " in " (number->string (json-object-ref run "rounds" 0)) " rounds"
           (string-join
            (map (lambda (st)
                   (string-append "\n  step " (json-object-ref st "name" "") ": " (json-object-ref st "status" "")
                                  (string-join (map (lambda (c) (string-append "\n    " (if (json-object-ref c "ok" #f) "✓" "✗") " " (json-object-ref c "kind" "") " "
                                                                                (json-object-ref c "text" "") " · " (json-object-ref c "detail" "")))
                                                    (json-array-items (json-object-ref st "checks" (json-array))))
                                               "")))
                 (json-array-items (json-object-ref run "steps" (json-array))))
            "")))
        runs)
   "\n"))

(define (improve-messages workflow-text runs)
  (list (make-message "system" improve-system)
        (make-message "user" (string-append "THE WORKFLOW FILE:\n" workflow-text "\n\nRECENT RUNS, newest first:\n" (runs-summary runs)))))

;; → ((change . TEXT) (workflow . TEXT)) or ((change . "none")) or #f.
(define (improve-parse text)
  (let ((object (json-in text)))
    (and object
         (let ((change (json-object-ref object "change" #f)) (workflow (json-object-ref object "workflow" #f)))
           (cond
            ((equal? change "none") '((change . "none")))
            ((and (string? change) (string? workflow) (not (string-null? (string-trim-both workflow))))
             `((change . ,(first-line change)) (workflow . ,workflow)))
            (else #f))))))

;; The candidate runs under its own folder, so its head names that folder.
(define (candidate-text text from to)
  (let ((needle (string-append "(workflow \"" from "\"")))
    (let ((at (string-contains text needle)))
      (unless at (error "the candidate must start with (workflow NAME VERSION)" from))
      (string-append (substring text 0 at) "(workflow \"" to "\"" (substring text (+ at (string-length needle)))))))

;; Two run records (JSON objects) → (keep|discard . reason). A candidate is
;; kept only when it resolved and did so in no more rounds than the baseline.
(define (compare-runs baseline candidate)
  (let ((b-ok (equal? (json-object-ref baseline "status" "") "resolved"))
        (c-ok (equal? (json-object-ref candidate "status" "") "resolved"))
        (b-rounds (json-object-ref baseline "rounds" 0))
        (c-rounds (json-object-ref candidate "rounds" 0)))
    (cond
     ((not c-ok) (cons 'discard (format #f "the candidate did not resolve (~a)" (json-object-ref candidate "status" ""))))
     ((not b-ok) (cons 'keep (format #f "the candidate resolved in ~a rounds where the baseline ~a" c-rounds (json-object-ref baseline "status" ""))))
     ((<= c-rounds b-rounds) (cons 'keep (format #f "both resolved; ~a rounds against ~a" c-rounds b-rounds)))
     (else (cons 'discard (format #f "both resolved but the candidate took ~a rounds against ~a" c-rounds b-rounds))))))

(define (versions-dir project name) (string-append (workflow-root project) "/" name "/versions"))
(define (ensure-versions! project name)
  (let ((dir (versions-dir project name)))
    (let make ((path dir)) (unless (file-exists? path) (make (dirname path)) (mkdir path)))
    dir))

;; The current file becomes versions/V.scm and the candidate (renamed back) the workflow.
;; The promoted file always lands in the project folder: for a plugin's or the
;; user's workflow that is a project override, and versions/V.scm keeps the text
;; it replaced wherever it came from.
(define (promote-candidate! project name version text)
  (let* ((dir (ensure-versions! project name)) (file (workflow-file project name))
         (promoted (candidate-text text (string-append name "-candidate") name))   ; fails before anything moves
         (located (or (workflow-locate name project) (error "no such workflow" name)))
         (current (call-with-input-file (cdr located) get-string-all)))
    (call-with-output-file (string-append dir "/" (number->string version) ".scm") (lambda (p) (display current p)))
    (call-with-output-file file (lambda (p) (display promoted p)))
    file))

(define (reject-candidate! project name version text)
  (let* ((dir (ensure-versions! project name)) (path (string-append dir "/" (number->string (+ version 1)) "-rejected.scm")))
    (call-with-output-file path (lambda (p) (display (candidate-text text (string-append name "-candidate") name) p)))
    path))

(define (improve-log! project name record)
  (let ((dir (ensure-versions! project name)))
    (let ((port (open-file (string-append dir "/log.jsonl") "a")))
      (display (json-write record) port) (newline port) (close-port port))))

(define (improve-log project name)
  (let ((path (string-append (versions-dir project name) "/log.jsonl")))
    (if (file-exists? path)
        (filter-map (lambda (line) (catch #t (lambda () (and (not (string-null? line)) (json-read line))) (lambda _ #f)))
                    (string-split (call-with-input-file path get-string-all) #\newline))
        '())))
