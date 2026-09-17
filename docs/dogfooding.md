# Dogfooding shift inside itself

The harness can now do useful work on its own repository without pretending it
is ready to replace a mature coding agent. The safe shape is a two-level loop:

1. Codex or the user is the supervisor and starts a durable `dogfood` session.
2. The inner agent uses `read`, `rg`, `write`, and exact `edit` inside this repo.
3. In manual mode every tool that is not an allowlisted `run` pauses for a
   one-key approval; plan mode permits only reads; autopilot allows everything
   and is the mode to use once the run allowlist is trusted.
4. Live-image changes are validated and hot-activate for the next turn.
5. Stable-runtime changes are only file edits. They do not enter the running
   authority boundary; the supervisor reviews the diff, runs `make check`, and
   restarts or resumes the session against the candidate runtime.
6. A useful behavioral repair can be exported as a disabled extension before it
   is promoted into reviewed source.

Start directly:

```sh
make dogfood
```

Or, from Codex, use the project MCP tools to start session `dogfood` in `manual`
mode, send a task, inspect its output, handle approvals explicitly, and resume
the same name after a restart. Multiple named sessions can test different live
prompts or models concurrently without mixing conversations or trace identity.

## A sensible first task

Ask the inner agent to inspect one small, testable seam—for example, add a
session-corruption test or improve one exact error message. Require it to name
the files it read, explain the proposed change, use `edit` rather than shell for
the source mutation, and stop after the edit. The outer supervisor then inspects
the diff and runs the tests. This exercises the actual product loop without
granting the inner model authority to accept its own runtime changes.

## What still blocks primary-agent use

- `status`, `diff`, `apply_patch`, and `run` now replace the shell for the
  inspect-change-test loop, with diff previews at approval, `/undo`, and
  `/recover restore`, and the end-of-turn receipt records changed files,
  commands, test outcomes and tokens. Failing runs lead with regex-derived
  diagnostics; there is no LSP integration.
- Long sessions now compact into a traced summary and can search pre-compaction
  trace evidence, checkpoints can fork into generation-pinned children, and
  `turn-token-budget` ends a runaway turn with a recorded reason, but there is
  no summary-quality evaluator, lossless event-sourced trajectory, or isolated
  workspace branch.
- Interrupted tools leave an explicit write-ahead record with manual
  retry/discard, and interrupted file mutations can be put back from their
  recorded pre-images. There is no exact mid-process continuation or
  deterministic replay, so a mutating retry may still be ambiguous.
- Background jobs, parallel subagents (`spawn`) and concurrent read-only
  tool calls exist now; children still share the working tree, and there is no
  model fallback.
- Stable-runtime upgrades need the versioned supervisor/handoff described in
  `docs/live-updates.md`; only the user-owned live image updates in process.
- The evaluator's allowlist is audited and the parsers fuzzed in the suite,
  secrets are redacted and traces can be bounded; job resource limits and
  symlink/race analysis remain open.
- Durable checkpoints are local and gitignored under `.shift/`, with no
  built-in export or share workflow yet.

The milestone for broader dogfooding is not feature parity with Pi. It is being
able to complete a small repository change, resume after a restart, show the
generation and trace lineage, and let an external reviewer accept or reject the
diff without hidden state.
