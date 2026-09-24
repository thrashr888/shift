;; The board is one file the pane and the agent share. There is no kanban
;; binary to declare tools over, so the only thing worth declaring is the read;
;; cards move with `edit`, under a workflow whose checks decide whether the
;; move was earned. See docs/plugin-tools-rfc.md, "What the kanban plugin
;; showed", for why that is the honest shape rather than a shortcoming.
((plugin "kanban" "0.1")
 (description "A per-project board kept as one file the pane and the agent share")
 (requires (command "rg"))
 (skills "skills")
 (panes "panes.scm")
 (workflows "workflows")
 ;; Deliberately not resident. This plugin is bundled, on by default, and
 ;; needs only ripgrep, so it is available in every project — while almost no
 ;; project has a board. A resident schema would be charged on every request
 ;; of every session to save one tool_search in the few that open one. The
 ;; pane renders the board from its own command row regardless, so nothing
 ;; visible depends on this tool being loaded.
 (tool "kanban_board"
   (description "Read this project's board: every column and the cards in it.")
   (run "rg" "--no-line-number" "^(#|- )" ".shift/kanban.md"))
 ;; The prefix is the whole command, including the file. Nothing else can be
 ;; read with it, which is what makes allowing it at all reasonable.
 (allow-run ("rg" "--no-line-number" "^(#|- )" ".shift/kanban.md")))
