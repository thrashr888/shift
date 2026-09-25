;; One command renders the whole board: per-column commands would each need
;; their own pinned allowlist entry, and ripgrep's context flags bleed into the
;; next heading anyway. With `sidebar full` the pane is wide enough to read.
((pane "board" "BOARD"
   (text "Cards in .shift/kanban.md")
   (command "rg" "--no-line-number" "^(#|- )" ".shift/kanban.md")
   (action "Pick up next" (workflow "card-pick"))
   (action "Finish current" (workflow "card-done"))))
