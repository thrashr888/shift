# Subagents as session folders, and project trace recall

Status: RFC, implemented in the same change. Decisions are listed; the only
open questions are ones that change the work.

The earlier direction, "fork the live image, not just the conversation", still
holds: a child inherits the parent's generation, patches and authority ceiling,
and returns inspectable artifacts rather than editing the parent. What changes
is the shape. The old supervised child ran through the Python MCP bridge, which
is gone. Children are now ordinary sessions that live in a folder under their
parent, the way Copilot lays out subagents, and the runtime schedules them as
background jobs so several can run at once.

## Layout

```text
.shift/sessions/default/
  session.json             the parent
  traces.jsonl
  agents/
    tests/                 a child: a complete session directory
      session.json
      traces.jsonl
      receipt.json         written when the child finishes
      progress.log         the child's tool narration (its stderr)
      agents/
        flaky-retry/       a grandchild, same shape, no special casing
```

A child's session name is its path from the sessions root:
`default/agents/tests`, `default/agents/tests/agents/flaky-retry`. Every
session command accepts these names (`--resume default/agents/tests` reopens a
finished child to ask follow-ups), the session list shows them nested under
their parent, and deleting a parent folder removes its whole tree.

## Spawn and join

`spawn` is a tool. It forks the live image into a new child folder and starts
the child as a background job:

```json
{"task": "Run make test and report failures with file:line",
 "name": "tests", "tools": ["read", "rg", "run", "job"],
 "history": false, "timeout_seconds": 600}
```

- `name` defaults to `agent-N`; it must be a plain session name.
- `tools` narrows the child's ceiling. It defaults to the parent's own ceiling
  and can never widen it; the ceiling is passed as `SHIFT_TOOL_CEILING` and
  stored in the child's `authority.json`, so it survives resume.
- `history` defaults to false: the child starts with an empty conversation and
  the task as its first prompt. `true` copies the parent's checkpoint so the
  child sees everything the parent saw.
- The child inherits the parent's mode and model; `model` overrides the model.
- Depth is capped at three levels. A fourth `spawn` is refused.
- Concurrency uses the job ceiling: at most four running jobs, children
  included.

The child runs `shift-agent --resume PATH --print TASK` with the parent's
project as its working directory, so it has the same files, plugins, skills,
MCP servers and allowlists. Its stdout is the answer and is captured as the
job log; its narration goes to `progress.log` in its folder. Because print mode
has no one to ask, a manual-mode child can only read, search and run
allowlisted commands; an autopilot child uses the judge like the parent would.

Joining is the existing `job` tool: `wait` blocks until the child finishes and
returns its complete answer plus the receipt path; `output` peeks; `cancel`
stops it. A finished child also raises the usual job notice, so the parent
hears about it on its next turn without polling. Several `spawn` calls in one
turn run in parallel and the parent joins them in any order.

## Traces

The parent records one `subagent.run` span per child, opened at spawn and closed
when the child exits, carrying the child's session name, job id, ceiling and
exit status. A `job wait` on a child records a `subagent.join` span with a link
to the run span. The child process receives `TRACEPARENT`, so its own turn and
tool spans nest under the parent's tool span in an OTLP viewer, and its local
`traces.jsonl` stays inside its folder. `recall` (below) searches across the
whole tree, so a parent can inspect a child's tool outcomes without reading its
transcript.

## Project trace recall

`recall` is a read-only tool and a `/recall QUERY` command that searches every
session's traces in the project, including subagent folders: a literal,
case-insensitive match over stored span JSON, newest first, bounded to the
requested limit. Each hit names its session, so `traces` with `span_id` inside
that session, or `--resume` of that session, gets the full detail. Filters are
the same as `traces` (`name`, `kind`, `status`, `errors_only`) plus `session`
to restrict to one session or subtree. It is prefetch-safe and allowed in plan
mode.

## Decisions

1. Children are full sessions in `agents/` folders, nested without limit in
   layout and capped at depth three in practice.
2. The child's conversation starts empty unless `history: true`; the live
   image (generation, patches, authority, settings) is always inherited.
3. Children are background jobs. No new scheduler: the job ceiling, notices,
   cancellation and the Log tab all apply.
4. Joining reuses the `job` tool. No separate `join` tool.
5. Children share the working tree. There is no workspace fork; parallel
   mutating children are the user's call, and a sandboxed session (`/sandbox`)
   already gives each run an isolated container when that matters.
6. The child's answer is the whole stdout, not a tail, bounded by the tool
   output limit.

## Open questions

None that change the work. Workspace forking per child (git worktrees) is the
obvious follow-up once mutating children are common.
