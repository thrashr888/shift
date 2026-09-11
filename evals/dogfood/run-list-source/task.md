# Show where the run allowlist came from

`/run list` shows allowed command prefixes but not which settings supplied them.
Add the effective allowlist's settings source to each row in this format:
`allow make test (project)`. Sources are `user`, `project`, `session`, or `default`.

Use the same precedence as settings: session overrides project, which overrides
user. These lists replace one another; do not merge shadowed lists. A terminal
`/run allow` or `/run deny` changes the effective list's source to `session`.
After resuming, saved session preferences must still be labelled `session`.
For an empty list, include its source in the existing help line, starting with
`Run allowlist is empty (SOURCE)` and retaining the help on adding a prefix.
Do not change which commands are allowed or how preferences are saved.
