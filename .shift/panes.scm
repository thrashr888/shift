;; Shift's own project panes: a SHIFT tab with checkout health. Read as data,
;; never evaluated; `./bin/shift-agent --check-panes` lints it.
((pane "shift" "SHIFT"
   (text "Shift checkout health")
   (field source.loaded)
   (field session.model)
   (field usage.prompt)
   (command "git" "status" "--short")
   (command "git" "log" "--oneline" "-3")
   (command "make" "test")))
