((workflow "card-pick" 1)
 (description "Choose the next card, move it to Doing, and say what the first change is")
 (requires (skill "kanban"))
 (budget (rounds 10))
 (step "read"
   "Read the board with the kanban_board tool. Report what is already in Doing before anything else: if a card is in progress, say so and ask whether to finish that one instead of starting another."
   (check (run "rg" "--no-line-number" "^(#|- )" ".shift/kanban.md")))
 (step "choose"
   "Pick the top card of Todo unless the user asked for a different one, and say why that card and not the one below it. If the board gives you no way to choose between the top two, say that rather than inventing a reason."
   (check (judge "The answer names one card by its id and gives a reason drawn from the board or the user's request, rather than restating the card's title.")))
 (step "move"
   "Move that one card from Todo to Doing by editing .shift/kanban.md, leaving every other card untouched. Then say what the first concrete change will be and which files you expect it to touch."
   (check (run "rg" "--no-line-number" "^## Doing" ".shift/kanban.md"))
   (check (judge "Exactly one card moved to Doing. No other card was reworded, reordered or renumbered."))))
