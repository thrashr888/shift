# RFC: autopilot with a judge

Status: draft, September 13, 2026. Decisions are proposed defaults; the open
questions at the end are the ones that change the work.

## Why

Autopilot today allows every tool. That is the mode people actually run in,
so it is where the protection matters. The daily-driver plan deferred a
model-based approval step until it could be evaluated in the shadow of human
decisions; this RFC adds that step and the shadow evaluation together.

## How others do it

- **Claude Code auto mode.** A separate classifier model (Sonnet 5 by default,
  not the session model) reviews each action that no allow, ask or deny rule
  resolves. It sees user messages, non-read tool calls and CLAUDE.md, with
  tool results stripped so hostile file content cannot steer it. It blocks by
  category: escalation beyond the request, untrusted infrastructure, secrets
  leaving the repository, discarding uncommitted work, editing its own
  permissions or transcripts. A block hands the model the rule name so it tries
  another approach; three consecutive blocks or twenty in total pause auto mode
  and prompting resumes. Boundaries stated in conversation ("don't push") count
  as block signals. Verdicts are reused per host and port.
- **Codex.** No judge; safety comes from an OS sandbox (network off, writes
  confined to the workspace) and an approval policy that asks only when a
  command needs to leave the sandbox.
- **Cursor, Gemini CLI, OpenCode, Hermes.** Rule lists: allow and deny
  patterns for commands and paths, a protected set for deletes, and an
  all-or-nothing autonomous mode above them. Pi has no permission layer at all.

The Claude Code shape is the one worth copying: rules resolve the cheap
cases, a small separate model judges the rest against the user's intent, and
the judge is never shown tool output.

## Design

### Order of decision in autopilot

1. **Rules, process-owned.** Read-only tools allow. Allowlisted `run` prefixes
   and `mcp-allow` entries allow. A short deny list blocks outright:
   `rm -rf` on `/`, `~` or any path outside the project, `git push --force`
   to the default branch, `git reset --hard`, `git clean -f`, `git checkout --
   .`, `git stash drop|clear`, `curl … | sh`, and any write under `.shift/`
   other than `skills/`, `panes.scm`, `mcp.scm` and `settings.json`. Denies
   never reach the judge.
2. **Judge.** Everything else: mutations, runs, `live_eval`, `extension`,
   `shell`, MCP tools, `ui` patches. One request to the judge model, strict
   JSON back: `{"verdict":"allow"|"block","rule":"…","reason":"…"}`.
3. **Fallback.** A judge error, timeout (10 s) or unparseable answer is a
   block. Three consecutive blocks or twenty in a turn drop the session to
   manual for the rest of the turn, with a notice; approving once resumes.
   In print mode there is nothing to fall back to, so the action stays
   blocked and the receipt says why.

### What the judge sees

- The turn's user prompt and the last three user messages before it, verbatim.
- The tool call: name, arguments, and for mutations the diff stat and the
  first 40 lines of the diff; for `run`, the argv, cwd and whether the tree has
  uncommitted work (Shift runs `git status --short` itself, as Claude Code
  does, so the judge knows what a destructive command would discard).
- The project root, its git remotes at session start, the run allowlist, and
  the mode.
- Never tool results, file contents beyond the diff excerpt, or skill bodies.

The judge prompt is process-owned text in `(live-agent judge)`, versioned with
the runtime; the live image cannot change it.

### Block categories

Escalation beyond the request; work outside the project root or its remotes;
secrets or `.env` content leaving the machine; discarding uncommitted changes;
changing Shift's own policy, allowlists, transcripts or settings; network
targets not named in the request; and any boundary the user stated in
conversation. The judge returns the category as `rule`, which is what the
model reads back, so it can choose a different route rather than argue.

### Model

`judge-model` setting, `PROVIDER/MODEL`. Default: the session provider's
cheapest capable model (`claude/claude-haiku-4-5` on Claude, `gpt-5-mini` on
OpenAI-compatible servers when present, the session model on Ollama). The
judge request carries `prompt.cache.key` so its fixed prefix caches, and its
span, `judge.decide`, records verdict, rule, tokens and latency. The receipt
gains `judged`, `blocked` and `judge_ms`.

### Shadow mode first

`judge` setting: `off`, `shadow`, `on`. In `shadow`, manual mode still asks
you, but the judge also runs on every prompt and its verdict is recorded next
to yours. `/judge report` reads the traces and prints agreement: how often the
judge would have blocked something you allowed and allowed something you
refused, with the cases. Autopilot requires `judge on`; with the judge off,
autopilot behaves like manual for anything the rules do not resolve, so
"allow everything" stops being a mode at all. The evals driver gets a
`judge` subcommand that replays recorded prompts through a candidate judge
model and reports the same agreement numbers, so a cheaper model can be
compared before it becomes the default.

### Interface

The approval prompt and the TUI's pending-tool box show `judged: allow (rule)`
or `blocked: rule` with the one-line reason; the Log tab records blocks; the
Session tab's receipt lines show `judged n · blocked n`. `/judge` shows the
setting, model and this session's counts.

## Implementation order

1. `(live-agent judge)`: rules, the prompt, the request through the existing
   provider transport, JSON parsing, spans; unit tests with a fake provider.
2. Shadow mode in manual, trace records, `/judge report`.
3. Autopilot routing through rules then judge, the fallback thresholds,
   receipt fields, TUI surfaces.
4. The evals `judge` subcommand and a first agreement run on the recorded
   dogfood prompts.
5. Docs: tool policy section, README, index.

## Open questions

1. Default judge on Ollama: the session model is slow per decision; a small
   local model may be too weak. Ship with the session model and let
   `judge-model` override, or require an explicit choice before autopilot?
2. Should the judge see the diff excerpt at all, given it is model-written
   content? The draft says yes, capped at 40 lines, since edits are the
   decisions that matter most.
3. Thresholds: three consecutive, twenty per turn, as Claude Code. Fine?
4. Should `shadow` be the default in manual so agreement data accumulates
   from day one? It costs a judge call per prompt.
