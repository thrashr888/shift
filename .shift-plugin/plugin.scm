;; Shift's own repository plugin: what an agent needs to work on Shift itself.
;; It loads from `.shift-plugin/` only for a session whose project is this
;; checkout, so none of it ships to a user running Shift on their own code.
((plugin "shift-dev" "0.1")
 (description "Build, test and eval loops for working on Shift itself")
 (requires (command "guile") (command "make"))
 (skills "skills")
 (panes "panes.scm")
 ;; Only fixed-argv reads and the project's own build and test targets.
 ;; `make -n` cannot execute a recipe, and each git and jj prefix is long
 ;; enough that no mutating subcommand matches it: ("git" "branch") would
 ;; also allow `git branch -D`, so it is absent, while ("git" "worktree"
 ;; "list") pins the third element and add/remove stay judged.
 ;;
 ;; A single suite runs as `guile -L src -L extensions -C build test/run.scm
 ;; test/NAME.scm` and is deliberately not allowlisted: test/run.scm loads
 ;; whatever path follows it, so any prefix that reaches it would let a
 ;; written-then-run file execute without approval, which is the shell
 ;; boundary this project keeps closed.
 (allow-run ("make" "build") ("make" "test") ("make" "check") ("make" "-n")
            ("git" "status") ("git" "log") ("git" "diff") ("git" "show")
            ("git" "worktree" "list")
            ("jj" "status") ("jj" "st") ("jj" "log") ("jj" "diff") ("jj" "show")))
