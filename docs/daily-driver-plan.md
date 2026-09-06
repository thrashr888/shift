# Daily driver plan

Agreed September 4–6, 2026. Build on the review fixes without adding a plugin framework.

1. Project-local state, explicit saved defaults, durable per-project input history.
2. Provider-neutral transcripts, built-in Claude, /model, /thinking, /effort, /fast.
3. One deterministic execution policy for manual, plan, accept, and conservative auto.
4. Visible context usage and token-budget preflight with recoverable compaction.
5. Built-in localhost MCP starts with the interactive session and shares its runtime;
   dedicated `shift --mcp` supports stdio. No PTY child for the new endpoint.
6. Thin TUI consuming the same controller, then dynamic local skills and project trace recall.
7. File/URL packs after the boundaries settle. MCP client and autonomous model approval
   execution remain deferred; approval models require shadow evaluation first.

Settings changes persist with named sessions. `/settings save` explicitly promotes
current preferences to project defaults; `/settings save user` promotes user defaults.
Up/down history must work before a TUI is introduced. `/fast` means provider fast
service, independently of thinking/effort. Unsupported controls must be visible.

Validation: deterministic provider and policy tests, PTY input history, cross-project
launches, resume/settings precedence, provider switching with tool results, long
conversations, and MCP interacting with the actual live terminal process. Then a
bounded native Claude smoke and local Phoenix trace verification. Never store keys.

## First slice delivered (September 6)

Project-local settings/history, Claude and model controls, normalized tool history,
deterministic approval modes, context budget preflight, and shared HTTP/stdio MCP
are implemented and validated. See [usage and validation](daily-driver.md).

Next slice: richer diff/undo and test interactions, TUI, dynamic skills and project
trace recall. Model-based approval execution and URL/file packs remain gated on
that foundation and their evaluations. No memory database or MCP client was added.
