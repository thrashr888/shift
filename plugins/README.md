# Bundled plugins

Each folder is a plugin: a `plugin.scm` manifest read as data, plus the skills,
panes, themes and live-image artifacts it points at. They ship with the
install and are on by default; `/plugin disable NAME` turns one off for a
project (`user` for everywhere), and the user's answer overrides the project's.
A plugin that needs a command that is not on `PATH` shows as missing and
contributes nothing until it is installed. See `docs/plugins-rfc.md`.
