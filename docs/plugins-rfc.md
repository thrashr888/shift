# RFC: plugins

Status: draft, September 15, 2026. Decisions are proposed defaults; the open
questions at the end are the ones that change the work.

## Why

Shift already has every piece a plugin needs, each as data the user owns:
skills folders, MCP packs, pane packs, theme packs, scoped allowlists, and
validated live-image artifacts. What is missing is a way to ship them
together for one tool, install that bundle once, and turn it on per project.
The first plugins are for the tools already on this machine: agentkernel,
cider, cortex, alchemy, allbeads, tauri-browser, and 1Password.

## What a plugin is

A folder with a `plugin.scm` manifest, read like a pane pack and never
evaluated, plus the files it points at:

```scheme
((plugin "cortex" "0.1")
 (description "Repo-local memory the agent can recall and extend")
 (requires (command "cortex"))
 (mcp (server "cortex" (command "cortex" "mcp")))
 (skills "skills")
 (panes "panes.scm")
 (theme "themes/cortex.scm")
 (agent "agent/memory.scm")
 (allow-run ("cortex" "recall") ("cortex" "stats"))
 (env NOTE_TOKEN))
```

| Section | Contributes | Existing surface it lands on |
| --- | --- | --- |
| `requires` | commands that must be on `PATH`; a missing one marks the plugin unavailable with the reason, nothing else changes | `/plugins` listing |
| `mcp` | server forms, exactly as `.shift/mcp.scm` takes them | MCP packs, `tool_search`, `/allow-mcp` |
| `skills` | a folder of `NAME/SKILL.md` or flat `NAME.md` skills | skill sources, the Session tab |
| `panes` | a pane pack whose panes are appended after the project's own | `.shift/panes.scm` |
| `theme` | presentation packs selectable by `/theme NAME` | `themes/` lookup |
| `agent` | live-image artifacts under the restricted contract, loaded as a generation when the plugin is enabled and removed with it | `/extension-load`, generations, rollback |
| `allow-run` | argv prefixes proposed for the run allowlist, applied only at enable time and only at the scope named, after being printed | scoped `run-allow` |
| `env` | `.env` variables the plugin's servers or commands need, reported when missing | MCP `env` |
| `secret` | a name resolved from a secret source at connect time, never stored | MCP `env` and `header` |

CLIs are not shipped; a plugin declares the command it needs and teaches it
with a skill and, optionally, an allowlist proposal. Panes and themes are
the UI mods; the `agent` artifacts are the behavior mods. Python is never
part of a plugin.

## Where plugins live and how they are enabled

Discovery mirrors skills: `.shift/plugins/NAME/` in the project,
`~/.config/shift/plugins/NAME/` for the user, and a `plugin-dirs` setting
for checkouts elsewhere. A tool's own repository can carry its plugin at
`.shift-plugin/`, the way agentkernel carries `claude-plugin/`;
`shift-agent plugin add PATH|GIT-URL` copies or clones it into the user
folder, `plugin update NAME` pulls it again, and `--check-plugin [DIR]`
lints a manifest.

Installed is not enabled. `/plugin enable NAME [project|user]` records the
name in the `plugins` setting at that scope, unioned like the allowlists,
and prints exactly what the plugin contributes, including the `allow-run`
prefixes it adds. `/plugin disable NAME` removes those prefixes, the servers,
the skills and the loaded `agent` generation. Enabling is the one moment a
plugin can widen anything, and the user reads the list before it does.

## Secrets: the 1Password plugin

`(secret DOCS_TOKEN (op "op://Private/Docs/token"))` in a manifest, or in
`.shift/mcp.scm` directly, resolves through the `op` CLI when a server
connects, into the child's environment or a header, and never into a file
or a transcript. The runtime resolves secrets; the model never calls `op`,
and `op read` is refused by a fixed judge rule. The `onepassword` plugin
also ships a skill for the `op` CLI's non-secret operations.

## The first seven

| Plugin | Contributes |
| --- | --- |
| agentkernel | its existing skill and `/sandbox` command notes; `allow-run` for `agentkernel run`, `sandbox`, `exec`; a pane showing sandbox state; the MCP config `agentkernel plugin install mcp` writes, as a server form |
| cider | a skill for the `cider` CLI; `allow-run` for its read commands (`list`, `show`, `search`); writes stay judged |
| cortex | the `cortex mcp` server; `.cortex/skills` as a source; `allow-run` for `cortex recall` and `stats`; an `agent` patch that runs `cortex_context` at turn start and folds it into `agent-select-context` |
| alchemy | the embedded MCP server by URL; `allow-run` for the `alchemy` CLI's reads; the companion skill |
| allbeads | a skill for `ab` and `bd`; `allow-run` for `ab ready`, `ab list`, `bd ready`, `bd show`; a pane with `ab ready` and `bd ready` rows |
| tauri-browser | the `driving-tauri-apps` skill; `allow-run` for `tauri-browser`; a pane with snapshot and screenshot rows |
| onepassword | the `secret` source; a skill for `op` |

Each lives in its tool's repository under `.shift-plugin/` where the tool is
yours, and under `~/.config/shift/plugins/` otherwise.

## Implementation order

1. `(live-agent plugins)`: manifest parsing and lint, discovery, the
   `plugins` scoped setting, enable and disable with the printed contribution
   list; tests with a fixture plugin.
2. Contributions: MCP servers, skill sources, pane and theme packs, allowlist
   proposals, `agent` artifacts through the existing extension loader.
3. `secret` sources with the `op` resolver; the judge rule for `op read`.
4. `shift-agent plugin add|update|list`, `/plugin`, a PLUGINS section in the
   Session tab and a `(source plugins)` row.
5. The seven plugins, each in its repository, and the docs.

## Open questions

1. Should `agent` artifacts be allowed in plugins at all, given a plugin is
   third-party text? The draft says yes, because they go through the same
   validated-generation path as `/extension-load` and disable with the plugin.
2. Enable scope when none is given: project (the draft) or user?
3. Git URLs for `plugin add`, or paths only for now? The draft supports both.
4. Should `.shift/plugins/` in a project auto-enable, the way `panes.scm`
   auto-loads? The draft says no: installed is not enabled.
