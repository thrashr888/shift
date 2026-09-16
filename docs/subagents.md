# Fork the live image: a subagent direction for shift

Status: smallest credible milestone implemented; parallel fan-out remains future
work.

The interesting move is not merely to let an agent spawn another chat. `shift`
can fork both conversation state and a validated behavior generation. A child
can then experiment with a prompt, context selector, model route, or extension
inside an isolated branch and return an inspectable artifact rather than
silently changing the parent.

## Child-run contract

A spawn captures this immutable envelope:

- parent session ID, turn, trace ID, generation ID, and fingerprint
- a bounded conversation checkpoint or compacted summary reference
- a snapshot of enabled tools and the stable authority ceiling
- an explicit task plus budget, cancellation token, and join policy

The child gets a new session and trace scope. It may create live patches and
extensions locally, but it cannot widen the parent's capability ceiling. Its
return value is structured:

```text
result              concise answer or patch proposal
trajectory_ref      child session/checkpoint reference
trace_ref           trace ID plus relevant span IDs
generation_ref      child generation and fingerprint
extension_proposal  optional disabled artifact to review/promote
```

This is “fork the live image, not just the conversation.” One subagent can test
a context selector while another keeps the baseline. The parent compares
recorded tool outcomes and evaluator spans, then selectively promotes the
winning extension into a new parent generation. No child code merges merely
because its prose says it worked.

## Trace topology

The root turn owns a `subagent.fanout` scope; each child owns a sibling
`subagent.run` scope; the join is a separate span with links to every child
result. Parent-child span IDs explain ownership, while links represent a real
fan-out/join DAG. Stable marks record spawn, checkpoint, compaction,
cancellation, recovery, and extension promotion.

This follows the useful boundary in [NeMo Relay's scope
model](https://docs.nvidia.com/nemo/relay/about-nemo-relay/concepts/scopes):
scopes own nested work and isolate concurrent context, but the application—not
Relay—still chooses and schedules the agent pattern. `shift` should own that
small orchestrator while keeping scope, middleware, and trace semantics
separable.

The [Trace Engineering
essay](https://x.com/marfinxx/status/2094016175617241109) motivates three
details worth preserving: distinguish the sequential trajectory from the
causal trace, classify side effects before execution, and write a recovery
record before mutating work. Raw traces should remain out of the prompt;
subagents exchange compact summaries and stable references, then use the trace
tool for bounded inspection.

## Implemented milestone

1. `./bin/shift-agent session-fork PARENT CHILD` atomically copies the bounded
   checkpoint into a distinct session identity, preserves the generation and
   fingerprint, and copies any durable authority ceiling.
2. The MCP bridge records `subagent.fanout`, `subagent.run`, and `subagent.join`
   spans. Run and join scopes contain explicit links rather than pretending the
   causal graph is a single sequential call stack.
3. `live_subagent_run` starts one child with a required, narrower tool list,
   waits up to its budget, cancels on timeout by default, and returns the
   structured envelope above. Its process receives `SHIFT_TOOL_CEILING`; the
   same ceiling is stored outside the live image in `authority.json`, survives
   resume, and cannot be widened by `live_eval`.
4. A child can return its child-only patches as a named, disabled extension via
   `proposal_name`. The supervisor stores it under the ignored child session
   state, never writes it into the project's extension directory, and never
   loads it in the parent. Promotion remains an explicit user or parent action.
5. The integration suite forks baseline and candidate children from the same
   checkpoint, loads a candidate extension only in the latter, and requires the
   same deterministic tool name and output evidence from both.

Example supervisor request:

```json
{
  "parent_session": "dogfood",
  "child_session": "selector-candidate",
  "task": "Use read to verify the selected runbook.",
  "tools": ["read", "traces"],
  "extension": "candidate-selector",
  "assert_tool": "read",
  "assert_output_contains": "production ingress",
  "proposal_name": "verified-selector"
}
```

The child has isolated conversation, generation, recovery, trace, and authority
state. Supervised runs accept only `read`, `rg`, `traces`, and `live_eval`;
`write`, `edit`, `shell`, and extension-management tools are excluded. The child
still shares the project filesystem, so a future workspace-fork layer should
precede concurrent mutating children. Supervisor fan-out/run/join spans are
local JSONL in this milestone; ordinary provider and turn spans keep using the
configured OTLP export.

Parallel fan-out is intentionally not included yet. The next step is scheduling
multiple children and joining them without weakening checkpoint isolation,
cancellation, write-ahead recovery, or causal trace identity.
