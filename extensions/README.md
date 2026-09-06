# Extensions

`shift/` contains trusted, shipped built-ins: Ollama, OpenAI, Claude, tracing, and MCP.
They are enabled by default, load only where needed, and can be excluded using
`SHIFT_BUILTINS`. They run outside the restricted live image and require restart
after edits. There is no package registry or automatic third-party discovery.

Top-level `*.scm` files are user-owned live behavior artifacts. They do not
load automatically. Use `/extension-load NAME` to apply one as a validated
generation and `/extension-disable NAME` to remove that exact patch. Successful
loads persist in named sessions.

Artifacts use the restricted top-level contract: `define`, `define*`, `set!`, or
`begin`, targeting `agent-*` or `extension-*` bindings. Existing artifact files
are never overwritten. An artifact cannot enable disabled trusted built-ins.
