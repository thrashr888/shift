# RFC: diff, patch, and test workflow

Status: accepted with the draft defaults on September 6, 2026. Steps one
through four of the implementation order are implemented: SHA-256, the change
ledger, the prepare/commit split with diff previews for `write` and `edit`, the
`(shift coding)` built-in with `status` and `diff`, `apply_patch` with an
all-or-nothing multi-file commit, and `run` with timeouts, logs, the
allowlist, `TRACEPARENT`, and the agentkernel backend seam. From steps five
and six, `/undo`, `/recover restore`, the Python workflow suite, and the
documentation refresh are implemented. The end-of-turn receipt landed on
September 9, 2026, with the JSON form the evals RFC asked for.

## Summary

Shift can edit files but cannot see what it changed, prove that a change is safe
to undo, or run a test command without an approval-gated shell string. That is
the biggest blocker to using it as a primary coding agent. This RFC adds one
trusted built-in, `(shift coding)`, with four structured tools, a per-session
change ledger behind every mutating tool, a hash-gated `/undo`, an end-of-turn
receipt, and a set of workflow tests that exercise the loop on real
repositories. The TUI waits until this loop is dependable.

## Goals

- The model inspects and verifies its own work with structured tools instead
  of shell strings: `status`, `diff`, `apply_patch`, and `run`.
- Every file mutation, whichever tool made it, is previewed as a diff before
  approval, recorded with before/after hashes, and reversible while the files
  still match the recorded post-edit state.
- Every turn ends with a receipt: changed files, diffstat, commands, test
  outcome, tokens, trace ID, and resume ID.
- Interrupted mutations are recoverable from an explicit record, not inferred.
- The same contracts work in a dirty Git checkout and in a project with no Git.

## Non-goals

- No Git write operations. Shift never stages, commits, stashes, or resets.
  `/undo` is file-level and independent of Git.
- No background jobs, PTY, or interactive child processes. `run` is a bounded,
  non-interactive command with captured output.
- No model-based approval classification. Any new allow decision is
  deterministic, process-owned data.
- No diagnostics integration (LSP, compiler JSON). Test results are exit status
  plus bounded output.
- No TUI. The REPL renders diffs and receipts as plain text that a later TUI
  can turn into cards without changing the controller.

## Current state that the design builds on

- `write` and `edit` live in `src/live-agent/tools.scm` and write atomically
  through `mkstemp` + `rename`. Neither records what the file was before.
- `shell` takes an opaque string, runs it under `/bin/zsh -lc`, and cannot be
  timed out. Cancellation relies on the terminal's SIGINT reaching the child.
- Before each tool executes, `main.scm` writes `interrupted-tool.json` and
  clears it afterwards; `/recover` shows, retries, or discards it.
- Approval prints the tool name and raw JSON arguments and waits for one key.
- Trusted built-ins are Guile modules under `extensions/shift/`, listed in
  `src/live-agent/builtins.scm`, and reached through `builtin-ref`. `traces`
  is already a tool whose availability depends on a built-in being enabled.
- `tool-decision` in `policy.scm` is the single deterministic gate.
- Session state lives in `.shift/sessions/NAME/` with `session.json`,
  `events.scm-log`, `traces.jsonl`, and `settings.json`. Unnamed sessions use
  the state directory directly.
- Guile 3.0.11 provides `spawn` with pipe redirection, `select`, `kill`, and
  `waitpid`, verified on this machine. There is no SHA module; the generation
  fingerprint is a 64-bit FNV-1a in `generation.scm`.

## Design

### 1. The `(shift coding)` built-in

A new trusted module `extensions/shift/coding.scm`, added to
`enabled-builtins` as `coding` and enabled by default like the providers. It
can be excluded with `SHIFT_BUILTINS`, in which case the four tools are simply
absent, exactly as `traces` disappears without `tracing`.

It exports:

```scheme
coding-tool-names      ; '("status" "diff" "apply_patch" "run")
coding-tool-schema     ; name -> provider tool schema
coding-prepare         ; name arguments ledger root -> <prepared>  (pure)
coding-execute         ; <prepared> or read-only call -> <tool-result>
```

`main.scm` folds these names into `supported-tool-names` and the enabled-tool
filter when the built-in is on. The live image still chooses which tools the
agent sees through `agent-tools`; `agent/default.scm` gains the four names.
`SHIFT_TOOL_CEILING` accepts them so a supervised child can be denied `run`.

The change ledger and hashing are runtime concerns used by core `write` and
`edit` as well, so they live in core: `src/live-agent/changes.scm` (ledger,
blob store, undo) and `src/live-agent/sha256.scm` (pure Scheme, tested against
the standard vectors). The built-in depends on core, never the reverse.

