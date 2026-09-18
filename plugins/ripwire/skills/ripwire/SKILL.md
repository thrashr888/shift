---
name: ripwire
description: Answer "who calls this", "is it safe to change", "which tests cover it" and "where do I start in this repo" from a call graph instead of grepping and reading files. Use before editing a symbol, when a test fails with a trace, and when landing in an unfamiliar codebase; not for Scheme, which it cannot parse.
---

# ripwire

ripwire parses the repo with tree-sitter (Python, TypeScript, JavaScript, Go,
Rust, Java, Ruby, PHP, C, C++, Swift, Kotlin, C#, Bash and more; not Scheme)
and answers from the call graph in one call. Its tools are MCP tools on the
`ripwire` server: find them with `tool_search` (for example
`tool_search "callers"` or `tool_search "ripwire"`) and call them by their
`ripwire__NAME` names. Every tool takes `path`: pass `"."` for the project.

When to reach for it instead of `rg` plus `read`:

- Landing cold or starting a task: `ripwire__explore` with `task` set to the
  task in words returns the ranked symbols, their bodies, their callers and
  the tests to run under one budget. `ripwire__for` is the signatures-only
  version.
- Before editing or deleting a symbol: `ripwire__find_referencing_symbols`
  for direct callers, `ripwire__impact` for the transitive blast radius,
  `ripwire__uses` for reads, writes and imports.
- A failing test or a stack trace: `ripwire__from_trace` with the trace text
  ranks the in-repo suspects innermost first.
- Which tests to run and what a diff forgot: `ripwire__situational_awareness`
  with the diff.
- A literal (an error string, a config key): `ripwire__grep`; each hit names
  the enclosing function.
- Before writing a new function or class: `ripwire__exemplar` gives the repo's
  best instance of that kind to imitate.

Read-only verbs run without asking. `ripwire__replace_symbol_body` and the
`insert_*_symbol` verbs edit files and go through the usual approval; prefer
`edit` and `apply_patch`, which the receipt and `/undo` track. Answers are
minified XML or JSON sized for a model; `budget_tokens` caps them.
