# RFC: skills, background jobs, and a composable sidebar

Status: implemented September 13, 2026, `source` rows included. The decisions
at the end record what changed from the draft.

## Summary

Three additions that share one rule: the runtime owns authority and the user
owns data.

- **Skills** are folders of instructions in the Agent Skills `SKILL.md` format
  that Pi, Claude Code and Codex already read. Shift indexes their names and
  descriptions for the model, loads a body only when asked, never widens tool
  policy because a skill says so, and shows what is loaded in the Session tab.
- **Background jobs** let `run` return immediately and keep a bounded process
  alive under the session, with output streaming into the Log tab and the
  ledger, completion notices reaching the model, and pane commands running the
  same way so the interface never blocks on `make test`.
- **The sidebar stays at five built-in tabs and paginates.** Skills join the
  Session tab and jobs join the Log tab. When tabs overflow the strip, it shows
  the ones that fit plus `‹ ›` arrows instead of shrinking labels, and later
  built-in sections become pane rows so a project can compose its own sidebar
  in `.shift/panes.scm`.

## 1. Skills

### Format and discovery

A skill is a directory with a `SKILL.md` whose YAML frontmatter has `name`
(1–64 characters, `[a-z0-9-]`) and `description` (≤1024 characters).
`disable-model-invocation: true` is honored; every other frontmatter field is
ignored. The body is Markdown, ≤32 KiB. Supporting files may sit beside it.
Nothing in a skill is evaluated.

Discovery, in precedence order when names collide:

1. `PROJECT/.shift/skills/*/SKILL.md`, committable; `.gitignore` allows it the
   way it allows `panes.scm`.
2. `PROJECT/.agents/skills/*/SKILL.md`, the shared convention Pi and other
   agents read, so a repository's existing skills work unchanged.
3. `~/.config/shift/skills/*/SKILL.md` (respecting `XDG_CONFIG_HOME`) and
   `~/.agents/skills/*/SKILL.md`.

The index is rebuilt at the start of each turn from directory mtimes, which is
cheap and avoids another watcher. Invalid skills are listed by `/skills` with
the reason and are never offered to the model.

### What the model sees

The runtime appends a `<skills>` block to the system message it already owns:
one line per skill with name and description, or nothing when there are no
skills. Bodies are not in the prompt. A new read-only tool, `skill`, takes
`{name}` and returns the body plus the skill's directory, and `read` accepts
paths under a discovered skill directory so supporting files are reachable
without widening the project-root boundary for anything else. The loaded body
lives in history as a tool result, so it survives compaction like any other
evidence. `disable-model-invocation: true` hides a skill from the tool; only
the user can load it.

A skill cannot grant or request authority: policy is process-owned data
(`policy.scm`). This is the deliberate difference from Pi, where a skill runs
with the process's permissions.

### User commands

- `/skills` lists skills with source, validity and loaded state.
- `/skill NAME` loads a skill for the next turn as a visible user-side message
  (`skill NAME loaded`), which is how a skill with `disable-model-invocation`
  gets used.
- The TUI's Session tab gets a `SKILLS` section: `● name` when loaded this
  session, `○ name` otherwise, with the source (`project`, `agents`, `user`)
  dimmed on the next row; clicking an unloaded row issues `/skill NAME` through
  the existing host session-command route, which gains that one prefix.

### Policy and trust

`skill` is a read-only tool: allowed in plan and autopilot, asked in manual like
every other read. A freshly cloned repository can therefore put text in front of
the model only after the user sees the tool call in manual mode or has chosen
autopilot for that project. That is the same trust boundary pane commands and
`read` already have, so no new "trust this folder" prompt is introduced.

### Records

The turn span gets `skill.loaded` (names) and the receipt gets `skills`; the
Session tab's `LATEST RECEIPT` shows them. `/skills` output and `shift_status`
for MCP peers include the index.

## 2. Background jobs

### Tool surface

`run` gains `background: true`. The approval prompt and the allowlist decision
are unchanged; the process starts and the tool returns at once with a job id
(`job-TURN-N`), the log path and the pid. Foreground `run` keeps its 600 s
ceiling; a background job may set `timeout_seconds` up to 3600. At most four
jobs run per session; a fifth request fails with the running list.

A second read-only tool, `job`, takes `{action, id, timeout_seconds}`:

- `list`: every job of the session with status, elapsed time and last line.
- `wait`: block up to `timeout_seconds` (default 60, max 600) for completion,
  then return the same record a foreground `run` returns.
- `output`: the bounded tail so far (300 lines / 16 KiB, like run output).
- `cancel`: SIGTERM, then SIGKILL after five seconds; records `cancelled`.

