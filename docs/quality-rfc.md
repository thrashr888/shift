# Quality RFC: evals that would have caught the default-session failure

Status: RFC. Decisions are listed; implementation follows in the order below,
each step landing with tests. Implemented so far: 1 (judge evals), 2
(session review), 3 (compaction quality) and 4 (diagnostics).

## What the real-world test showed

A manual-mode performance review on a 27b local model ran seven tool rounds
over 24 minutes, hit the six-round ceiling with no answer, and the harness
threw the whole turn away. The next turn's model had no record of the reads
and runs it had done, so it invented a confession about fabricated output.
Meanwhile the shadow judge blocked two harmless read-only commands because it
read the run allowlist as a whitelist. None of the existing evals could have
noticed any of that: the dogfood tasks grade outcomes, the SWE-bench slice
grades patches, and the unit tests pin behaviors nobody had thought to pin.

Three defects are already fixed (round-limited turns keep their exchanges, the
judge prompt explains the allowlist, the default ceiling is 12). This RFC is
about the evals and quality work that make the next such failure visible
before a person notices it.

## 1. Judge evals

`judge.jsonl` gains the fields a replay needs: `arguments`, the run `preview`,
and the user-message excerpt the judge saw. `scripts/evals.py judge` replays
each case through a candidate model and reports agreement with the human
answer when there was one, and with the original verdict otherwise. The two
false blocks from the default session become the first entries of
`evals/judge/cases.jsonl`, a fixed regression set that any judge model must
pass; `evals.py judge --cases` runs that file.

Decisions: cases are stored with the user messages clipped to twelve lines, as
the judge saw them; the report counts false blocks and false allows
separately, since a false allow is the expensive kind; no aggregate score
beyond those two counts and agreement.

## 2. Session review

`scripts/evals.py session NAME` turns a session's receipts, events and judge
log into the report I produced by hand: per turn, rounds used against the
ceiling, tool calls that failed (non-zero runs, tool errors), identical reads
repeated, time spent waiting for approval, judge verdicts that disagreed with
the human, and whether the turn ended at a limit. It is deterministic and
needs no model. `--all` runs it over every session in the project, subagents
included, so a week of dogfooding reads as one table.

Decision: this is a report, not a score. It names the failure classes from the
evals RFC and leaves judgement to the reader.

## 3. Compaction quality

Compaction already records the summary. It will also record what it replaced:
the compacted prefix is written to `compactions/N.json` beside the checkpoint,
with the summary and a checklist of durable facts derived from the prefix
without a model: files edited, commands whose exit was non-zero, user
constraints (messages starting with "don't", "never", "always", "only"), and
decisions the assistant stated. `scripts/evals.py compaction` replays stored
prefixes through a candidate summarizer and scores each summary by checklist
coverage: how many of the durable facts a reader can recover from it. The same
scorer runs on the summary the session actually used, so `session` review can
flag a lossy compaction.

Decisions: coverage is substring recall over the checklist, nothing fuzzier;
prefixes are kept locally under the session and are never exported.

## 4. Diagnostics

`run` results carry a `diagnostics` list when the output matches formats the
harness knows: `path:line:col: message` (compilers, guild, linters), pytest
and unittest failure lines, and cargo's `-->` locations. The receipt lists
them, the Log tab shows them under the run, and the model gets them in the
tool result ahead of the raw tail, so a failing test names its file and line
in the first lines it reads. No LSP: the parsers are regular expressions over
the output the run already captured.

## 5. Hardening

- **Authority audit.** A test that enumerates every binding reachable from
  `live_eval` and diffs it against a committed allowlist, so a new export that
  widens the evaluator fails the suite.
- **Fuzzing.** Property tests feeding random and mutated inputs to the JSON
  reader, the patch applier, the diff and the pane and plugin parsers; they
  must reject or accept, never hang or crash.
- **Resource limits.** Runs already have timeouts and output caps; child jobs
  and subagents get an RSS ceiling through `ulimit -v` where the platform
  supports it, and the session refuses to spawn when free disk under `.shift`
  is below a floor.
- **Secret redaction.** Values of `.env` variables and anything returned by
  `op read` are replaced by `[redacted NAME]` in tool results, traces, logs
  and receipts before they are written.
- **Trace privacy defaults.** `trace-content` setting: `full` (today),
  `bounded` (prompts, reasoning, file contents and tool output clipped to 200
  characters), `off` (names and timings only). Default stays `full` for a
  single-user install; the setting exists so an exported trace can be safe.
- **Cross-platform.** A GitHub Actions workflow runs `make test` on Ubuntu.

## 6. Stable-runtime handoff

At development scale the handoff already exists in pieces: the TUI relaunches
the backend to switch sessions, and the checkpoint carries every durable
reference. `/upgrade` composes them: checkpoint, relaunch the backend against
the same session from the current install, and report the old and new source
identities. Trace spans record the runtime version alongside the generation.
The signed-artifact supervisor in live-updates.md stays future work; Homebrew
is the release channel.

## 7. The proof

`evals/live-repair/` holds a task set of behavior fixes (context selector,
prompt wording, tool routing) that can be solved either by `live_eval` or by
editing the agent file and reloading. `scripts/evals.py live-repair` runs each
task both ways in print mode and reports resolved rate, rounds, wall time and
whether the fix survived a reload. The claim it tests is the one in the README:
generation-attributed repair is faster and no less correct than
edit-plus-reload. Five tasks first; the number grows with the evidence.

## Order

1, 2, 3, 4, 5, 6, 7. The first two come straight from the incident and need no
model to run.

## Open questions

None that change the work.
