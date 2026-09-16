---
name: cortex
description: Use the project's cortex memory: recall past learnings before work, save durable patterns, decisions and fixes after, and consolidate. Use when a task could benefit from what earlier sessions learned, or when something worth remembering was just established.
---

# cortex

cortex keeps two stores under `.cortex/`: `raw.db` for every observation this
session and `consolidated.db` for merged long-term patterns, plus generated
skill files under `.cortex/skills/` that Shift indexes as skills. The MCP
server this plugin registers exposes `cortex_recall`, `cortex_save`,
`cortex_context`, `cortex_stats` and `cortex_sleep`; find them with
`tool_search cortex`.

- Start of a task: `cortex__cortex_recall` with the task's key words, or on the
  command line `cortex recall "upload handler"`.
- Something durable learned: `cortex__cortex_save` with `type` pattern, bugfix
  or decision; add `global: true` for a personal preference that applies to
  every project.
- End of a long session: `cortex__cortex_sleep` consolidates and promotes
  cross-project patterns.

A project without `.cortex/` needs `cortex init` first; the server reports
that when it cannot start.
