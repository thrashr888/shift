;; What every commit in this repo went through by hand: the quality gate,
;; the tree, and a message that says why. Run it before committing.
((workflow "pre-commit" 1)
 (description "Gate a commit: the suite passes, the diff is known, the message says why")
 (budget (rounds 16))
 (step "suite"
       "Run make test as a background job with the job tool (it takes several minutes), wait for it, and report in one sentence whether every suite passed; if not, name the failing suites."
       (check (run "make" "test"))
       (check (judge "the answer says the suite passed or names what failed")))
 (step "diff"
       "Run git status --short and git diff --stat. Answer in two or three sentences: which files changed, and what the change does as a whole."
       (check (judge "the answer names the changed files and what the change does")))
 (step "message"
       "Write a commit message for this change to the note commit.md with the notes tool: a subject under 70 characters in the imperative mood, a blank line, then one paragraph on why the change was made, not what it contains. Then print the message."
       (check (notes "commit.md"))
       (check (judge "the answer contains a commit subject and a paragraph explaining why"))))