### 2. Prepared mutations: preview, approve, commit

Every mutating tool is split into two phases so the approval prompt can show
the real diff and the commit cannot race the preview.

```
prepare  (pure)   read current files, compute new contents, produce
                  a unified diff and per-file (path, before-hash, after-hash)
approve            existing tool-decision plus the interactive prompt,
                  now rendering the prepared diff
commit   (atomic) re-hash each target, refuse if it differs from the
                  prepared before-hash, write atomically, append ledger
```

`write`, `edit`, and `apply_patch` all implement `prepare`. `write` of an
existing file is a diff against it; `write` of a new file is a create diff
against `/dev/null`. The `<tool-result>` record gains an optional `changes`
field so the runtime learns what a tool mutated without parsing its prose.

The approval prompt becomes:

```
edit src/live-agent/tools.scm  (+3 −1)
--- a/src/live-agent/tools.scm
+++ b/src/live-agent/tools.scm
@@ -20,4 +20,6 @@
 (define max-tool-output (* 64 1024))
-(define max-write-input (* 256 1024))
+(define max-write-input (* 512 1024))
...
Approve edit? [y/N]
```

Diff rendering is capped at 120 lines per prompt; beyond that it prints the
diffstat and the first hunks, then `… 4 more hunks in 2 files`. The full diff
is always available afterwards through `diff turn`.

### 3. Stale-file detection

The ledger keeps a per-session "last seen" hash for every path that `read`,
`diff`, or a mutation has observed. `prepare` compares the file's current hash
to that entry. If they differ, the tool fails before approval:

```
src/app.rs changed on disk since turn 4 (a1b2… → c3d4…); read it again before editing.
```

Files the session has never seen are not checked; `edit`'s exact `old_text`
match and `apply_patch`'s context match remain the guard there. This catches
the user's editor, another Shift session, or a formatter touching the file,
without asking the model to track hashes. `read` output gains a one-line
header `# path · 1,204 bytes · sha256 a1b2c3d4` so the model can quote it.

### 4. `apply_patch`

Input is one unified diff, possibly multi-file, in the exact shape `git diff`
and `diff -u` emit: `--- a/PATH`, `+++ b/PATH`, `/dev/null` for create and
delete, `@@` hunks with context. No other patch dialect is accepted.

Semantics:

- Parse the whole patch first. A malformed hunk rejects the whole call.
- Each hunk must match its context lines exactly. The applier searches for the
  context starting at the stated line and then outward in both directions, but
  never applies with partial context (no fuzz).
- All-or-nothing across every file in the patch. If any hunk fails, nothing is
  written and the error names the file, hunk, and the first mismatched line.
- Paths resolve through the existing project-root confinement.
- Prepared and committed like any mutation, so it is previewed and undoable.

Inverse patches are derived, not stored: `diff -u after before` over the
blob store produces one on demand for display and for the receipt. Applying
the inverse on undo would be a second code path with the same failure modes,
so undo restores blobs instead (section 6).

### 5. `run`

```json
{"argv": ["cargo", "test", "--", "session"],
 "cwd": "crates/shift",            // optional, project-relative
 "timeout_seconds": 120}           // optional, default 120, max 600
```

- No shell. `spawn` runs `argv[0]` through `PATH` with the project's
  environment. `cwd` must resolve inside the project root.
- stdout and stderr share one pipe so interleaving is preserved. Output is
  read with `select` on a 250 ms tick so cancellation asyncs and the deadline
  are both honoured.
- The complete output is written to `.shift/sessions/NAME/runs/ID.log`. The
  tool result carries the first 16 KiB and the last 48 KiB with a marker
  between them, the exit status or signal, the duration, and the log path.
- Timeout or cancellation sends SIGTERM, waits two seconds, then SIGKILL, and
  always reaps the child. The result reports `timeout` or `cancelled`
  distinctly from a non-zero exit. In an interactive terminal, Ctrl-C also
  reaches the child's descendants through the foreground process group; for
  timeouts and MCP cancellation, only the direct child is signalled. That
  limitation is documented rather than hidden behind a `setsid` wrapper that
  macOS does not ship.
- The result is structured text the model can act on:

```
run cargo test -- session · exit 101 · 4.8s · 312 lines · log runs/7f3a.log
…bounded output…
```

`shell` stays for the rare case that needs a pipeline, but the system prompt
directs the model to `run` for anything with an argv.

### 6. Change ledger, blob store, and `/undo`

Layout under the session directory (or the state directory for unnamed
sessions):

