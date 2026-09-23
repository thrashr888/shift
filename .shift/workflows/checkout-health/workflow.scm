;; Shift's own example workflow: read as data, never evaluated.
;; Run it with /workflow run checkout-health, or unattended:
;;   ./bin/shift-agent --print "/workflow run checkout-health" --mode autopilot
((workflow "checkout-health" 1)
 (description "Say what state this checkout is in and prove it still compiles")
 (budget (rounds 12))
 (step "status"
       "Run git status --short and git log --oneline -3. Then answer in two sentences: is the working tree clean, and what is the last commit's subject?"
       (check (judge "the answer says whether the tree is clean and names the last commit's subject")))
 (step "build"
       "Run make -s build and say in one sentence whether the runtime compiled."
       (check (run "make" "-s" "build"))
       (check (contains "compiled"))))
