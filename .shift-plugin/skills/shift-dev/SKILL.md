---
name: shift-dev
description: Build, test and debug Shift itself — the Guile module layout, the compiled-vs-source trap, running one suite instead of all of them, and where a new module has to be registered. Use when editing anything under src/live-agent, extensions/shift, or agent/.
---

# Working on Shift

## Layout

| Path | What it is |
| --- | --- |
| `src/live-agent/*.scm` | the permanent runtime: authority, transport, tools, session |
| `extensions/shift/*.scm` | trusted built-ins reached through `builtin-ref`, including tracing and the provider adapters |
| `agent/default.scm` | the live image. User-owned data, not runtime code: bindings here are what `live_eval` rewrites at runtime |
| `test/*.scm` | SRFI-64 suites |
| `test/*.py` | integration tests that drive `bin/shift-agent` against a fake provider |

## Build before you test

```sh
make build
```

`bin/shift-agent` and the tests load compiled modules from `build/` **and fall
back to source when a `.go` is stale**. The fallback is silent, so an edit you
forgot to compile does not fail — it just tests the old module in some paths
and the new one in others. Run `make build` after editing any `.scm` under
`src/` or `extensions/`. `make -n build` lists what is stale without compiling,
and the DEV pane shows the same thing.

## Tests

```sh
make test          # every Guile suite plus every Python test; ~3 minutes
make check         # the same target
```

`make test` runs longer than a default command timeout, so give it room or run
it in the background rather than assuming it hung.

One suite at a time:

```sh
guile -L src -L extensions -C build test/run.scm test/receipt.scm
```

This asks for approval every time and is meant to. `test/run.scm` loads
whatever path follows it, so allowlisting any prefix that reaches it would let
a file be written and then executed without approval — the shell boundary this
project keeps closed. `make build`, `make test`, `make check` and `make -n` are
allowlisted instead.

## Registering a new module or suite

- A new `src/live-agent/NAME.scm` is compiled automatically: the Makefile globs
  `CORE_SOURCES`.
- A new `test/NAME.scm` is **not** run automatically. Add `NAME` to the suite
  list in the Makefile's `test:` target or the suite never runs, and a green
  `make test` will mean nothing about it.
- A new `test/NAME.py` likewise needs its own `python3 test/NAME.py` line.

## Two traps worth knowing

**SRFI-64 tests after `test-end` are silently skipped.** Appending a case below
`(test-end "name")` leaves it unexecuted while the suite still reports success,
with the pass count unchanged. If a case you just added does not appear in the
output, check that it sits above `test-end`.

**Tool schemas are charged on every request.** Several integration tests pin a
tight `context-limit`, so lengthening a tool description in
`src/live-agent/tools.scm` can push an unrelated turn over its budget and fail
it with "Context still exceeds the budget". Put instructions the model needs
only after calling a tool in that tool's *output* rather than its description.

## Debugging a session

`traces.jsonl` in the session folder holds every span. In a session, the
`traces` tool searches it and fetches a span by `span_id`; outside one,
`python3 scripts/evals.py session NAME` gives a per-turn review with rounds,
failures, waits and judge disagreements.
