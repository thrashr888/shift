# Durability and prompt-cache strategy

`shift` has two related jobs: preserve enough evidence for an agent to recover
its reasoning after compaction, and avoid needlessly re-evaluating a large local
prompt on every turn.

## What is implemented

### Searchable trace history

`traces.jsonl` remains append-only. `/traces QUERY` scans the complete file,
filters to the stable current-session ID, and retains at most 12 compact newest-
first hits. The model tool accepts `query`, `name`, `kind`, `status`,
`generation`, `turn`, `errors_only`, and a limit up to 50. Each hit includes a
stable `trace_id` and `span_id`; pass `span_id` back to retrieve that full stored
span. The Codex MCP bridge exposes the same search and exact-fetch operations.

This is deliberately retrieval, not prompt replay. Search results are compact,
tool responses are capped at 64 KiB, and individual trace attributes are capped
at 4 KiB. A future index may accelerate large logs without changing this
contract.

### Cache-friendly request shape

Each provider request is assembled in this order:

1. generation-owned system message
2. persisted conversation history
3. volatile context selected for this turn
4. current user message

The first two items are the reusable prefix. Moving selected context after
history means a different retrieval result no longer invalidates the cache
immediately after the system message. Selected context is still omitted from
the durable provider history so stale file content does not accumulate forever.

Tool definitions are stable within two safety cohorts: ordinary turns omit
mutation tools, while explicit change-intent turns include them. We accept the
cache boundary between those cohorts rather than expose mutation authority on
an ordinary turn. A live generation change and a compaction checkpoint are also
intentional boundaries.

Claude caches nothing unless the request marks breakpoints, so every Claude
request sets `cache_control: ephemeral` on the system block, which covers the
tool definitions and system prompt, and on the final content block of the last
message, so the next request reuses the whole conversation prefix through
Anthropic's automatic lookback over earlier breakpoints. Thinking blocks never
carry a breakpoint. `cache_read_input_tokens` and `cache_creation_input_tokens`
feed the same `llm.prompt_cache.*` and `llm.token_count.*` attributes as OpenAI.
Prompts under Anthropic's minimum cacheable length simply report a miss.

OpenAI requests also carry a stable `prompt_cache_key` derived from the live
generation fingerprint and safety cohort. It stays consistent across resumed
sessions with the same prompt/tool image, while a behavior change deliberately
routes to a new cache lineage.

The Ollama request sends `agent-keep-alive` as `keep_alive`; the default is ten
minutes. This reduces cold reloads during interactive work without holding a
large model forever. Users can change it transactionally.

Every LLM span records:

- `prompt.cache.cohort`
- `prompt.cache.prefix_messages` and `prompt.cache.prefix_chars`
- `prompt.cache.dynamic_context_chars`
- `prompt.cache.tool_count`
- prompt/output token counts
- OpenAI cached-input, cache-write, and reasoning token counts when returned
- `llm.prompt_cache.status` (`hit` or `miss`) and `llm.prompt_cache.hit`
- uncached prompt tokens, so a partial hit is visible rather than binary only
- Ollama load, prompt-evaluation, generation, and total durations

OpenAI cache reuse is read directly from
`usage.prompt_tokens_details.cached_tokens`. Ollama does not return an equivalent
cached-token count here, so its reuse remains a hypothesis to validate from
repeated-request prompt-evaluation time, not a success claim. Backend, model
type, eviction, model switching, daemon restarts, and memory pressure may all
change the result.

In the live OpenAI smoke, the first long-prefix request reported
`cache=miss (0 tokens)` and the second reported `cache=hit (1280 tokens)`.
The hit span contained 1,753 prompt tokens: 1,280 cached and 473 uncached. This
is an observed example, not a guarantee for shorter prompts or a different
backend/cache window.

## What Tardigrade changes in the longer-term design

[Tardigrade's rationale](https://tardigrade.sh/docs/why) models agent behavior as
a projection of an immutable event log: pure state machines decide transitions,
an effectful runtime executes them, and outcomes are appended as new events.
Compaction is a checkpoint event plus a projected tail rather than destructive
replacement of the underlying history.

That is a useful target for `shift`, but it is not the current architecture.
Today, `session.json` is a mutable checkpoint, the audit journal and trace are
secondary records, and trace attributes are bounded. Therefore search can help
an agent recover old evidence, but it cannot provide deterministic replay or a
lossless source of truth.

The next durability step should be one canonical, versioned trajectory log for
user messages, model outputs, tool requests/outcomes, generation transitions,
compaction checkpoints, cancellation, and recovery decisions. `session.json`,
the model context, the Phoenix export, and the live UI should become projections
of that log. Effect IDs and idempotency rules must exist before automatic replay
of mutating tools is safe.
