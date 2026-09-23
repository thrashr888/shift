(use-modules (srfi srfi-64) (srfi srfi-1) (ice-9 textual-ports)
             (live-agent json) (live-agent workflow) (live-agent improve))
(test-begin "improve")
(define project (mkdtemp "/tmp/shift-improve-XXXXXX"))
(mkdir (string-append project "/.shift"))
(define (message-content m) (json-object-ref m "content" ""))

;; Field notes.
(define events
  '(("run" "{\"argv\":\"cat a | sed -n 1p\"}" #f "tool failed: argv must be a non-empty list of strings; shell syntax such as pipes is refused")
    ("read" "{\"path\":\"/logs/x\"}" #f "tool failed (misc-error): read path escapes the project root")
    ("run" "{\"argv\":[\"make\",\"test\"]}" #f "exit=2\nmake: *** [test] Error 1")
    ("read" "{\"path\":\"a\"}" #t "contents")
    ("run" "{\"argv\":\"cat a | sed -n 1p\"}" #f "tool failed: argv must be a non-empty list of strings; shell syntax such as pipes is refused")))
(test-equal "only harness rejections become notes, once each"
  '("run: tool failed: argv must be a non-empty list of strings; shell syntax such as pipes is refused"
    "read: tool failed (misc-error): read path escapes the project root")
  (field-note-candidates events))
(test-equal "no notes, no block" "" (field-notes-block project))
(test-equal "appending writes the skill folder" 2 (field-notes-append! project (field-note-candidates events) "session default, turn 3"))
(test-assert "the file is a disabled skill with provenance"
  (let ((text (call-with-input-file (field-notes-file project) get-string-all)))
    (and (string-contains text "name: field-notes") (string-contains text "disable-model-invocation: true")
         (string-contains text "(session default, turn 3)"))))
(test-equal "the same quirk again adds nothing" 0 (field-notes-append! project (field-note-candidates events) "session other, turn 9"))
(test-equal "a new quirk adds one" 1 (field-notes-append! project '("edit: tool failed: no unique match") "session other, turn 9"))
(test-assert "the prompt block carries the notes without provenance"
  (let ((block (field-notes-block project)))
    (and (string-prefix? "\n\n<field-notes>" block) (string-contains block "- run: tool failed: argv")
         (not (string-contains block "(session")))))
(test-equal "the notes are capped at forty, oldest dropped" 40
  (begin (field-notes-append! project (map (lambda (i) (format #f "tool~a: quirk ~a" i i)) (iota 45)) "session cap, turn 1")
         (length (field-notes-lines project))))
(test-assert "the newest note survives the cap" (string-contains (field-notes-block project) "tool44: quirk 44"))

;; Hard turns.
(test-equal "an easy turn has no flags" '() (turn-flags "ok" #f '(("read" "{}" #t "x"))))
(test-equal "a limit is a flag" '("ended at a limit") (turn-flags "failed" "round limit reached after 40 rounds" '()))
(test-equal "one repeat is routine, two are a flag" '(() ("2 repeated calls"))
  (let ((x '("rg" "{\"query\":\"x\"}" #t "a")) (y '("rg" "{\"query\":\"y\"}" #t "b")))
    (list (turn-flags "ok" #f (list x x y)) (turn-flags "ok" #f (list x x x y)))))
(test-equal "three rejections are a flag, two are not" '(("3 tool rejections") ())
  (let ((r (lambda (i) (list "run" (format #f "{\"argv\":~a}" i) #f "tool failed: shape"))))
    (list (turn-flags "ok" #f (list (r 1) (r 2) (r 3))) (turn-flags "ok" #f (list (r 1) (r 2))))))
(test-assert "hard-turn? reads the flags" (and (hard-turn? '("ended at a limit")) (not (hard-turn? '()))))

;; Reflection.
(let ((messages (reflection-messages "fix the tests" '("ended at a limit" "2 repeated calls") events)))
  (test-equal "reflection is one system and one user message" '("system" "user") (map (lambda (m) (json-object-ref m "role" "")) messages))
  (test-assert "the user message carries the request, the flags and the rejected calls"
    (let ((text (message-content (cadr messages))))
      (and (string-contains text "fix the tests") (string-contains text "ended at a limit; 2 repeated calls")
           (string-contains text "REJECTED: tool failed: argv")))))
(test-equal "a note proposal parses" '(note "run takes argv as a JSON array; pipes need [\"sh\",\"-c\",\"...\"]")
  (let ((p (reflection-parse "{\"kind\":\"note\",\"note\":\"run takes argv as a JSON array; pipes need [\\\"sh\\\",\\\"-c\\\",\\\"...\\\"]\",\"why\":\"two rounds lost\"}")))
    (list (assq-ref p 'kind) (assq-ref p 'note))))
(test-equal "a skill proposal parses with its parts" '(skill "run-the-suite" "How to run the suite" "1. make test")
  (let ((p (reflection-parse "Here: {\"kind\":\"skill\",\"name\":\"run-the-suite\",\"description\":\"How to run the suite\",\"body\":\"1. make test\",\"why\":\"repeats\"}")))
    (list (assq-ref p 'kind) (assq-ref p 'name) (assq-ref p 'description) (assq-ref p 'body))))
(test-equal "none parses" 'none (assq-ref (reflection-parse "{\"kind\":\"none\",\"why\":\"the task was hard\"}") 'kind))
(test-assert "a bad skill name or missing body is not a proposal"
  (and (not (reflection-parse "{\"kind\":\"skill\",\"name\":\"../x\",\"body\":\"b\"}"))
       (not (reflection-parse "{\"kind\":\"skill\",\"name\":\"ok\"}"))
       (not (reflection-parse "no json here"))))
(test-assert "applying a note appends it"
  (string-contains (reflection-apply! project '((kind . note) (note . "edit needs the exact old text") (why . "x")) "session s, turn 2") "noted"))
(test-assert "applying a skill writes a disabled SKILL.md"
  (let ((line (reflection-apply! project '((kind . skill) (name . "run-the-suite") (description . "How to run the suite") (body . "1. make test") (why . "repeats")) "session s, turn 2")))
    (and (string-contains line "proposed skill run-the-suite (disabled)")
         (let ((text (call-with-input-file (string-append project "/.shift/skills/run-the-suite/SKILL.md") get-string-all)))
           (and (string-contains text "name: run-the-suite") (string-contains text "disable-model-invocation: true")
                (string-contains text "Proposed by reflection (session s, turn 2): repeats") (string-contains text "1. make test"))))))
(test-assert "an existing skill is never overwritten"
  (string-contains (reflection-apply! project '((kind . skill) (name . "run-the-suite") (description . "d") (body . "other") (why . "w")) "p") "which exists"))
(test-equal "none reports its reason" "reflection: no durable fix (the task was hard)"
  (reflection-apply! project '((kind . none) (why . "the task was hard")) "p"))

;; Distillation.
(define ok-read '("read" "{\"path\":\"a\"}" #t "contents"))
(define (reads n) (map (lambda (i) (list "read" (format #f "{\"path\":\"f~a\"}" i) #t "x")) (iota n)))
(test-assert "eight clean calls on an ok turn are worth distilling" (clean-tool-heavy? "ok" (reads 8)))
(test-assert "seven are not, nor a failed turn, nor a turn with a rejection"
  (and (not (clean-tool-heavy? "ok" (reads 7)))
       (not (clean-tool-heavy? "failed" (reads 8)))
       (not (clean-tool-heavy? "ok" (cons '("run" "{}" #f "tool error: shape") (reads 8))))))
(test-assert "the distillation prompt carries the task, the calls and the answer"
  (let ((text (message-content (cadr (distillation-messages "add a flag" (reads 3) "Added --verbose.")))))
    (and (string-contains text "add a flag") (string-contains text "- read {\"path\":\"f2\"} → x") (string-contains text "Added --verbose."))))
(test-equal "a distillation is a skill or nothing, never a note" '(skill none #f)
  (list (assq-ref (distillation-parse "{\"kind\":\"skill\",\"name\":\"add-a-flag\",\"body\":\"steps\"}") 'kind)
        (assq-ref (distillation-parse "{\"kind\":\"none\",\"why\":\"one-off\"}") 'kind)
        (distillation-parse "{\"kind\":\"note\",\"note\":\"x\"}")))
(test-assert "a distilled skill names its origin"
  (let ((line (reflection-apply! project '((kind . skill) (name . "add-a-flag") (description . "Add a CLI flag") (body . "1. edit") (why . "repeats")) "session s, turn 4" "distillation")))
    (and (string-contains line "distillation: proposed skill add-a-flag (disabled)")
         (string-contains (call-with-input-file (string-append project "/.shift/skills/add-a-flag/SKILL.md") get-string-all) "Proposed by distillation (session s, turn 4)"))))
(test-equal "nothing worth keeping says so" "distillation: nothing worth keeping (one-off)"
  (reflection-apply! project '((kind . none) (why . "one-off")) "p" "distillation"))

;; Improvement.
(define (mkdirs path) (unless (file-exists? path) (mkdirs (dirname path)) (mkdir path)))
(mkdirs (string-append project "/.shift/workflows/site-check"))
(define original "((workflow \"site-check\" 1)\n (step \"check\" \"Run the checker.\" (check (judge \"the answer states the checker's verdict\"))))")
(call-with-output-file (workflow-file project "site-check") (lambda (p) (display original p)))
(define failed-run (json-read "{\"workflow\":\"site-check\",\"version\":1,\"session\":\"s\",\"started\":\"2026-09-22T02:00:00Z\",\"status\":\"failed\",\"rounds\":2,\"steps\":[{\"name\":\"check\",\"status\":\"failed\",\"rounds\":2,\"checks\":[{\"kind\":\"judge\",\"text\":\"the answer states the checker's verdict\",\"ok\":false,\"detail\":\"does not hold (confidence 0.40)\"}]}],\"error\":null}"))
(test-assert "the improvement prompt shows the file and the failed check"
  (let ((text (message-content (cadr (improve-messages original (list failed-run))))))
    (and (string-contains text original) (string-contains text "✗ judge the answer states the checker's verdict · does not hold"))))
(test-equal "a proposal parses" '("Reword the claim" "((workflow \"site-check\" 2) (step \"check\" \"Run it.\" (check (contains \"passed\"))))")
  (let ((p (improve-parse "{\"change\":\"Reword the claim\",\"workflow\":\"((workflow \\\"site-check\\\" 2) (step \\\"check\\\" \\\"Run it.\\\" (check (contains \\\"passed\\\"))))\"}")))
    (list (assq-ref p 'change) (assq-ref p 'workflow))))
(test-equal "none is a proposal of nothing" "none" (assq-ref (improve-parse "{\"change\":\"none\"}") 'change))
(test-equal "the candidate is renamed for its own folder and back"
  "((workflow \"site-check-candidate\" 2) (step \"a\" \"b\"))"
  (candidate-text "((workflow \"site-check\" 2) (step \"a\" \"b\"))" "site-check" "site-check-candidate"))
(define (run status rounds) (json-object (cons "status" status) (cons "rounds" rounds)))
(test-equal "compare: resolved beats failed" 'keep (car (compare-runs (run "failed" 2) (run "resolved" 3))))
(test-equal "compare: an unresolved candidate is discarded" 'discard (car (compare-runs (run "failed" 2) (run "budget" 9))))
(test-equal "compare: both resolved, fewer or equal rounds keeps" '(keep discard)
  (list (car (compare-runs (run "resolved" 4) (run "resolved" 4))) (car (compare-runs (run "resolved" 4) (run "resolved" 5)))))
(define candidate "((workflow \"site-check-candidate\" 2)\n (step \"check\" \"Run it.\" (check (contains \"passed\"))))")
(test-assert "promotion rotates the old file into versions and installs the candidate under its own name"
  (begin (promote-candidate! project "site-check" 1 candidate)
         (and (equal? (call-with-input-file (string-append project "/.shift/workflows/site-check/versions/1.scm") get-string-all) original)
              (equal? (workflow-version (workflow-read project "site-check")) 2)
              (equal? (workflow-name (workflow-read project "site-check")) "site-check"))))
(test-assert "a candidate under the wrong name changes nothing"
  (and (catch #t (lambda () (promote-candidate! project "site-check" 2 "((workflow \"other\" 3) (step \"a\" \"b\"))") #f) (lambda _ #t))
       (equal? (workflow-version (workflow-read project "site-check")) 2)))
(test-assert "promoting a plugin's workflow writes a project override and keeps the plugin text as the version"
  (let ((plugin-dir (string-append project "/plugin-workflows")))
    (mkdirs (string-append plugin-dir "/callers"))
    (call-with-output-file (string-append plugin-dir "/callers/workflow.scm") (lambda (p) (display "((workflow \"callers\" 1) (step \"a\" \"from the plugin\"))" p)))
    (workflows-init! project (list (cons "plugin:demo" plugin-dir)))
    (promote-candidate! project "callers" 1 "((workflow \"callers-candidate\" 2) (step \"a\" \"improved\"))")
    (and (equal? (workflow-source (workflow-read project "callers")) "project")
         (equal? (workflow-version (workflow-read project "callers")) 2)
         (string-contains (call-with-input-file (string-append project "/.shift/workflows/callers/versions/1.scm") get-string-all) "from the plugin"))))
(test-assert "rejection keeps the candidate beside the versions"
  (string-suffix? "/versions/3-rejected.scm" (reject-candidate! project "site-check" 2 candidate)))
(improve-log! project "site-check" (json-object (cons "at" "2026-09-22T03:00:00Z") (cons "kept" #t) (cons "change" "Reword the claim")))
(test-equal "the log reads back" "Reword the claim" (json-object-ref (car (improve-log project "site-check")) "change"))
(test-end "improve")
