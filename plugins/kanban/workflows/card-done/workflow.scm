((workflow "card-done" 1)
 (description "Verify the work, then move the card out of Doing")
 (requires (skill "kanban"))
 (budget (rounds 20))
 (step "verify"
   "Find this project's test command by inspecting its files, run it, and report the outcome with the failing tests named if any. If it fails, stop here and say the card is not finished; do not move it."
   (check (judge "The answer reports the result of a test command that actually ran in this session, with its outcome, rather than an expectation that it would pass.")))
 (step "review"
   "Show the committed changes for this card with diff and say, in one or two sentences, what they do. Name anything you changed that the card did not ask for."
   (check (judge "The answer describes changes taken from a diff that was actually produced, not from memory of what was intended.")))
 (step "move"
   "Move the card from Doing to Done by editing .shift/kanban.md, leaving every other card untouched. Report the card id and the outcome of the verification that earned the move."
   (check (run "rg" "--no-line-number" "^## Done" ".shift/kanban.md"))
   (check (judge "Exactly one card moved to Done, and the answer ties the move to the test outcome from the first step rather than asserting completion."))))