`/jobs` and `/jobs cancel ID` are the user-side forms. `/cancel` stops the
turn and leaves jobs running; process exit kills every job and records
`killed by exit` in the ledger, because nothing is daemonized.

### Completion reaching the model

The ledger records a job at start (`status: running`) and rewrites the record
on completion, so `/undo` and the receipt see one entry. When a job finishes
while a turn is in flight, the next tool round carries an ephemeral user
message, `job job-12-1 finished: exit 0 · 4.8s · log runs/run-12-1.log`, using
the same ephemeral mechanism as the round-limit nudge. When no turn is running,
the notice is queued in the session checkpoint and delivered at the start of
the next turn, so a restart does not lose it. The receipt lists jobs started
and finished in the turn with the same fields as runs.

### Interface

- The Log tab shows a `RUNNING` block above the run history: one row per job
  with a working mark, elapsed seconds and the last output line, refreshed by
  a `job-output` UI event no more often than twice a second and bounded like
  `pane-output`. Clicking a running row jumps to its output; the row's action
  menu offers cancel.
- The footer summary says `1 job running` while any job runs; the mark animates
  only for the model turn, not for jobs.
- Pane `command` rows run as background jobs. Output streams under the row
  instead of arriving at the end, the interface never blocks, and a pane can
  hold `make test` without a timeout compromise. `/pane run` semantics are
  unchanged.

### Concurrency inside a round

When a completion returns several tool calls, read-only calls (`read`, `rg`,
`status`, `diff`, `traces`, `skill`, `job list/output`) execute concurrently
on up to four Guile threads and their results are returned in the model's
order; mutating calls and foreground runs execute sequentially after the
reads, as now. This needs the trace writer and `runtime-record!` to serialize
under the existing runtime mutex, which is the audit that gates both jobs and
parallel reads. Subagent fan-out stays where `subagents.md` leaves it.

## 3. The sidebar

### Are there too many tabs?

Today: Work, Diff, Session, Model, Log, plus up to four pane packs, with the
`sections` preference able to hide Diff and Session and the strip shrinking
labels to their first letters below 12 columns each. Skills and jobs would push
that to seven built-ins. That is too many for a 128-column terminal and it
duplicates what the tabs already mean: Session is "what is attached to this
session" and Log is "what ran". So:

- Skills go into Session, jobs into Log. No new tabs.
- Model stays its own tab because it is a picker, not a status view.

### A more flexible solution

Two steps:

1. **Pagination in the strip.** Labels stay whole. When they overflow, the
   strip shows the tabs that fit and `‹ ›` arrows to the right of the names;
   the active tab's page is always the one shown, Tab past the last visible
   tab turns the page, and the arrows are clickable. This replaces the
   first-letter shrinking, which stopped being readable past five tabs.
2. **Sections as pane rows.** Built-in sidebar content becomes rows a pane can
   name: `(source sessions)`, `(source peers)`, `(source skills)`,
   `(source runs)`, `(source receipt)`, `(source models)`. The built-in Session
   and Log tabs become default panes declared in the same grammar, and a project
   can compose a `STATUS` pane with the sessions list, its skills and
   `git status`. The pane reference on the site gains the `source` row and its
   names; the field list already comes from `ui.scm`, and the source list will
   too.

Pagination ships first because it is small. Step 2 follows once skills and jobs
exist as sources, so the built-in tabs are rewritten once, not twice.

## Implementation order

1. Skills: discovery and validation in a `(live-agent skills)` module with
   tests, the system-prompt block, the `skill` tool and `read` allowance,
   `/skills` and `/skill`, the Session tab section and host route, receipt and
   trace fields, docs and the site's skills note.
2. Runtime audit: serialize trace and runtime records under the runtime mutex;
   tests that hammer them from threads.
3. Jobs: process table in `(shift coding)`, `run background`, the `job` tool,
   ledger records, completion notices, `/jobs`, Log tab `RUNNING`, pane
   commands as jobs, receipt fields, docs.
4. Parallel read-only tool calls behind the audited records.
5. `source` rows, so built-in tabs become default panes.

Each step leaves `make test` green and is usable on its own.

## Decisions (September 13)

1. Read `.agents/skills` in the project and `~/.agents/skills` globally as well
   as Shift's own folders.
2. Job ceilings stay at one hour and four concurrent jobs per session.
3. Every pane command runs as a background job; there is no separate row kind.
4. Parallel read-only tool calls ship with jobs.
5. Tab-strip pagination ships now, ahead of skills.
