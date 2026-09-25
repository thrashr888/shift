((pane "beads" "BEADS"
   (text "Ready work across contexts")
   (command "ab" "ready")
   (command "bd" "ready")
   (command "bd" "blocked")
   ;; The action runs a procedure with checks rather than a bare command, so
   ;; picking work leaves a record that says whether it went anywhere.
   (action "Pick up next" (workflow "bead-pickup"))))