```
changes.jsonl     append-only; one entry per mutation
blobs/<sha256>    content-addressed pre- and post-images
runs/<id>.log     full command output
receipts.jsonl    one entry per completed turn
```

A ledger entry:

```json
{"turn": 12, "seq": 3, "tool": "apply_patch", "call_id": "toolu_01…",
 "path": "src/app.rs", "before": "a1b2…", "after": "c3d4…",
 "state": "committed", "at": "2026-09-06T21:14:02Z"}
```

The entry is appended with `state: "started"` and the pre-image blob before
the write, and rewritten as `committed` after. Creates use `before: null`;
deletes use `after: null`.

`/undo` reverts the most recent turn that still has undoable changes:

1. Group that turn's committed entries by path, taking the first `before`
   and last `after` per file.
2. Hash every file now. If any differs from its recorded `after`, refuse and
   list the diverged files. There is no force flag; the user resolves it.
3. Restore each file from its `before` blob atomically (or delete it for a
   create), then re-hash and verify.
4. Append `undone` entries, journal `turn-undone`, print a receipt, and add a
   system message to the conversation so the model knows the files reverted.

Repeated `/undo` walks back one turn at a time. Redo is not in scope, though
the post-image blobs make it cheap later. The blob store is capped at 64 MiB
per session; pruning drops the oldest turns' blobs and marks those turns as no
longer undoable in `status`.

### 7. `status` and `diff`

Both are read-only, so plan mode allows them.

`status` reports, in order: whether the project is a Git checkout and its
branch, the files Shift changed this turn and this session (from the ledger),
which turns are undoable, pre-existing dirty files from `git status
--porcelain=v2` that Shift did not touch, and the last `run` outcome. In a
non-Git project the Git sections read `not a git repository` and everything
else works.

`diff` takes `scope`: `turn` (default), `session`, or `git`, plus optional
`paths`. `turn` and `session` diff the earliest ledger pre-image against the
current file, which works without Git. `git` runs `git diff` for the working
tree and errors clearly outside a checkout. All diffs are `diff -u` over blobs
or Git output, spawned without a shell, bounded at 64 KiB with a diffstat
header.

### 8. Policy

`tool-decision` gains three rows:

| Tool | manual | plan | accept | auto |
| --- | --- | --- | --- | --- |
| `status`, `diff` | ask | allow | allow | allow |
| `apply_patch` | ask | deny | allow | ask |
| `run` | ask | deny | ask, or allow when allowlisted | same |

The `run` allowlist is process-owned settings data, never a live-image
binding: `run-allow` in `settings.json` is a list of argv prefixes such as
`["cargo","test"]` or `["make","check"]`. Only the terminal can change it:
`/run allow cargo test`, `/run deny cargo test`, `/run list`. The approval
prompt offers `[y/N/a]`, where `a` approves and adds the exact prefix for this
session; `/settings save` promotes it like any other preference. Matching is
exact on the leading elements; `["cargo","test"]` does not allow
`["cargo","publish"]`. MCP callers still cannot approve anything.

### 9. Receipt

After every turn, and on `/receipt`, the REPL prints:

```
turn 12 · claude-sonnet-5 · generation 3 · 4 rounds · 2,445 in (1,900 cached) + 611 out · 6.1s
changed  src/app.rs (+14 −3)  tests/app.rs (+22 −0) new
ran      cargo test -- session  exit 0  4.8s
undo     available (/undo)
trace    3f9a1b2c… span 8c21aa00…   resume ./bin/shift --resume dogfood
```

The receipt is a projection, not a store: the changed files and their
diffstats come from the ledger's committed entries and stored images for
that turn, the `ran` lines from the ledger's run records, the tokens and
rounds from the turn's provider usage, and the identities from the
`agent.turn` span and the session. The same record is appended as one JSON
line to the session's `receipts.jsonl`, attached to the `agent.turn` span as
`receipt.*` attributes (status, rounds, token counts, tool call count,
changed file count and names, run and failed-run counts, undo), written
whole to `--receipt FILE` in print mode, and carried by the MCP
`shift_prompt` output because it is part of the turn's printed text;
`shift_inspect` accepts `/receipt`. A cancelled or failed turn gets a receipt
with a `status` line and reason and whatever mutations committed before the
interruption, so `undo` is reported for them too. A receipt that cannot be
written is reported on stderr and never fails the turn.

The JSON form:

