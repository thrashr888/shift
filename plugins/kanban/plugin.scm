;; The board is one file the pane and the agent share. There is no kanban
;; binary, and this plugin needs none: the read is the `read` tool with its
;; path fixed, and cards move with `edit`, under a workflow whose checks decide
;; whether the move was earned. See docs/plugin-tools-rfc.md, "What the kanban
;; plugin showed", for why that is the honest shape rather than a shortcoming.
((plugin "kanban" "0.2")
 (description "A per-project board kept as one file the pane and the agent share")
 ;; Only the pane needs ripgrep. A pane row renders a command's output and
 ;; nothing else, so showing a file means running something over it; the tool
 ;; below needs no binary at all. That asymmetry is the argument for letting a
 ;; pane name a file directly — docs/plugin-tools-rfc.md, open question 4.
 (requires (command "rg"))
 (skills "skills")
 (panes "panes.scm")
 (workflows "workflows")
 ;; A read binding: no binary, no allowlist entry, and the project boundary
 ;; comes from `read` rather than from a pinned argv that has to be trusted to
 ;; stay pinned. Deliberately not resident — this plugin is available in every
 ;; project while almost none has a board, and a resident schema is charged on
 ;; every request of every session. The pane renders the board from its own
 ;; command row, so nothing visible depends on this tool being loaded.
 (tool "kanban_board"
   (description "Read this project's board: every column and the cards in it.")
   (read ".shift/kanban.md"))
 ;; For the pane's row only. The prefix is the whole command including the
 ;; file, so nothing else can be read through it.
 (allow-run ("rg" "--no-line-number" "^(#|- )" ".shift/kanban.md")))
