# Live context-selection demo

This demo begins with an intentionally bad Scheme context selector. It chooses
the 2024 Atlas runbook and answers `8080`. The user naturally challenges the
source, the agent explains and rewrites `agent-select-context` through
`live_eval`, reports the exact generation transition, and the retry uses
generation 2 plus the 2026 runbook to answer `9443`.

This demo image disables visible model thinking so the interaction stays short;
the default agent still streams thinking and content independently.

Start Dockerized Phoenix and enter the demo:

```sh
make phoenix
make demo-context
```

Paste the three prompts from `session.txt`, or run the complete script:

```sh
make demo-context-scripted
```

The memorable bit is not merely that the second answer is right. `/traces`
shows the current session's `context.select` RETRIEVER spans, their selected
file paths, and the generation attached to each answer. Phoenix shows the same
trace tree in the `shift` project at `http://localhost:6006`.

## Candidate checks

The demo image defines eight `agent-context-cases` covering independent port and
deployment queries, uppercase variants, and unrelated input. The deliberately
stale unpatched image is the baseline. Any patched candidate must pass all cases
before activation; a rejected patch leaves the current generation intact.
These are task quality checks, not a security boundary: an author can change the
image and its checks. `test/context.scm` independently checks the expected cases
and rollback under `make check`.

`make phoenix` reuses an already healthy local collector. Scripted input defaults
to source watching off; interactive and MCP sessions retain automatic watching.
