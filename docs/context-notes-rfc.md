# Context notes RFC: compaction the agent does itself

Status: RFC. Prompted by Codex's experimental context management for Astra
(traced by Owen Gretzinger, September 8, 2026): instead of summarizing when
the window fills, the harness warns the agent, the agent writes notes with
tools, then explicitly resets to a fresh window that carries pointers to the
notes and to the earlier windows, and history tools stay available so it can
search and read what it left behind.

## What Shift already has

- Summary compaction at the token budget and on `/compact`, with the prefix
  and summary recorded and scored (`scripts/evals.py compaction`).
- `traces` and `recall`: search the durable span history of this session or
  every session, then fetch an exact span with its stored input and output.
  That is Codex's `history.search_contents` and `history.read_item`.
- Skills as durable procedure notes, and `/learn` to write one.

What is missing is the loop: a warning before the window fills, a place to
write working notes that survive the reset, a reset the agent chooses, and a
fresh window that starts from pointers rather than a summary.

## Design

1. **Reminder.** When the estimated context passes a `context-reminder`
   fraction of the budget (default 0.75), the next request carries one
   ephemeral harness note: "Context is at N%. Write what you must keep to
   notes, then call new_context." It is sent once per window.
2. **Notes tool.** `notes` with actions `write` (path, text), `append`,
   `read`, `list`. Files live under the session folder, `notes/`, never in
   the project, so the judge's `.shift` rule stays intact and the project tree
   stays clean. Subagents get their own folder; a parent can read a child's.
3. **new_context tool.** The agent replaces its window: history becomes the
   system prompt, one harness message with the window number, the list of
   notes files with sizes, the last user request, and a pointer sentence
   ("earlier windows are searchable with traces and recall"). No summary is
   generated. The old window's messages are recorded to `windows/N.json`
   beside the checkpoint, the way compactions are today, and the trace gets a
   `session.new_context` span.
4. **Forced reset.** If the agent ignores the reminder and the hard budget is
   reached, today's summary compaction runs as before; the reminder note said
   it would.
5. **Evals.** The compaction scorer applies unchanged: the durable-fact
   checklist is computed from the dropped window, coverage is measured over
   the notes files plus whatever the next window's first answer recovers.
   `scripts/evals.py compaction` gains a `notes` row per window.

## Decisions

- Notes are session state, not project files, and are gitignored with the
  rest of `.shift/`.
- The reminder is a fraction of the same budget the compaction guard uses;
  one setting, `context-reminder`, off with `0`.
- `new_context` keeps the last user message verbatim so the task survives
  even when the notes are thin.
- Summary compaction stays as the forced fallback; nothing regresses for a
  model that never calls the new tools.

## Open questions

1. Should `new_context` be allowed in plan mode? It writes only session
   state, so the draft says yes.
2. Whether the reminder should also fire on `/compact`, turning the manual
   command into "write notes, then reset". The draft says `/compact` keeps
   its meaning and a new `/new-context` command is the manual reset.
