---
name: alchemy
description: Collect sources into, and search across, the user's Alchemy research notebooks (a local-first NotebookLM). Use when asked to save a URL, file or note to a notebook, to find what a notebook says, or to answer from the user's own collected sources.
---

# alchemy

The Alchemy app must be running with its MCP server on; the CLI and the MCP
server share one notebook store, so writes appear live in the app.

```sh
alchemy notebooks --json                                  # ids and titles
alchemy search "renewal risk" --notebook "Project Atlas"  # one notebook
alchemy search "contractor agreement" --json              # every notebook
alchemy add report.pdf https://example.com --notebook "Project Atlas"
pbpaste | alchemy add --notebook "Project Atlas" --title "Meeting notes"
```

Over MCP (find with `tool_search alchemy`) the server also creates notebooks,
adds sources, runs hybrid search, writes notes and can attach Mac items such as
a Reminders list or a Note through a `cider://` origin. The server needs the
app's private token: copy `token` from the app's `mcp.json` into the project's
`.env` as `ALCHEMY_MCP_TOKEN`.
