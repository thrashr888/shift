# RFC: MCP client and tool search

Status: implemented September 13, 2026, with the answers recorded at the end:
lazy connection everywhere, MCP-only search, eight schemas per search, and
`.env` as the only secret source.

## Summary

Shift already serves MCP. This RFC makes it a client too: external MCP
servers, declared as data per project or per user, whose tools the model can
call under the same process-owned policy as built-ins. Their schemas never
sit in the system prompt: a `tool_search` tool returns the schemas that match
a query and enables them for the rest of the turn, so a session with forty
MCP tools costs the same context as one with none until a tool is wanted.

## 1. Declaring servers

Servers are data in `.shift/mcp.scm` (project, committable) and
`~/.config/shift/mcp.scm` (user), one form each, read like a pane pack and
never evaluated:

```scheme
((server "github"
   (command "npx" "-y" "@modelcontextprotocol/server-github")
   (env GITHUB_TOKEN))
 (server "docs"
   (url "https://docs.example.com/mcp")
   (header "Authorization" "Bearer $DOCS_TOKEN")))
```

- `command` starts a stdio server as a child of the session, the way `run`
  starts jobs: argv only, no shell, killed on exit.
- `url` speaks Streamable HTTP through the existing curl transport, keeping
  the `Mcp-Session-Id` an `initialize` answers with.
- `env NAME ...` lists environment variables the child inherits from the
  session's `.env`; nothing else of the environment is passed. `header`
  values expand `$NAME` from the same source. Secrets never live in the file.
- Names are `[a-z0-9-]{1,16}`, at most eight servers, project shadowing user.

`shift --check-mcp [FILE]` lints a file the way `--check-panes` does.

## 2. Connecting

A server connects lazily at the first `tool_search` or `/mcp connect NAME`,
not at session start, so a broken server never slows a session that does not
need it. `initialize` and `tools/list` run with a ten-second budget; a server
that fails stays listed as failed with its reason until `/mcp connect` retries
it. The Session tab's PEERS section grows a SERVERS block: name, transport,
state (idle, connected, failed) and tool count.

Tool names are `NAME__TOOL` (`github__create_issue`), which every provider
accepts and which keeps a server's tools from colliding with built-ins or with
each other. A server's tool that would shadow a built-in is refused at
`tools/list`.

## 3. Policy

MCP tools are not read-only unless the server says so through the MCP
`readOnlyHint` annotation, and even then plan mode treats them as reads only
when `destructiveHint` and `openWorldHint` are absent. So:

| Mode | MCP tool |
| --- | --- |
| manual | ask, like every other tool |
| plan | allow only tools annotated read-only, closed-world and non-destructive; deny the rest |
| autopilot | allow |

`/allow-mcp NAME__TOOL [project|user]` adds a tool to an allowlist with the
same three scopes as `run-allow`, so a project can commit that
`github__search_issues` never asks. The live image cannot widen any of this;
the list is a setting, not a generation binding.

Every call gets a `tool.NAME__TOOL` span with the server name, the `[peer]`
style Log entry, and the same bounded output (64 KiB, log path for the rest)
as built-ins. Results that carry images or resources are summarized as text
with their size; binary content is written under the session's `runs/` folder
and named, not inlined.

## 4. Tool search

The system prompt lists MCP servers by name with their one-line description
from `initialize`, nothing more. A new built-in tool:

```
tool_search {query}   → up to 8 matching tool schemas, now callable this turn
```

Matching is a case-insensitive substring over `NAME__TOOL` and the tool's
description, with `select:` for exact names, the way Claude Code's deferred
tools work. The matched schemas are appended to the enabled-tool set for the
remaining rounds of the turn, so the next provider request carries them; they
drop again at turn end, and the receipt lists which were enabled. A server
that is not connected yet connects during the search.

Built-ins stay always-on. The search covers only MCP tools, so nothing about
the coding loop changes for sessions without servers.

## 5. Interface

- `/mcp` lists servers, states and tool counts; `/mcp connect NAME`,
  `/mcp disconnect NAME`, `/mcp tools NAME`.
- SERVERS in the Session tab (and a `(source servers)` pane row); clicking a
  failed server retries it.
- `shift_status` for peers includes the server list, so a peer can see what
  the session can reach.

## Implementation order

1. `(live-agent mcp-client)`: the file format, lint, stdio and HTTP
   transports, lazy connect, `tools/list`, `tools/call` with bounded
   results; tests against a fake stdio server written in Python.
2. Policy rows, `/allow-mcp` on the scoped allowlist, spans and Log entries.
3. `tool_search`, the per-turn enabled set, receipt field.
4. `/mcp` commands, SERVERS section and source row, peer status.
5. Docs: daily-driver section, site note next to pane packs.

Each step leaves `make test` green and is usable on its own.

## Open questions

1. Lazy connect by default, or connect at session start for servers marked
   `(eager)`? The draft is lazy everywhere.
2. Should `tool_search` also cover built-ins once there are many, or stay
   MCP-only? The draft keeps built-ins always-on.
3. Cap on enabled MCP schemas per turn: eight per search, no total cap?
4. `.env` as the only secret source for `env` and `header`, or also the
   process environment? The draft says `.env` only, so a committed
   `.shift/mcp.scm` cannot read a variable the user did not put there.
