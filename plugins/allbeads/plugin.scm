((plugin "allbeads" "0.2")
 (description "Issue beads across repositories with ab and bd")
 (requires (command "ab") (command "bd"))
 (skills "skills")
 (panes "panes.scm")
 (workflows "workflows")
 ;; The skill still teaches the two CLIs, because they have far more verbs
 ;; than are worth declaring. These two are the ones a session reaches for by
 ;; name, so they get a schema instead of prose the model re-derives every
 ;; time it wants an issue id.
 (tool "beads_ready"
   (description "List unblocked work in this repository, highest priority first.")
   (resident)
   (run "bd" "ready"))
 (tool "beads_show"
   (description "Show one issue with its dependencies, status and comments.")
   (parameter "issue" string "Issue id as bd prints it, such as shift-c4l")
   (run "bd" "show" "{issue}"))
 (allow-run ("ab" "ready") ("ab" "list") ("ab" "show") ("ab" "blocked") ("ab" "search") ("ab" "stats")
            ("bd" "ready") ("bd" "list") ("bd" "show") ("bd" "blocked") ("bd" "search") ("bd" "stats")))