```json
{"turn": 12, "at": "2026-09-09T20:39:24Z", "status": "ok", "error": null,
 "model": "claude-sonnet-5", "provider": "claude", "generation": 3, "duration_ms": 6100,
 "rounds": 4, "tokens": {"prompt": 2445, "cached": 1900, "uncached": 545, "completion": 611},
 "tool_calls": {"read": 2, "edit": 1, "run": 1},
 "changed": [{"path": "src/app.rs", "added": 14, "removed": 3, "created": false, "deleted": false,
              "before": "<sha256>", "after": "<sha256>"}],
 "runs": [{"command": ["cargo", "test", "--", "session"], "mode": "local", "exit_code": 0,
           "success": true, "status": "exit", "duration_ms": 4800, "log": "runs/run-12-1.log"}],
 "undo": true, "trace_id": "…", "span_id": "…",
 "session": "dogfood", "session_id": "…", "resume": "./bin/shift --resume dogfood"}
```

Run entries use the agentkernel receipt vocabulary (`exit_code`, `success`,
`mode`) so a signed sandbox receipt can be attached beside them later.

### 10. Interrupted mutation recovery

`interrupted-tool.json` already survives a crash. With the ledger, a
`started` entry that never reached `committed` identifies exactly which file
and pre-image were in flight. On boot, `/recover` reports both:

```
interrupted apply_patch at turn 12 · src/app.rs
  recorded before a1b2… · on disk now c3d4… (matches the prepared after-hash)
  /recover retry     re-run the tool (it will refuse: file already changed)
  /recover restore   put src/app.rs back to a1b2… from the pre-image
  /recover discard   keep the file as it is
```

`restore` is the new action. It is hash-gated the same way as `/undo`: it
only writes if the file currently matches either the recorded before-hash
(nothing to do) or the prepared after-hash (the write completed but the
ledger did not). Any other hash means a third party changed the file, and
the record is left for the user to inspect.

### 11. MCP and the supervisor

`shift_status` gains the changed-file list, undoable turns, and last run
outcome. `shift_prompt` output already includes everything the REPL prints,
so the receipt reaches the supervisor without a new tool. A structured
`shift_receipt` tool can follow once the TUI needs the same data.

### 12. Compatibility with agentkernel

