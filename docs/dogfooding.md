# Dogfooding shift inside itself

The harness can now do useful work on its own repository without pretending it
is ready to replace a mature coding agent. The safe shape is a two-level loop:

1. Codex or the user is the supervisor and starts a durable `dogfood` session.
2. The inner agent uses `read`, `rg`, `write`, and exact `edit` inside this repo.
3. Shell still pauses for an explicit one-key approval.
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

Or, from Codex, use the project MCP tools to start session `dogfood` in `auto`
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
  `/recover restore`. There is still no end-of-turn receipt or diagnostics
  integration, so the supervisor reconstructs outcomes from tool output and traces.
- Long sessions now compact into a traced summary and can search pre-compaction
  trace evidence, and checkpoints can fork into generation-pinned children, but
  there is no token-budget policy, summary-quality evaluator, lossless
  event-sourced trajectory, or isolated workspace branch.
- Interrupted tools leave an explicit write-ahead record with manual
  retry/discard, and interrupted file mutations can be put back from their
  recorded pre-images. There is no exact mid-process continuation or
  deterministic replay, so a mutating retry may still be ambiguous.
- A supervisor can wait for or cancel one child, but there is no general
  background job model, provider retry, model fallback, parallel fan-out, or
  concurrent tool execution.
- Stable-runtime upgrades need the versioned supervisor/handoff described in
  `docs/live-updates.md`; only the user-owned live image updates in process.
- The Scheme evaluator and filesystem confinement need deeper adversarial tests,
  resource limits, secret redaction, and cross-platform validation.
- Durable checkpoints are local and gitignored under `.shift/`, with no
  built-in export or share workflow yet.

The milestone for broader dogfooding is not feature parity with Pi. It is being
able to complete a small repository change, resume after a restart, show the
generation and trace lineage, and let an external reviewer accept or reject the
diff without hidden state.
