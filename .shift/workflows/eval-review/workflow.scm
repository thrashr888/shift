;; Dogfood: review every session in this project and keep the hard turns.
((workflow "eval-review" 1)
 (description "Review every session's turns and note the hard ones")
 (budget (rounds 12))
 (step "review"
       "Run python3 scripts/evals.py session --all. Then write the note review.md with the notes tool: one line per turn that ended at a limit, repeated a tool call, or had tool errors, naming the session, the turn and the flag. End with one sentence on the most common flag."
       (check (notes "review.md"))
       (check (judge "the answer or the note names at least one session and its flagged turn")))
 (step "summary"
       "Read the note review.md and answer in two sentences: which flag is most common, and which session deserves a look first."
       (check (contains "session"))))