[agentkernel](https://thrashr888.github.io/agentkernel/) runs commands in
isolated sandboxes and mounts the project at `/workspace`. Shift's file tools
stay on the host; only execution moves. The design above is compatible with
that split, with four deliberate alignments:

- **`run` has a backend seam.** The built-in maps the tool's argv to an
  executed argv. The `local` backend is the identity. An `agentkernel`
  backend wraps it as `agentkernel exec NAME --workdir /workspace/CWD -- ARGV`
  and spawns that locally, so exit codes pass through, timeouts and
  cancellation still signal a local process, and `--receipt FILE` can be
  added for a signed receipt. The backend and sandbox name are process-owned
  settings; security profile, network, and mounts remain agentkernel's
  configuration. `cwd` is always project-relative so it maps to `/workspace`.
  This is the same shape as agentkernel's Pi extension, without an HTTP
  client, and it matches the argv-only `ExecRequest` of the HTTP API for a
  later transport.
- **Run outcomes use agentkernel's receipt fields.** Each `run` record in
  Shift's receipt carries `exit_code`, `success`, `output_sha256`,
  `output_bytes`, and `error`, the exact `ExecutionOutcome` of
  `agentkernel run --receipt`, plus an `invocation` of `{mode, input}` where
  `mode` is `local` or `agentkernel_exec`. A signed agentkernel receipt can be
  attached verbatim when one was produced.
- **Trace context crosses the boundary.** agentkernel injects `TRACEPARENT`
  into sandboxed commands. Shift's `run` sets `TRACEPARENT` from the tool
  span for local runs too, so both paths link into the same trace.
- **Sandbox side effects are visible.** A sandboxed formatter or build that
  rewrites mounted files shows up through last-seen hashes. After every
  `run`, the result lists previously seen files whose hash changed, so the
  model re-reads them instead of failing a stale check later.

Hashes are lower-case hex SHA-256 everywhere, as in agentkernel.

### 13. Compiled modules

`bin/shift` runs Guile with `--no-auto-compile`, and interpreted SHA-256
costs 371 ms per 64 KiB, which is too slow for every `read`. Compiled, the
same code takes 32 ms. `make build` compiles `src/live-agent` and
`extensions/shift` into `build/`, which is gitignored; `bin/shift` and the
tests pass `-C build`, and Guile falls back to source with a note whenever a
`.go` is older than its `.scm`. `make test` depends on `build`. A subprocess
per hash was rejected: process spawn alone measured over 130 ms here.

## Tests

Scheme suites, run through `test/run.scm`:

- `test/sha256.scm`: the standard vectors, empty input, and a 600 KiB input.
- `test/patch.scm`: parse and apply single- and multi-hunk patches, creates,
  deletes, offset context, conflicting context, malformed hunks, CRLF
  preserved as-is, no trailing newline, and all-or-nothing on a second-file
  failure.
- `test/changes.scm`: ledger append, blob dedupe, undo gating on a diverged
  file, undo of create and delete, cap pruning, stale-file detection.
- `test/coding.scm`: `run` exit codes, timeout, output bounding and log path,
  `status` and `diff` inside and outside Git, `cwd` confinement.

Python end-to-end, `test/coding_workflow_test.py`, driving the real CLI with
the fake OpenAI-compatible provider from `test/regressions.py` so the model
side is deterministic:

1. Dirty Git checkout: the user has an uncommitted change; the model edits a
   different file; `status` separates the two; `/undo` reverts only Shift's
   file; the user's change is untouched.
2. Non-Git project: the same edit, diff, receipt, and undo flow works and
   `status` says there is no repository.
3. Patch conflict: a patch whose context does not match is rejected with the
   file and hunk named, nothing is written, and the turn continues.
4. Stale file: the test rewrites a file between the model's `read` and its
   `edit`; the edit fails before approval and the message names the turn.
5. Failing test: `run` returns exit 1; the receipt reports it; the turn is
   still checkpointed.
6. Cancelled test: SIGINT during a `run` that sleeps; the child is reaped,
   the span is `CANCELLED`, and history is unchanged.
7. Interrupted mutation: the process is killed between the `started` ledger
   entry and the commit; the next boot reports it and `/recover restore`
   returns the pre-image.
8. Undo refusal: after a turn, the test edits one changed file; `/undo`
   refuses and names it; nothing else is reverted.
9. Run allowlist: `run` asks in accept mode, `a` adds the prefix, the next
   identical call is allowed, a different argv still asks.

`make check` compiles the new modules like the others.

## Documentation changes

- `docs/daily-driver.md`: new tools, policy table rows, `run` allowlist,
  receipts, `/undo`, `/recover restore`, and the session directory layout.
- `docs/dogfooding.md`: remove "no first-class diff, patch-hunk, git-status,
  or test tool" from the blockers.
- `docs/gaps-with-pi.md`: refresh the coding-workflow and provider rows;
  Claude, context budgeting, and token reporting have shipped.
- `README.md`: tool count in the banner example and a short pointer.
- `agent/default.scm`: tool list and prompt guidance for `run` and
  `apply_patch`.

## Decisions made in this draft

- One trusted built-in, not a plugin. Same shape as the providers.
- Preview, approve, commit for every mutation, including the existing
  `write` and `edit`. This is the change that makes the approval prompt
  honest.
- Content-addressed pre-images instead of stored inverse patches. Undo
  restores bytes and verifies hashes; inverse patches are derived for display.
- Undo granularity is the turn, matching the receipt.
- Stale detection is runtime-side from last-seen hashes. The model never has
  to pass a hash.
- `run` takes argv only; there is no shell fallback inside it.
- The `run` allowlist is exact argv prefixes in process-owned settings, edited
  only from the terminal.
- SHA-256 in pure Scheme rather than shelling out per file or reusing the
  64-bit FNV fingerprint for persisted, user-visible hashes.

## Open questions

1. Should `[a]lways` on the `run` prompt persist to the project's
   `settings.json` immediately, or stay session-scoped until `/settings save`
   like every other preference? The draft says session-scoped.
2. Should `write` and `edit` remain in `src/live-agent/tools.scm` with the
   prepare/commit split, or move into `(shift coding)` so all file mutation
   lives in one module? The draft keeps them in core to avoid making the
   read/write confinement depend on a built-in.
3. Is a 120-line cap on the approval diff right for the REPL, given the TUI
   will scroll? A lower cap keeps piped and MCP transcripts readable.
4. Does `status` in a Git checkout also need ahead/behind and staged versus
   unstaged, or is branch plus dirty files enough for the first slice?

## Implementation order

1. `sha256.scm`, `changes.scm`, and the prepare/commit split for `write` and
   `edit` with diff previews at approval. Ledger tests.
2. `(shift coding)` with `status` and `diff`, policy rows, banner and prompt
   updates.
3. `apply_patch` with the parser and applier tests.
4. `run` with timeout, cancellation, logs, and the allowlist.
5. `/undo`, `/recover restore`, and the receipt.
6. The Python workflow suite, then the documentation updates.

Each step leaves `make check` green and is usable on its own.
