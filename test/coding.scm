(use-modules (srfi srfi-64) (ice-9 textual-ports)
             (live-agent json) (live-agent tools) (live-agent changes) (live-agent sha256) (shift coding))

(test-begin "coding")

(define (write-file! root path text)
  (call-with-output-file (string-append root "/" path) (lambda (port) (display text port))))
(define (mutate! ledger root turn path before after)
  (write-file! root path after)
  (ledger-commit! ledger (ledger-begin! ledger turn "call" "edit" path before after)))
(define (output result) (tool-result-output result))
(define (args . pairs) (apply json-object pairs))

(test-assert "status and diff have provider schemas"
  (and (json-object? (coding-tool-schema "status")) (json-object? (coding-tool-schema "diff"))))
(test-assert "tool schema lookup reaches the built-in"
  (json-object? (tool-schema "diff")))

;; A project without git
(define plain (string-append "/tmp/shift-coding-plain-" (number->string (getpid))))
(system* "mkdir" "-p" (string-append plain "/state"))
(define plain-ledger (open-ledger (string-append plain "/state")))
(write-file! plain "a.txt" "one\n")
(mutate! plain-ledger plain 3 "a.txt" "one\n" "one\ntwo\n")
(ledger-commit! plain-ledger (ledger-begin! plain-ledger 4 "call" "write" "b.txt" #f "fresh\n"))
(write-file! plain "b.txt" "fresh\n")

(define plain-status (coding-execute "status" (args) plain plain-ledger 4))
(test-assert "status works without git"
  (and (tool-result-success? plain-status)
       (string-contains (output plain-status) "not a git repository")))
(test-assert "status separates this turn from the session"
  (and (string-contains (output plain-status) "changed this turn (turn 4): (+1 −0)")
       (string-contains (output plain-status) "  b.txt (+1 −0)")
       (string-contains (output plain-status) "changed this session: 2 files in turns 3, 4")
       (string-contains (output plain-status) "  a.txt (+1 −0) turn 3")))
(test-assert "turn diff covers only the current turn"
  (let ((text (output (coding-execute "diff" (args) plain plain-ledger 4))))
    (and (string-contains text "1 file changed (+1 −0)")
         (string-contains text "+++ b/b.txt")
         (not (string-contains text "b/a.txt")))))
(test-assert "session diff covers every turn"
  (let ((text (output (coding-execute "diff" (args (cons "scope" "session")) plain plain-ledger 4))))
    (and (string-contains text "2 files changed") (string-contains text "+two"))))
(test-assert "paths restrict the diff"
  (let ((text (output (coding-execute "diff" (args (cons "scope" "session")
                                                  (cons "paths" (json-array "a.txt")))
                                      plain plain-ledger 4))))
    (and (string-contains text "+two") (not (string-contains text "b.txt")))))
(test-assert "diff reflects later external edits against the pre-image"
  (begin
    (write-file! plain "a.txt" "one\nthree\n")
    (string-contains (output (coding-execute "diff" (args (cons "scope" "session")) plain plain-ledger 4))
                     "+three")))
(test-assert "an empty scope says so"
  (string-contains (output (coding-execute "diff" (args) plain plain-ledger 9)) "No changes in scope turn."))
(test-assert "git scope fails clearly outside a checkout"
  (let ((result (coding-execute "diff" (args (cons "scope" "git")) plain plain-ledger 4)))
    (and (not (tool-result-success? result))
         (string-contains (output result) "not a git repository"))))
(test-assert "escaping paths are rejected"
  (not (tool-result-success?
        (coding-execute "diff" (args (cons "paths" (json-array "../x"))) plain plain-ledger 4))))
(test-assert "unknown scopes are rejected"
  (not (tool-result-success? (coding-execute "diff" (args (cons "scope" "all")) plain plain-ledger 4))))

;; A dirty git checkout
(define repo (string-append "/tmp/shift-coding-git-" (number->string (getpid))))
(system* "mkdir" "-p" (string-append repo "/.shift"))
(write-file! repo "tracked.txt" "v1\n")
(write-file! repo "theirs.txt" "user work\n")
(system* "git" "-C" repo "init" "-q")
(system* "git" "-C" repo "-c" "user.name=t" "-c" "user.email=t@example.com" "add" ".")
(system* "git" "-C" repo "-c" "user.name=t" "-c" "user.email=t@example.com" "commit" "-q" "-m" "base")
(write-file! repo "theirs.txt" "user work\nuser edit\n")
;; The ledger lives under the project's .shift/, which status must not count as dirt.
(define repo-ledger (open-ledger (string-append repo "/.shift")))
(mutate! repo-ledger repo 2 "tracked.txt" "v1\n" "v2\n")

(define repo-status (coding-execute "status" (args) repo repo-ledger 2))
(test-assert "status reports the branch and dirty count"
  (and (string-prefix? "git " (output repo-status))
       (string-contains (output repo-status) "dirty files")))
(test-assert "status lists user changes shift did not touch"
  (and (string-contains (output repo-status) "not touched by shift: 1")
       (string-contains (output repo-status) "  theirs.txt")
       (string-contains (output repo-status) "  tracked.txt (+1 −1)")))
(test-assert "git diff includes the user's own change"
  (let ((text (output (coding-execute "diff" (args (cons "scope" "git")) repo repo-ledger 2))))
    (and (string-contains text "against HEAD") (string-contains text "+user edit") (string-contains text "+v2"))))
(test-assert "session diff excludes the user's own change"
  (let ((text (output (coding-execute "diff" (args (cons "scope" "session")) repo repo-ledger 2))))
    (and (string-contains text "+v2") (not (string-contains text "user edit")))))

;; apply_patch preparation
(write-file! plain "p1.txt" "one\ntwo\n")
(write-file! plain "p2.txt" "alpha\n")
(define (prepare-patch text) (coding-prepare (args (cons "patch" text)) plain))
(define good
  (string-append "--- a/p1.txt\n+++ b/p1.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
                 "--- a/p2.txt\n+++ b/p2.txt\n@@ -1 +1,2 @@\n alpha\n+beta\n"))
(define prepared (prepare-patch good))
(test-equal "a two-file patch prepares two changes" '("p1.txt" "p2.txt")
  (map prepared-change-path prepared))
(test-assert "prepared patch changes carry diffs and hashes"
  (and (string-contains (prepared-change-diff (car prepared)) "+TWO")
       (string? (prepared-change-before-hash (car prepared)))
       (equal? "alpha\nbeta\n" (prepared-change-after-text (cadr prepared)))))
(test-equal "preparation writes nothing" "one\ntwo\n"
  (call-with-input-file (string-append plain "/p1.txt") get-string-all))
(test-error "a mismatch in the second file rejects the whole patch" #t
  (prepare-patch (string-append "--- a/p1.txt\n+++ b/p1.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
                                "--- a/p2.txt\n+++ b/p2.txt\n@@ -1 +1 @@\n-omega\n+beta\n")))
(test-error "creating an existing file is rejected" #t
  (prepare-patch "--- /dev/null\n+++ b/p1.txt\n@@ -0,0 +1 @@\n+x\n"))
(test-error "patch paths cannot escape the project" #t
  (prepare-patch "--- /dev/null\n+++ b/../escape.txt\n@@ -0,0 +1 @@\n+x\n"))
(test-error "touching a path twice is rejected" #t
  (prepare-patch (string-append "--- a/p2.txt\n+++ b/p2.txt\n@@ -1 +1 @@\n-alpha\n+a\n"
                                "--- a/p2.txt\n+++ b/p2.txt\n@@ -1 +1 @@\n-alpha\n+b\n")))
(test-error "a delete must remove every line" #t
  (prepare-patch "--- a/p1.txt\n+++ /dev/null\n@@ -1,2 +1,1 @@\n one\n-two\n"))
(define deletion (prepare-patch "--- a/p2.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-alpha\n"))
(test-assert "a delete prepares a change with no post-image"
  (and (= 1 (length deletion)) (not (prepared-change-after-hash (car deletion)))))
(define rename (prepare-patch "--- a/p2.txt\n+++ b/p3.txt\n@@ -1 +1 @@\n-alpha\n+ALPHA\n"))
(test-equal "a rename becomes a delete plus a create" '("p2.txt" "p3.txt")
  (map prepared-change-path rename))
(test-assert "the rename's create carries the patched text"
  (equal? "ALPHA\n" (prepared-change-after-text (cadr rename))))
(test-error "non-string patches are rejected" #t (coding-prepare (args (cons "patch" 5)) plain))
(test-assert "apply_patch has a provider schema" (json-object? (coding-tool-schema "apply_patch")))

;; run
(define (run-tool arguments) (coding-execute "run" arguments plain plain-ledger 7))
(define echo-run (run-tool (args (cons "argv" (json-array "sh" "-c" "echo out; echo err 1>&2; exit 0")))))
(test-assert "run captures combined output and exit 0"
  (and (tool-result-success? echo-run)
       (string-contains (output echo-run) "run sh -c echo out; echo err 1>&2; exit 0 · exit 0 ·")
       (string-contains (output echo-run) "2 lines · log runs/run-7-1.log")
       (string-contains (output echo-run) "out\nerr\n")))
(test-assert "the full log is on disk"
  (equal? "out\nerr\n" (call-with-input-file (string-append plain "/state/runs/run-7-1.log") get-string-all)))
(define failing (run-tool (args (cons "argv" (json-array "sh" "-c" "echo boom; exit 3")))))
(test-assert "non-zero exit is a failed result that still carries output"
  (and (not (tool-result-success? failing))
       (string-contains (output failing) "· exit 3 ·")
       (string-contains (output failing) "boom")))
(define timed-out (run-tool (args (cons "argv" (json-array "sh" "-c" "echo start; sleep 30; echo never"))
                                  (cons "timeout_seconds" 1))))
(test-assert "timeouts kill the child and report distinctly"
  (and (not (tool-result-success? timed-out))
       (string-contains (output timed-out) "timeout after 1s (killed)")
       (string-contains (output timed-out) "\nstart\n")
       (not (string-contains (output timed-out) "\nnever"))))
(test-assert "a child that exits while a grandchild holds the pipe does not stall"
  (let ((started (get-internal-real-time))
        (result (run-tool (args (cons "argv" (json-array "sh" "-c" "sleep 20 & echo parent-done"))
                                (cons "timeout_seconds" 10)))))
    (and (tool-result-success? result)
         (string-contains (output result) "parent-done")
         (< (- (get-internal-real-time) started) (* 5 internal-time-units-per-second)))))
(system* "mkdir" "-p" (string-append plain "/sub"))
(define in-sub (run-tool (args (cons "argv" (json-array "pwd")) (cons "cwd" "sub"))))
(test-assert "cwd runs inside the requested project directory"
  (and (tool-result-success? in-sub) (string-contains (output in-sub) "/sub\n")))
(test-assert "cwd cannot escape the project"
  (not (tool-result-success? (run-tool (args (cons "argv" (json-array "pwd")) (cons "cwd" "../"))))))
(test-assert "argv must be a non-empty string array"
  (and (not (tool-result-success? (run-tool (args (cons "argv" (json-array))))))
       (not (tool-result-success? (run-tool (args (cons "argv" "ls")))))))
(test-assert "timeouts are bounded"
  (not (tool-result-success? (run-tool (args (cons "argv" (json-array "true")) (cons "timeout_seconds" 9999))))))
(define big (run-tool (args (cons "argv" (json-array "sh" "-c" "i=0; while [ $i -lt 9000 ]; do echo line-$i-0123456789; i=$((i+1)); done")))))
(test-assert "large output keeps the head and tail and points at the log"
  (and (tool-result-success? big)
       (string-contains (output big) "line-0-")
       (string-contains (output big) "line-8999-")
       (string-contains (output big) "bytes omitted; full output in runs/")
       (< (string-length (output big)) (* 70 1024))))
(test-assert "invalid UTF-8 output is substituted, not fatal"
  (tool-result-success? (run-tool (args (cons "argv" (json-array "sh" "-c" "printf 'ok\\377\\n'"))))))
(test-assert "the traceparent reaches the child environment"
  (string-contains
   (output (coding-execute "run" (args (cons "argv" (json-array "sh" "-c" "echo $TRACEPARENT")))
                           plain plain-ledger 7 '((traceparent . "00-abc-def-01") (backend . local))))
   "00-abc-def-01"))
(ledger-observe! plain-ledger 7 "watched.txt" (sha256-string "before\n"))
(write-file! plain "watched.txt" "before\n")
(define rewriting (run-tool (args (cons "argv" (json-array "sh" "-c" "echo after > watched.txt")))))
(test-assert "files seen earlier that a command rewrote are reported"
  (let ((text (output rewriting)))
    (and (string-contains text "files changed since you last read them:")
         (string-contains text "watched.txt"))))
(test-assert "runs are journaled with agentkernel-shaped outcomes"
  (let* ((runs (ledger-runs plain-ledger))
         (first-run (car runs))
         (outcome (json-object-ref first-run "outcome")))
    (and (>= (length runs) 8)
         (equal? 0 (json-object-ref outcome "exit_code"))
         (eq? #t (json-object-ref outcome "success"))
         (equal? (sha256-string "out\nerr\n") (json-object-ref outcome "output_sha256"))
         (equal? 8 (json-object-ref outcome "output_bytes"))
         (equal? "local" (json-object-ref (json-object-ref first-run "invocation") "mode")))))
(test-assert "status reports the last run"
  (string-contains (output (coding-execute "status" (args) plain plain-ledger 7)) "last run (turn 7): sh -c echo after > watched.txt · exit 0"))
(test-assert "runs survive ledger replay"
  (= (length (ledger-runs plain-ledger)) (length (ledger-runs (open-ledger (string-append plain "/state"))))))
(test-equal "the agentkernel backend wraps argv with exec and a workspace path"
  '("agentkernel" "exec" "box" "--workdir" "/workspace/crates/x" "--" "cargo" "test")
  (executed-argv '("cargo" "test") "crates/x" 'agentkernel "box"))
(test-equal "the project root maps to /workspace"
  "/workspace" (list-ref (executed-argv '("ls") "." 'agentkernel "box") 4))
(test-error "the agentkernel backend needs a sandbox name" #t (executed-argv '("ls") "." 'agentkernel #f))
(test-assert "run has a provider schema" (json-object? (coding-tool-schema "run")))

(system* "rm" "-rf" plain repo)
(test-end "coding")
