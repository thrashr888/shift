;; Read as data, never evaluated. `./bin/shift-agent --check-panes
;; .shift-plugin/panes.scm` lints it. The command row runs only because the
;; manifest's allow-run already permits that prefix.
((pane "shift-dev" "DEV"
   (text "Modules a build would recompile")
   (command "make" "-n" "build")
   (field source.loaded)
   (field receipt.status)
   (field receipt.duration_ms)))
