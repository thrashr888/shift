((workflow "bead-pickup" 1)
 (description "Choose the next unblocked issue and start it with its context loaded")
 (requires (skill "allbeads"))
 (budget (rounds 12))
 (step "ready"
   "List the unblocked work with the beads_ready tool. Report the issues it returns, highest priority first, and say which repository each belongs to. If nothing is ready, say so and stop."
   (check (run "bd" "ready")))
 (step "choose"
   "Pick the issue that best fits what the user asked for, or the highest-priority one if they did not say. Show it with beads_show and report its dependencies, what it blocks, and anything its comments already settled."
   (check (run "bd" "ready")))
 (step "plan"
   "Say what the first concrete change for that issue is, naming the files you expect to touch, and what would show it worked. Do not make the change yet."))
