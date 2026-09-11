# Show the last undo in status

The status tool lists undoable turns but does not say which turn the user most
recently undid. Add one line to its output: `last undo: none` before any successful
undo, otherwise `last undo: turn N`.

Report the most recent successful undo operation, not the highest turn number:
undoing turn 11 and then turn 10 must report turn 10. A refused undo must not
change that answer, and subsequent edits must not erase it. It must survive
reopening the session ledger and work in projects without Git. Preserve the
existing status information and undo safeguards.
