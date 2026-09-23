# Daily-driver foundation

This is the first implementation slice of [the agreed plan](daily-driver-plan.md).
The terminal UI is the interactive default and shares the scripted session loop.
Cross-session trace recall, extension packs, and model-tested automatic approval
remain later work.

## Projects and settings

Run `bin/shift-agent` from the project you want to work on. Code loads from the Shift
installation; tools, `.env`, and `.shift/` state belong to your working directory.
An interactive launch resumes or creates the project's `default` session. Use
`--session NAME` for another session. Piped input remains ephemeral unless named.

```
/thinking on
/stream on
/model claude/claude-haiku-4-5-20251001
/model list
/effort high
/fast off
/settings
/settings save
/settings save user
```

Changes take effect on the next model request and persist with named sessions.
Preferences are data, not live Scheme patches, so changing a setting does not
increment the code generation or consume its 64-patch limit. `/settings save`
explicitly promotes effective preferences to defaults for new project sessions;
`/settings save user` writes `$XDG_CONFIG_HOME/shift/settings.json` (normally
`~/.config/shift/settings.json`). Precedence is session, project, user, agent image
or runtime default. Forks copy the parent's saved preferences. Live image changes
still use `/eval`, `/reload`, and `/rollback`; explicit preferences take precedence.

Up/down cycles through prompts and commands; down restores your unfinished draft.
The last 500 submitted inputs are kept in `.shift/input-history.jsonl`, separate
from conversation history. File locking coordinates concurrent session writers.
On close, a named session prints provider-reported token totals, its stable ID,
and a copyable `./bin/shift-agent --resume NAME` command.

`.env` is read as data without shell evaluation. Existing process environment
variables take precedence. Claude uses `CLAUDE_API_KEY`; OpenAI uses
`OPENAI_API_KEY`. Settings and checkpoints store only credential variable names.

## Providers and context

Claude is a built-in native Messages adapter, including streaming text, thinking,
signed thinking blocks, tool calls/results, and usage. Conversations normalize
Ollama's id-less tool messages so provider switching keeps call IDs intact.
Claude-only blocks are preserved for their originating model and omitted when
sending to another provider. Tool calls from truncated streams never execute.

`/model list` discovers the current provider's available models. `/model
PROVIDER/MODEL` selects a provider and its standard endpoint. Custom gateways can
be configured with the typed `agent-base-url` and `agent-api-key-environment`
settings in project `settings.json` before launch. The picker does not infer a
provider from an ambiguous model name.

`/effort` and `/fast` are independent. Known Claude models use `output_config.effort`
and `speed: fast`; known OpenAI reasoning models use `reasoning_effort` and
`service_tier: fast`. Unsupported preferences are retained but explicitly shown
as unavailable and omitted from requests. Fast service may incur premium pricing;
account access remains provider-controlled. OpenAI thinking is provider-managed;
use `/effort`. No separate thinking toggle is sent to OpenAI Chat Completions.

Capability mappings are deliberately conservative. See the current
[Claude fast-mode docs](https://platform.claude.com/docs/en/build-with-claude/fast-mode),
[OpenAI fast-mode docs](https://developers.openai.com/api/docs/guides/fast-mode), and
[Chat Completions schema](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create).

`/context` shows the last request's estimated input, known context limit, output
reserve, and reported usage. Estimates include tool schemas and message framing;
they are not tokenizer counts. The first request of each turn uses bytes/3.
Later tool rounds scale that estimate by the last provider-reported full prompt
count divided by the raw estimate for the same request. Cache reads count toward
context size. Missing usage retains the last calibration, and a new turn starts
fresh; summarizer usage does not change the tool-loop calibration. The 20% margin
and output reserve still apply. Claude's context window is discovered from the
account's model metadata. If a provider does not report its effective window,
the limit stays unknown; set `/context limit TOKENS` explicitly. Switching models
clears that explicit override. The JSON `output-reserve` setting defaults to 8192.

Before each tool-loop request, the runtime checks an 80% input-plus-output budget.
It summarizes earlier complete turns, retaining the current turn and tool chain.
If the retained turn or summarization request cannot fit, it pauses with a useful
error and preserves the original checkpoint. Message-count compaction remains a
fallback. `/compact` also works explicitly. Compaction is notes-first: before
the window resets, the harness asks the model to save progress, decisions,
unresolved work and exact paths with the `notes` tool (files under the
session's `notes/` folder, never in the project), then replaces the earlier
context with a pointer that lists those files and reminds it that `traces` and
`recall` reach earlier turns. If the model writes no note, the summary
compaction runs instead. Every compaction writes what it
replaced beside the checkpoint, `compactions/N.json` with the prefix and the
summary; `scripts/evals.py compaction` scores each summary by how many durable
facts from its prefix it still carries (edited files, failing commands, user
constraints), `--replay` re-summarizes the stored prefixes with the current or
`--model` model for comparison, and `scripts/evals.py session` flags a lossy
one. Raw usage and tool outcomes remain in
local traces, with Claude token counts exported to Phoenix.

## Tool policy

| Mode | Tool behavior |
| --- | --- |
| `/mode manual` (default) | Ask before each model tool execution, except runs already on the allowlist. |
| `/mode plan` | Allow reads/search/traces, `status`, `diff`, and extension listing; deny mutations. |
| `/mode autopilot` | Reads and allowlisted runs proceed; a fixed rule set refuses the destructive cases outright; everything else is judged by a separate model, and a block sends the model the rule so it takes another route. |

The same policy gates model tools, selected context reads, and recovery retries.
Shell `deny` and process tool ceilings still apply. Mode is process-owned data;
`live_eval` cannot change it. Explicit terminal slash commands are user operations.
Autopilot is an explicit choice; nothing infers approval from prompt words.

**The judge.** Autopilot resolves actions in three steps. Process-owned rules
first: reads and allowlisted runs and MCP tools proceed, and `rm -rf` outside
the project, force pushes, `git reset --hard`, `git clean -f`, `git stash drop`,
`curl … | sh` and writes into Shift's own state are refused without a model
call. Everything else goes to the judge: one request to a separate model with
the user's last four messages, the proposed action with a 40-line preview, the
project root, its git remotes, whether the tree has uncommitted work, and the
allowlist, never any tool output. It answers `allow` or `block` with a rule
name and a sentence; a block reaches the model as
`blocked by autopilot [rule]: reason` so it tries another way. A judge that
fails or does not answer is a block. Three consecutive blocks, or twenty in a
turn, pause the judge and manual prompting takes over for the rest of the
turn. `judge-model` picks the judge as `PROVIDER/MODEL`; unset, the session's
own provider and model judge. `judge-model typesafe/jev-1.13.0` uses TypeSafe's
Jev instead: a typed request (one allow-or-block choice plus one yes/no per
block category) that answers in about a quarter of a second with calibrated
probabilities, no text to parse, and a fixed category description as the
reason. It sends the judge the same evidence and nothing more, reads its key
from `TYPESAFE_API_KEY` or `~/.config/typesafe/api-key`, is never selected on
its own, and records `confidence` in every `judge.jsonl` line
([the RFC](jev-rfc.md) has the numbers). When Jev cannot answer, the session
model judges that action instead and the log line says so in `fallback`; a
rejected key, an empty balance, a missing key or a malformed request turns Jev
off for the rest of the session after one notice, and `/judge` shows why. In
autopilot an allow the typed judge is not sure of asks you instead of going
through: `judge-ask-below` (default 0.5) is the confidence under which that
happens, `#f` never asks, and in print mode such an allow blocks with the rule
`judge-uncertain` since there is nobody to ask; the receipt counts them as
`judge_asked`. With the typed judge on, two more decisions use it: `tool_search`
sends the word-ranked candidates (names and descriptions only) to Jev and keeps
those it is at least half sure do what the query asks, in that order, falling
back to the word order when none clears the bar; and each user turn asks Jev
once which offered skill, if any, is the procedure for the request, adding one
`<skill_relevance>` line to the prompt when it is confident (the trace records
`skill-hint`). The
`judge` setting is `shadow` by default: the
judge decides in autopilot, and in manual mode it also runs beside every
prompt, its verdict shows in the approval preview, and both answers go to the
session's `judge.jsonl`; `/judge report` prints agreement and the cases that
disagreed. `/judge on` keeps the judge for autopilot without the manual-mode
shadowing; with `/judge off`, autopilot asks for anything the rules do not
resolve, so nothing runs everything unattended. The
receipt records `judged`, `blocked` and `judge_ms`, and blocks land in the Log
tab as `[judge]` entries. Each `judge.jsonl` record also stores the action's
arguments, the run preview and the user messages the judge saw, so
`scripts/evals.py judge --session NAME` can replay a session's decisions
through any judge model (`--model PROVIDER/MODEL`) and report agreement with
your answers, false blocks and false allows; `--cases` runs the fixed set in
`evals/judge/cases.jsonl` and fails on any disagreement. `scripts/evals.py
session NAME` (or `--all`) prints a per-turn review of a session: rounds, tool
failures, repeated calls, minutes spent waiting for approval, judge
disagreements and turns that ended at a limit. Every answer you give an approval prompt (`y`, `a`,
`n`, Esc or a typed reply) lands there too as an `[approval]` entry naming the
tool and its subject.

## File changes

`read` output begins with `# PATH · N bytes · sha256 PREFIX`. The session ledger at
`.shift/sessions/NAME/changes.jsonl` remembers the last hash it saw for every path
that was read, edited, or written. A `write` or `edit` against a file that changed
on disk since then fails before approval and names the turn that saw it; read the
file again to continue. Mutations are prepared without touching the project, shown
as a unified diff with a diffstat at the approval prompt, journaled with their pre-
and post-images under `blobs/`, and committed atomically only if the file still
matches the prepared pre-image.

`/undo` reverts the most recent turn that still has changes: every file that turn
touched must still match its recorded post-image, otherwise the command refuses and
names the diverged files, and there is no force flag. Files the turn created are
removed and files it deleted come back. Repeating `/undo` walks back one turn at a
time, and a system message tells the model what was reverted. `/undo` never touches
git. After a crash or cancellation mid-mutation, `/recover` lists the in-flight
files with their recorded and current hashes, and `/recover restore` puts back any
file that carries the interrupted post-image, leaves untouched files alone, and
keeps the record when a file matches neither.

Every turn ends with a receipt, and `/receipt` reprints the last one (for a
resumed session, from its `receipts.jsonl`):

```
turn 3 · claude-sonnet-5 · generation 1 · 4 rounds · 2,445 in (1,900 cached) + 611 out · 6.1s
changed  src/app.rs (+14 −3)  tests/app.rs (+22 −0) new
ran      cargo test -- session  exit 0  4.8s
undo     available (/undo)
trace    3f9a1b2c… span 8c21aa00…   resume ./bin/shift-agent --resume dogfood
```

The files and diffstats come from the ledger, the `ran` lines from its run
records, the tokens and rounds from the turn's provider usage. Failed and
cancelled turns get a `status` line with the reason and still list whatever
committed before the interruption. The same record is appended as JSON to the
session's `receipts.jsonl` and attached to the `agent.turn` span as `receipt.*`
attributes, so `/traces` shows it too. The JSON shape is in
[the coding workflow RFC](coding-workflow-rfc.md#9-receipt).

`run` executes one program from an `argv` list with no shell, an optional
project-relative `cwd`, and a `timeout_seconds` up to 600 (default 120). stdout and
stderr are captured together; the full log is saved under the session's `runs/`
directory and the result carries the first 16 KiB and last 48 KiB, the exit code or
signal, the duration, and any previously read files the command rewrote. A timeout
or Ctrl-C sends SIGTERM, then SIGKILL after two seconds, and always reaps the child;
only the direct child is signalled, while Ctrl-C in a terminal also reaches its
descendants through the process group. The child receives `TRACEPARENT` for the
tool span. Every run is journaled with agentkernel-shaped `invocation` and `outcome`
records. Settings `run-backend` (`local` or `agentkernel`) and `run-sandbox` route
argv through `agentkernel exec SANDBOX --workdir /workspace/CWD -- ARGV` instead,
so the project must be mounted at `/workspace` in that sandbox. agentkernel 0.20
does not pass a failing command's exit code through: it exits 1 and folds the
output into an `Error: Command exited with code N:` line, which Shift unwraps
back into the real exit code and output. The `agentkernel` on `PATH` must be
that version or newer; a stale `cargo install` in `~/.cargo/bin` shadows the
Homebrew one.

`/sandbox NAME` turns that on for the session (`/sandbox off` turns it off,
`/sandbox` shows the state) and then leans on the sandbox the way Codex does: a
run that will execute inside it needs no approval in manual mode and no judge
in autopilot, because the sandbox is the boundary. Commands whose argv starts
with a `run-host` prefix stay on the host and are approved or judged like any
other run; the default list is `git`, `cargo tauri`, `codesign`, `xcodebuild`,
`xcrun`, `notarytool`, `open`, `swift`, `swiftc` and `brew`, the tools a Tauri
or macOS build needs from the host toolchain and the one that needs your
signing keys. On this Mac agentkernel runs Linux containers, so a Tauri app's
frontend tests fit the sandbox and its `cargo tauri build` does not; the
prefix list is what keeps both working in one session. The approval preview
says `in agentkernel sandbox NAME` when a run is headed there.

Every mode except plan asks before a run. The answer `a` approves it and adds the
exact argv to this session's allowlist. The allowlist has three scopes that
union, the way Claude Code's permission rules do: user
(`~/.config/shift/settings.json`), project (`.shift/settings.json`, committable,
so a repository can ship the commands its panes and tests need) and session.
`/allow-run "cargo test"` allows a prefix for this session; add `project` or
`user` to persist it there, quotes optional. `/run allow cargo test` is the
session form, `/run deny cargo test` removes a prefix from every scope holding
it, and `/run list` shows each prefix with its scope. Allowlisted prefixes run
without asking in manual, where every other tool still asks; autopilot never
asks. Prefixes match exact leading elements only. `/settings save` promotes the
whole effective list to that scope. This repository's own `.shift/settings.json`
allows `git status`, `git log` and `make test` for its SHIFT pane. MCP
callers cannot approve or extend it.

The `coding` built-in provides `status`, `diff`, `apply_patch`, and `run`. `apply_patch`
takes one unified diff in the exact `--- a/PATH`, `+++ b/PATH`, `@@` form that
`git diff` and `diff -u` emit, with `/dev/null` for creates and deletes. Hunks must
match their context exactly, with no fuzz; a rename is applied as a delete plus a
create; and the whole patch is prepared in memory, previewed, and committed as one
unit, so a failure in any file leaves every file untouched. `status` reports the git branch
and dirty count, files shift changed this turn and this session with diffstats, and
dirty files shift did not touch. It also reports `last undo: none` or the most
recently undone turn, including after reopening the session. Failed undo attempts
and later edits leave that value unchanged. `diff` takes `scope` `turn` (default), `session`, or
`git` (working tree against HEAD) and optional `paths`. Both are read-only, work
without git, spawn `git` and `diff` without a shell, and are bounded at 64 KiB.
A failing `run` leads with `diagnostics (N):`, the locations its output points
at, read with regular expressions: `path:line:col: message` from compilers,
guild and linters, Python traceback frames, pytest and unittest failure lines,
cargo `-->` locations and make errors. The receipt lists them per run and the
Log tab shows them under the run. Omit `coding` from `SHIFT_BUILTINS` to remove
the tools.

`make build` compiles the runtime into `build/`; `bin/shift-agent` and `make test` load
those modules and fall back to source, with a note, when a file is newer than its
compiled form. `bin/shift-agent` runs `make build` itself before launching, so the cache
is refreshed after a pull without any notes about stale modules.

## Skills

A skill is a folder with a `SKILL.md` in the Agent Skills format: YAML
frontmatter with `name` (1–64 lowercase letters, digits or hyphens, equal to the
folder name) and a one-line `description` (≤1024 characters), then Markdown
instructions (≤32 KiB), with any supporting files beside it. Shift reads skills
from `.shift/skills/`, `.agents/skills/` and `.cortex/skills/` in the project
(the last is where cortex writes its consolidated patterns as flat `NAME.md`
files, which count as skills too), then `~/.config/shift/skills/`,
`~/.agents/skills/` and any folders listed in the `skill-dirs` setting; a
project skill shadows a user skill of the same name. Skills other agents already installed in
`.agents/skills` therefore work unchanged. Nothing in a skill is evaluated, and
`disable-model-invocation: true` is the only optional field that matters: it
keeps a skill out of the model's index so only you can load it.

Skill folders may sit directly in a source or one level down in category
folders, the way Hermes lays out `~/.hermes/skills/category/skill`. The model
sees a `<skills>` index of names and descriptions in its system message and
loads a body with the read-only `skill` tool, which returns the instructions
and the folder; `skill` with a `path` returns one supporting file, and `read`
accepts paths under a valid skill folder too, so `references/` and `scripts/`
are reachable without widening the project boundary. `/skills`
lists every skill with its source, validity and loaded state; `/skill NAME`
(Tab-completes) sends a skill with your next prompt, wrapped in a
`<skill name="…">` block that stays in history. The Session tab's `SKILLS`
section shows the same list with `●` for loaded skills; clicking an unloaded row
runs `/skill NAME`. `/learn NAME [notes]` asks the model to write the
procedure it just carried out as `.shift/skills/NAME/SKILL.md`, through the
normal `write` path and its approval, so a session that worked out a workflow
leaves a committable skill behind. The receipt records `skills` loaded in the turn, and
`receipt.skills` lands on the turn span. Loading a skill never changes tool
policy: the `skill` tool is read-only, so plan mode allows it and manual mode
asks like any read.

## Background jobs

`run` accepts `background: true`: the command starts, the tool returns at once
with a job id (`job-N`), and the process keeps running under the session with
its output streaming to `runs/job-N.log` in the session directory. Foreground
runs keep the 600 s ceiling; a background job may set `timeout_seconds` up to
3600, and at most four jobs run at once. The approval prompt and the run
allowlist apply exactly as for a foreground run. The `job` tool takes `action`
`list`, `wait` (blocks up to `timeout_seconds`, default 60), `output` (the
bounded tail so far) or `cancel`; `/jobs` and `/jobs cancel ID` are the user
forms. When a job finishes, the ledger gets one run record carrying the job id,
the receipt of the turn it finished in lists it, and the model receives a
one-line harness note at its next request, in this turn or the next. Jobs die
with the process: `/cancel` leaves them running, but quitting kills them, and
nothing is daemonized.

The Log tab shows a `RUNNING` block above the run history while jobs run, with
elapsed time and the last output line, and each finished job joins the history
as a `[job]` entry. Pane command rows run as background jobs, so the interface
never blocks on `make test` and the output lands under the row when the job
ends.

In one model round, read-only tool calls (`read`, `rg`, `status`, `diff`,
`traces`, `recall`, and `job list`/`output`) that the policy already allows without asking
execute concurrently, four at a time, before their results are recorded and
returned in the model's order; their spans carry `tool.parallel`. Mutations,
runs and anything that could prompt stay sequential.

## Subagents

`spawn` starts a child on a task and returns at once. The child is a complete
session in a folder under the parent, `sessions/NAME/agents/CHILD/`, nested
again for grandchildren, and it appears in the session list under its parent.
It inherits the parent's generation, patches, mode, model, settings, project,
skills, plugins and MCP servers; its conversation starts empty unless
`history: true` copies the parent's. `tools` narrows the child's ceiling and
can never widen it; the ceiling is stored in the child's `authority.json` and
honoured when the child is resumed by hand (`--resume default/agents/tests`).
Children run as background jobs, so the four-job ceiling, `/jobs`, the Log tab
and job notices all apply, and `job wait` returns the child's complete answer
plus its receipt path. Nesting stops at depth three. Children run unattended:
a manual-mode child can only read, search and run allowlisted commands, while
an autopilot child uses the judge. The parent's trace carries a `subagent.run`
span per child and a `subagent.join` span per wait; the child's own spans nest
under the parent's via `TRACEPARENT`.

## Workflows

A workflow is a durable multi-step procedure kept as data under
`.shift/workflows/NAME/workflow.scm`, committable like panes and settings and
never evaluated:

```scheme
((workflow "release-check" 1)
 (description "Verify a checkout before tagging a release")
 (budget (rounds 20))
 (step "status" "Run git status --short and report whether the tree is clean." (check (contains "clean")))
 (step "tests" "Run make test and report the outcome." (check (run "make" "test")))
 (step "notes" "Write release notes for the last five commits to the note release.md."
       (check (notes "release.md")) (check (judge "the notes name the last five commits"))))
```

`/workflow run NAME` runs the steps as ordinary turns of the session, so
approvals, the judge, receipts and traces all apply. After each step its checks
run: `run` must exit 0, `contains` looks in the step's answer, `file` and
`notes` must exist, and `judge` asks the judge model whether the answer
establishes the criterion. Jev answers a typed question with a probability
that the record keeps as confidence; the session model answers a JSON verdict
when Jev is not configured or cannot answer, and a check with no judge fails
rather than passes. The first failed check, a failed or limited turn, or a
spent round budget ends the run; later steps are skipped. One record per run
lands under `runs/N.json`, the sidebar's WORKFLOWS tab shows every workflow
with its last run and follows a run step by step, `/workflow` lists them and
`/workflow NAME` shows steps, checks and recent runs. In print mode,
`--print "/workflow run NAME"` runs one unattended and exits 0 only when it
resolved. The `workflow` tool gives the model the same list and show, and its
`run` starts the workflow in a subagent so a long procedure does not fill the
parent's window.

Workflows come from three places, first one wins: the project's
`.shift/workflows`, the user's `~/.config/shift/workflows`, and any enabled
plugin that declares `(workflows "workflows")` in its manifest. The tab and
`/workflow` name the source when it is not the project. Runs, versions and a
promoted copy always land in the project folder, so improving a plugin's
workflow leaves a project override and never touches the plugin. The list
follows the folders: drop a new `NAME/workflow.scm` into any source, or edit
one, and the WORKFLOWS tab shows it within the watcher's half-second tick,
the same tick that reloads `panes.scm`. This repo ships four:
`checkout-health`, `site-check`, `eval-review` and `pre-commit`, plus
`bench-smoke` for the Harbor adapter.

Three things run beside workflows and make sessions improve on their own.
After every turn, each tool rejection becomes one line in
`.shift/skills/field-notes/SKILL.md`, a skill the skill tool never offers
because every turn's system prompt already carries it, so a quirk hit once
(an argv shape, a path rule) is known in the next session; edit or delete
lines as you like, or set `field-notes false`. A hard turn, one that ended
at a limit, repeated the same call twice over, or took three rejections,
gets one reflection exchange that may propose a field note or a skill; a
proposed skill is written disabled (`disable-model-invocation: true`, listed
by `/skills`) and nothing is ever overwritten; `reflection false` turns it
off. `/workflow improve NAME` asks for one change to a workflow that has run
before, runs the current and the changed file in two subagents, and keeps
the change only when it resolves in no more rounds, with every attempt,
kept or not, recorded under the workflow's `versions/`.

## Trace recall

`recall` and `/recall QUERY` search the traces of every session in the
project, subagent folders included: a literal, case-insensitive match over
stored span JSON, newest first, bounded by `limit`. Each hit names its session,
so `traces` with `span_id` inside that session, or resuming it, gets the full
detail. `session` restricts the search to one session or its subtree; `name`,
`kind`, `status` and `errors_only` filter like `traces`. It is read-only,
prefetch-safe and allowed in plan mode.

## Plugins

A plugin bundles the data Shift already treats as yours: a folder with a
`plugin.scm` manifest, read like a pane pack and never evaluated, that names
MCP servers, a skills folder, a pane pack, theme packs, live-image artifacts,
run and MCP allowlist proposals, the `.env` names it needs, and secret sources.

```scheme
((plugin "cortex" "0.1")
 (description "Repo-local memory the agent recalls and extends")
 (requires (command "cortex"))
 (mcp (server "cortex" (command "cortex" "mcp")))
 (skills "skills")
 (agent "agent/memory.scm")
 (allow-run ("cortex" "recall") ("cortex" "stats")))
```

Plugins are found in `plugins/` of the install (the bundled ones: agentkernel,
cider, cortex, alchemy, allbeads, tauri-browser and onepassword),
`~/.config/shift/plugins/`, the folders in the `plugin-dirs` setting,
`.shift/plugins/` in the project, and a repository's own `.shift-plugin/`;
later sources shadow earlier ones by name. Installed plugins are on: their
servers register (and connect lazily), their skills join the index with source
`dir`, their panes append after the project's, their themes answer `/theme`,
their allowlist proposals join the allowlist under the `plugin` scope without
being written anywhere, and their `agent` artifacts load as generations the way
`/extension-load` does. A plugin whose `requires` command is missing from
`PATH` shows as missing and contributes nothing. `SHIFT_PLUGINS=off` in the
environment starts a session with no plugins at all.

`/plugins` lists them; `/plugin disable NAME [project|user|session]` turns one
off at that scope and `/plugin enable` back on, with the user's answer
overriding the project's and the session's overriding both; a disabled
plugin's servers, skills, panes, prefixes and artifacts leave at once. The
Session tab's PLUGINS section (also a `(source plugins)` pane row) toggles a
plugin for the project by click. `shift-agent plugin add PATH|GIT-URL` copies
or clones a plugin into the user folder, `plugin update NAME` pulls it again,
`plugin list` shows what is installed, and `--check-plugin [DIR]` lints a
manifest.

`(secret NAME (op "op://vault/item/field"))` resolves through the `op` CLI
when a server connects, into that server's environment or `$NAME` header, and
is cached for the process only; a fixed judge rule refuses `op read` and its
kin so the model never sees a secret.

## MCP servers as tools

Shift is an MCP client as well as a server. Servers are data in `.shift/mcp.scm`
(project, committable) and `~/.config/shift/mcp.scm` (user), one form each,
read like a pane pack and never evaluated; a project server shadows a user
server of the same name, and `./bin/shift-agent --check-mcp [FILE]` lints a file.

```scheme
((server "github"
   (command "npx" "-y" "@modelcontextprotocol/server-github")
   (env GITHUB_TOKEN))
 (server "docs"
   (url "https://docs.example.com/mcp")
   (header "Authorization" "Bearer $DOCS_TOKEN")))
```

`command` starts a stdio server as a child of the session with a minimal
environment plus the named `env` variables; `url` speaks Streamable HTTP and
keeps the `Mcp-Session-Id`. Secrets come only from the project's `.env`: `env`
names are copied from there and `$NAME` in a header expands from there, so a
committed file cannot read a variable you did not put in `.env`. Servers
connect lazily, at the first `tool_search` or `/mcp connect NAME`, with a
ten-second budget; a failure is kept with its reason until you retry.

Tools are named `SERVER__TOOL`, a server tool that would shadow a built-in is
refused, and their schemas never sit in the system prompt: the model sees only
server names and one-line descriptions, calls `tool_search` with a few words
(or `select:SERVER__TOOL`), and the matching tools, up to eight, become
callable for the rest of the turn. The receipt lists them as `mcp_tools`.

Policy treats an MCP tool like any other: manual asks, autopilot allows, and
plan allows only tools the server annotates as read-only, non-destructive and
closed-world. `/allow-mcp SERVER__TOOL [project|user]` puts a tool on the same
scoped allowlist as runs, so a project can commit that `github__search_issues`
never asks. `/mcp` lists servers, `/mcp connect NAME`, `/mcp disconnect NAME`
and `/mcp tools NAME` manage them, and the Session tab's SERVERS section (also
a `(source servers)` pane row) shows state and tool counts; clicking a server
that is not connected connects it. Results are bounded to 64 KiB; images and
other non-text content are named with their type and size, not inlined.

## Secrets and trace privacy

Values loaded from the project's `.env` and anything `op read` returns for an
MCP server are registered as secrets when the process sees them. Every tool
result, run log, trace attribute, event record and receipt has them replaced by
`[redacted NAME]` before it is written or shown, so a model that prints a token
never sees it and a shared trace never carries it. Values shorter than six
characters are left alone. The `trace-content` setting (`/settings
trace-content bounded`, or `--set`) decides how much prompt and output text
traces keep: `full` (default), `bounded` clips content attributes to 200
characters, `off` keeps names, timings, token counts and errors only.

## Upgrading the runtime in place

`/upgrade` is the development-scale runtime handoff: the session checkpoints,
jobs and servers stop, and the backend execs the launcher from the current
install against the same session and the same pipes, so a `brew upgrade` or a
`git pull` takes effect without leaving the conversation. The TUI resets its
view exactly as a session switch does and then reports `Runtime upgraded: OLD
→ NEW`. Every trace span carries `runtime.version`, a git label for a checkout
or the Cellar version for a brew install, next to the generation that shaped
it, and the events log records the handoff.

## Print mode and unattended runs

```
./bin/shift-agent --print "Add a test for the parser" --mode autopilot \
  --model claude/claude-sonnet-5 --set agent-max-tool-rounds=40 --set turn-token-budget=400000 \
  --session task-17
```

`--print TASK` (or `-p`) runs one task with no prompt loop and no stdin: the
banner, thinking, and `assistant>` prefix are omitted so stdout is the answer
alone, the receipt and the usual close message go to stderr, and the exit
status is 0 for a completed turn, 1 for a failed or cancelled one, and 2 for a
startup error. `--receipt FILE` writes the turn's receipt as one JSON object
to FILE, which is how the eval driver reads a task's outcome. It
implies `--no-watch` and starts no MCP endpoint. Approval prompts cannot be
answered, so anything that would ask is denied; use `--mode autopilot` for edits
and runs, or stay in manual with `--allow-run "ARGV PREFIX"` (repeatable) for the
only commands the task may run. These
flags seed the session's settings exactly as `/mode`, `/run allow`, `/model`, and
`/settings` would, and `--set KEY=JSON` accepts any settings key.

Every tool call is echoed as `tool> NAME SUMMARY` followed by a `✓` or `✗` line
with the first line of its result, so a session shows what the model did even
when nothing needed approval. In print mode the echo goes to stderr. One
setting, `show-work`, covers everything Shift prints about its own work between
the prompt and the answer: the tool echo and the receipt text. `/work off` and
`/work on` toggle it, `/tools` lists the enabled tools with its state, and
`--set show-work=false` does the same for an unattended run. Receipts are
still recorded in `receipts.jsonl` and to `--receipt FILE` either way, and
`/receipt` shows the last one on request.

Two turn limits exist. `agent-max-tool-rounds` now goes up to 64 and can be set
per session. `turn-token-budget` caps the uncached prompt tokens plus completion tokens one
turn may spend across its tool rounds, so cache reads do not count; either limit ends the turn as a failure, keeps
the conversation unchanged, and journals a `turn-limit` event with the reason.
Files the turn already changed stay changed and remain undoable. Before either
limit lands, once per turn, when three rounds remain or the budget is 80%
spent, Shift appends a user message telling the model to stop exploring, write
its fix, run one test, and answer. The message is sent for the rest of that
turn only, never persisted into the session history, journaled as
`turn-nudge`, and shown as `shift> … asked the model to finish` when
`show-work` is on.

With Ollama, `context-limit` is also sent as the request's `num_ctx`, so the
window Shift budgets for is the window the server allocates; Ollama would
otherwise truncate the prompt silently. Ollama reports no cache reads, so the
turn budget counts every round's whole prompt.

Provider requests that fail with 429, 5xx, or a connection error before any
of the response was consumed are retried with exponential backoff (1s, 2s,
4s, capped at 30s, or the server's `Retry-After` if longer). `provider-retries`
sets the limit (default 3, 0 disables) and each retry is shown as
`provider 429 · retrying in 1.0s (attempt 2 of 4)` and recorded on the LLM
span as `llm.retries` and `llm.retry_log`. A stream that already produced
output is never replayed. Non-retryable failures now report the HTTP status
and the response body instead of only curl's exit code.

## Live MCP

An interactive session starts a built-in HTTP MCP server in the same Guile process:

```
http://127.0.0.1:7331/mcp
```

Use `--mcp-port PORT` for another fixed port (also starts HTTP for piped sessions),
`--no-mcp` to disable it, or omit `mcp` from `SHIFT_BUILTINS`. A port collision fails
clearly; it never attaches to another session. The endpoint stops with the session.
There is no daemon, PTY child, or separate MCP executable behind this endpoint.

Tools: `shift_status`, `shift_prompt`, `shift_inspect`, `shift_cancel`. Status reports
the actual PID, project, session, settings, generation, and turn. Terminal and MCP
share one controller. Simultaneous mutations return a busy error; status remains
available. MCP prompts use the current mode. Actions requiring interactive approval
are denied to MCP callers; approve those operations from the terminal instead.
Read-only inspection cannot invoke `/eval`, change modes, or inject slash commands
through the prompt tool.

The HTTP server binds loopback only and validates Host and Origin. Set
`SHIFT_MCP_TOKEN` to require a Bearer token from clients. GET returns 405: this server
uses JSON responses to Streamable HTTP POST requests, without a notification stream.

There is no stdio transport and no separate MCP process: the session you have
open is the server, and clients attach to its URL. `.codex/config.toml` in
this repository registers it that way.


## Validation on September 6, 2026

- 162 Scheme assertions and 26 Python integration/regression tests passed;
  all 25 Scheme modules compiled. Ruff and `git diff --check` passed.
- PTY tests exercised up/down, unfinished-draft restoration, history after restart,
  project/user/session preference precedence, forks, and more than 64 setting changes.
- Native Claude fixtures covered partial JSON tool streams, signed thinking blocks,
  a switch to OpenAI with existing tool history, denial/acceptance of writes,
  truncated streams, and compaction before a request.
- HTTP tests verified the real PID and shared terminal state, Host/Origin rejection,
  shutdown, concurrent-operation rejection, and cancellation without advancing the
  checkpoint. Dedicated stdio emitted only JSON-RPC.
- Live Claude Haiku 4.5 read the current runbook through the read tool and reported
  port 9443. The two model requests used 2,445/2,588 input and 102/11 output tokens.
  Phoenix received all five spans, with matching names, statuses, and generations.

Local demo artifacts are under `.shift/daily-driver-demo/`: `input.txt`,
`traced-output.txt`, `verification.json`, and the `claude-traced` session. The
exporter test used `UV_CACHE_DIR=/tmp/shift-uv-cache` to accommodate this coding
session's filesystem permissions; normal runtime defaults were left alone.

The live test covers Claude standard service. OpenAI fast/effort fields and Claude
fast capability checks are fixture-tested; premium fast service was not exercised.


## Terminal interface

Launch `bin/shift-agent` from your project, or `make` in the Shift checkout (the optional
`SHIFT_ARGS` make variable forwards CLI options). It requires Python 3 with curses and
an interactive terminal. It uses the existing Guile session, tool permissions,
streaming, receipts, and cancellation; it does not start a separate agent.
There is no separate
interactive REPL mode. Redirected/scripted input, `--print`, MCP, help, and session
maintenance still use their non-screen paths. No additional model is loaded by
the frontend. For a no-model demo, run:

```sh
./bin/shift-agent --session ui-demo --set 'agent-model="demo"'
```

The host terminal controls the font. Layout is measured in cells, with Unicode
width-aware clipping and word-aware prose wrapping. Fenced/indented code and diffs
preserve whitespace; headings render bold, and inline `**bold**`, `*italic*`
(or `_italic_`) and `` `code` `` render as bold, italic and code on the panel
tint, with the markers removed, without introducing a full Markdown renderer. **Acid** uses a lowercase pixel
wordmark, a separate session/model/mode strip, and a two-thirds transcript beside
a one-third output pane. **Paddock** docks that pane on the left. **Blueprint**
keeps the transcript full width and places a three-row telemetry band above the
composer. Explicit `/place` preferences still win under any theme: left/right use
the side-pane arrangement, top/bottom the full-width transcript with a telemetry
band, and a multi-line wordmark then shares its header rows with session details.
Side panes dock from 96 columns when height permits; telemetry bands from 72.
The tab strip keeps whole labels: when Work, Diff, Session, Model, Log and the
panes do not fit, it shows the page holding the active tab and `‹ ›` arrows to
the right of the names; Tab past the last visible tab turns the page, and the
arrows are clickable.
Narrow or short views use an overlay only when explicitly opened. Auto avoids
overlays. Thin cyan separators and a restrained, unlabeled composer frame keep
navigation separate from the conversation.
**QDOS** uses a black canvas, compact clickable command menu, green contextual
help, white double rules, cyan metadata and yellow-on-red selection. Its default
left information pane fits at 80x25. It adapts the
[QDOS design language](https://github.com/thrashr888/QDOS/blob/master/spec/SPEC.md),
not DOS filesystem commands. Existing placement, identity and color overrides
still take precedence.
When the session/model strip is too narrow for both, the model name is dropped
rather than cut mid-word; the Session tab keeps the full value. Footer hints drop
their least essential items (pane paging, diff/work folds, then mode and sidebar)
before the row would overflow, so 80-column QDOS keeps `^D quit` visible.
Below 40 columns or 18 rows, a compact transcript, status and input replace the
larger frame. The prompt stays outside all overlays. The live transcript is bounded to 3,000 lines; resumed sessions show
the last 50 persisted messages, with complete history available through traces.
PageUp clamps at the oldest retained content; incoming output and resize preserve
the scroll anchor. Composer scrolling accounts for whole wide characters.
Wheel offsets clamp to the rendered viewport for every event, so reversing at
the oldest content moves immediately rather than paying off hidden overscroll.
Both SGR and legacy X10 packets are decoded, including wheel-down on older
macOS ncurses without button-five support. Word wrapping is linear in text length.
Up/Down browses the project's saved session-command history and restores the
unfinished draft and cursor when returning to the newest entry. Local presentation
commands remain in the current frontend's history; approval replies are not added.

An empty session invites a task rather than inventing activity. Ordered backend
events supply `USER` and `SHIFT` role blocks and grouped `READ`, `EDIT`, and `RUN`
work rows. Tool completion is not a fabricated test pass. Real committed ledger
diffs supply the highlighted added/removed lines and file counts; unapproved
previews never appear as committed changes. Top/bottom placements show these diffs inline.
The side pane's Work, Diff, Session, Model and Log tabs show output/files/telemetry,
the unified diff, session/receipt details, the provider's model list, and bash run
output. Tab labels drop their padding when the pane is narrow.

**Model.** Entering the tab asks the session for `/model list` once per provider:
Ollama's `/api/tags` or the provider's `/models` endpoint, a metadata request with
no inference. Rows are clickable; the current `provider/model` carries a marker and
the strip badge updates when the host confirms. `/model NAME` at the prompt
Tab-completes the listed names. Requests ride the same host route as `/mode`, so a
running turn or pending approval refuses them without consuming input, and the
agent's `ui` tool cannot use it. A failed listing stays visible with its reason
until you re-enter the tab or type `/model list`. Choosing another model of the
current provider keeps its endpoint and key source, so a local OpenAI-compatible
server stays selected; choosing another provider restores that provider's defaults.

**Terminal colors.** The `terminal_colors` preference, on by default, makes the
surrounding terminal follow the pack: default background, foreground and cursor
color via OSC 11/10/12 whenever the theme loads or changes, reset on exit.
`/terminal off` stops it for terminals you would rather keep as they are; Ghostty,
kitty and iTerm2 honor the sequences. The generated Ghostty themes remain the way
to match the full 16-color palette.

**Session.** Besides the current session, receipt, exact telemetry and source
identity, the tab lists every durable session under the state directory with a
status mark: `▶` current, `●` open in another process (its owner lock is held),
`○` idle, plus turn count and last checkpoint time. Entering the tab refreshes
the list. Clicking an idle row, or `/session NAME` (Tab-completes), switches: the
Guile owner of the current session checkpoints and exits, the same launch opens
the other session, and the curses process, preferences and identity stay put.
Busy turns, pending approvals and sessions open elsewhere refuse the switch.

**User-owned panes.** A `panes` preference adds up to four tabs of your own,
as data rather than code: each pane has a `name`, a `title`, and up to 24 rows
of `text`, a live `field` (`session.name`, `session.model`, `usage.prompt`,
`receipt.status`, `source.loaded` and the rest of the documented list), or a
`command` argv, or a `source` that borrows one of the built-in sidebar sections
(`session`, `skills`, `sessions`, `peers`, `receipt`, `telemetry`, `source`,
`jobs`, `runs`, `models`), so a project can compose its own status tab from the
same pieces the Session and Log tabs use. Clicking a command row runs that row as a background job;
`/pane run NAME` starts every command row and `/pane run NAME ROW` one of them,
through the same `run` machinery as the agent's runs, but only when the
session's run allowlist already permits it; otherwise the pane reports which
`/allow-run` prefix is missing. Output lands under the row and in the Log tab
when the job ends, bounded like other runs. Panes
never load Python, and the agent's `ui` tool can edit them only under the same
validation as colors.

A project ships its panes in `.shift/panes.scm`, a pane pack: one Scheme data
form, read like a theme pack and never evaluated, holding up to four
`(pane NAME TITLE ROW ...)` forms whose rows are `(text "...")`,
`(field session.model)` or `(command "git" "status" "--short")`. It loads
whenever Shift runs in that folder and reloads within half a second when it
changes; this repository's own file adds a SHIFT tab with checkout health,
`git status`, `git log` and `make test`. The file is committable (`.gitignore`
keeps the rest of `.shift/` private). Explicit `panes` preferences, for example
from `/ui`, take precedence over the file and carry the same panes as JSON; an
invalid file is reported and skipped. `./bin/shift-agent --check-panes [FILE]` lints
a pack the way a session loads it. The grammar and field list are published at
<https://thrashr888.github.io/shift/panes.html>.

```scheme
;; .shift/panes.scm
((pane "shift" "SHIFT"
   (text "Checkout health")
   (field source.loaded)
   (command "git" "status" "--short")
   (command "make" "test")))
```

```text
/ui {"action":"patch","patch":{"panes":[{"name":"shift","title":"SHIFT","rows":[
  {"text":"Checkout health"},{"field":"source.loaded"},
  {"command":["git","status","--short"]},{"command":["make","test"]}]}]}}
```

**Peers.** Every terminal session serves MCP for other clients at
`http://127.0.0.1:7331/mcp`, falling forward to the next free port up to 7340
when several sessions run; `--no-mcp` turns it off and `--mcp-port PORT` pins a
port, which must then be free. The Session tab's PEERS section shows the endpoint.
Each `initialize` answers with an `Mcp-Session-Id`; clients that send it back are
listed in the Session tab's PEERS section with their name, version, call count
and last tool, and every tool call they make lands in the Log tab as a `[peer]`
entry with its outcome. Peers get the same four read-mostly tools as before;
they cannot change settings or approve anything.

**Copying replies.** `/copy` puts the last reply on the clipboard, `/copy 2` the
one before, and clicking a `SHIFT` role label copies that block. The text goes
out as OSC 52, which Ghostty, kitty, iTerm2 and tmux forward to the system
clipboard even over SSH, and also through `pbcopy`, `xclip` or `wl-copy` when
one is installed. While Shift tracks the mouse for tabs, rows and the wheel,
the terminal still selects natively with its modifier held: Shift in Ghostty,
kitty, WezTerm and xterm, Option in iTerm2. `/mouse off` (the `mouse`
preference) releases tracking so plain drag-selection, right-click and the
terminal's own scrollback work as usual, and clicks inside Shift stop; `/mouse
on` takes them back. Both take effect live.

**Log.** Every `run` tool call appends its command, exit status, duration and
combined output, bounded to 300 lines or 16 KiB per run with the ledger log path
for the rest; the tab follows the newest run until you scroll. With a top or
bottom placement, or no pane, the same output appears inline under its work group
as a `RUN OUTPUT` block (first 20 lines) that Ctrl+O folds with the diffs. Ctrl+W and Ctrl+O fold work and diff
groups; the selection and fold state survive redraw and resize. PageUp/PageDown
scroll the selected Diff or Session pane; in Work they scroll the transcript.
Live diff previews are bounded to 200 lines/32 KiB; complete filenames and
diffstats remain available even when the preview is truncated.
A scrolled transcript pins the current block's role label (`USER`, `SHIFT`) on its
first row; failed tool results wrap by word under their work row with a hanging
indent.
The session's `show-work=false` setting suppresses new automatic work groups in
the transcript without discarding inspector events or receipts. `/work on`
does not reveal groups that were hidden when created; Ctrl+W folds visible groups.

Cell-height segmented context and round bars use reported usage (or explicitly
`~`-marked local estimates) and known limits, rounded to the nearest segment and clamped to the bar's
range. Compact counts such as `24k / 131k` reserve space for the bar; the Session
tab retains exact values and provenance. Startup and resume publish the effective
max-rounds setting and round `0` before any provider request; UI edits retain the
latest snapshot. Missing denominators show `?` and a `/context limit N` hint rather
than a meaningless empty usage bar. The current-turn
pane resets on the next turn without deleting earlier transcript groups.

For a local Ollama endpoint, bounded metadata-only `/api/ps` requests can supply
the loaded model's `context_length` and `size_vram`. An explicit context limit
wins; architecture maximums and downloaded weight size are never substituted.
`MODEL MEM` means the provider's **GPU/model allocation**, not host RAM or proven
physical residency. It shows GiB without an invented capacity bar; exact bytes
and the provider label appear in Session. Missing metadata shows `N/A` with a
reason (not loaded, unsupported, unavailable, or demo). Remote endpoints and demo
models are not probed. Discovery uses a one-second timeout, bounded response and
five-second cache, outside rendering; provider/model/endpoint changes invalidate
the cached identity. No inference request is made for these measurements.

| Input | Action |
| --- | --- |
| Ctrl+B | Toggle inspector without discarding the draft |
| Ctrl+P or click its hint | Open searchable command completion; Escape restores the draft |
| `/`, then type | Filter command names and supported argument choices |
| Tab / Up / Down in suggestions | Complete the selection / move selection; Enter on a selected completion deliberately submits |
| F2 or bare `/theme` | Cycle installed built-ins, then discovered custom theme packs |
| Tab outside suggestions | Select Work, Diff, Session, Model or Log in a side pane/overlay |
| Click a Model row or `/model PROVIDER/MODEL` | Switch models when idle; `/model list` refreshes the tab |
| Click an idle Session row or `/session NAME` | Switch durable sessions when idle; running sessions are marked, not switchable |
| Click a pane command or `/pane run NAME [ROW]` | Start a user-owned pane's allowlisted commands as background jobs |
| Click a Session-tab skill or `/skill NAME` | Send a skill's instructions with the next prompt; `/skills` lists them |
| `/upgrade` | Checkpoint and hand this session to the current install in place; the notice names the old and new runtime versions |
| `/jobs`, `/jobs cancel ID` | List background jobs or stop one; the Log tab shows them running |
| `/mouse off` | Release mouse tracking for the terminal's own selection (`on` takes it back) |
| Click `‹` or `›` in the tab strip | Turn the page when the tabs do not fit |
| `/copy`, `/copy N`, or click a SHIFT label | Copy the last reply, the N-th from last, or that block to the clipboard |
| `/terminal on` | Sync the terminal's default colors and cursor to the theme (`off` restores) |
| Shift+Tab or click mode badge | Cycle manual -> plan -> autopilot -> manual when idle |
| Click sidebar hint / Work, Diff, Session | Toggle inspector / select pane without submitting the draft |
| Wheel / trackpad | Scroll the pane under the pointer; navigate suggestions over a popup |
| Ctrl+W | Fold/unfold tool work groups |
| Ctrl+O | Fold/unfold committed diffs and inline run output |
| PageUp / PageDown, or Option/Ctrl + Up/Down | Scroll the transcript, or the selected side pane; Mac keyboards without page keys use the arrows |
| Ctrl+G | Jump to the latest transcript without changing the draft |
| Ctrl+C | Cancel the current turn, or clear the idle draft |
| Ctrl+D | Exit and restore the terminal |
| Escape | Dismiss an overlay/reference, or decline an approval |
| `/name thrashr888` | Set personal identity |
| `/brand replace` | Replace the wordmark with your name (`subtitle` or `none` also available) |
| `/place bottom` | Place the inspector left/right/top/bottom/modal |
| `/sidebar auto` | Select auto/on/off visibility |
| `/theme acid` | Select a built-in or user-owned theme |
| `/density compact` | Reduce transcript whitespace (`comfortable` restores it) |
| `/motion off` | Disable the working mark animation (`on` restores it) |
| `/ui get` | Inspect current configuration |
| `/ui undo` | Restore the previous working UI revision |
| `/ui reload` | Reload the selected presentation pack |
| `/ui code-reload` | Validate and reload compatible local TUI presentation code |
| `/ui save user` | Promote preferences to user scope (`project` also available) |

UI commands use a separate inherited pipe and remain responsive while the agent
runs or waits for approval, including typed `/theme`, `/name`, `/motion` and
`/ui` commands. These do not answer, approve or decline the waiting request.
Multi-line command results (such as the auto-mode explanation) collapse into one
notice line separated by `·`.
Other session commands cannot run until approval is resolved. Invalid UI commands
leave the request pending and show the error beside the input. Approval input is separate from the saved draft;
presentation overlays are hidden during approval so the tool preview stays
visible. Pending previews are separately framed and scrollable; completed approval
questions, tool JSON and the plain REPL prompt chatter are not duplicated in the transcript.
Command completion never answers an approval; Escape first dismisses completion.
The agent's `ui` tool supports get/patch/undo/reload/save. Manual mode
asks for tool approval; plan mode permits only get. Autopilot allows validated UI
changes. Mode switching is an explicit user-only `/mode` operation,
not a presentation preference or agent UI action. Busy turns and pending approvals
reject mode changes visibly without changing their decision or consuming input.
The draft and cursor survive mode clicks and Shift+Tab.
Tool results and traces record the applied UI revision/configuration.

Rules use individual wide-character cells on UTF-8 terminals, ACS on legacy
terminals with a graphics character set, and ASCII only when requested or required.
This separates connected chrome from semantic prose/diff hyphens. Terminals whose
terminfo advertises `rep` (Ghostty, kitty) expose a bug in ncurses before 6.1,
including the macOS system library Python links: repeated wide cells are sent as
their low byte plus a repeat sequence, so rules vanish and `═` shows as `P`. When
that ncurses is in use, startup compiles a private terminfo copy without `rep`
for the curses process only; TERM stays unchanged and the Session tab notes it.
Meters use
full `█`/`░` cells through the same wide-cell path; ASCII/legacy fallback uses
`#`/`.` rather than uncommon partial-block glyphs.
Terminal-cell captures do not prove native font rendering. Mouse
tracking is enabled while curses owns the terminal and restored on exit; if a
terminal reserves a modified click for text selection, its own convention wins.

#### Reloading presentation code

After one restart to install this support, `--watch` (the interactive default)
checks trusted local `scripts/tui.py` changes twice per second, with a stable-revision
debounce. `--no-watch` disables automatic code reload; `/ui code-reload` remains
explicitly available. `/ui reload` still reloads the selected Scheme theme pack.
This does not load model-provided Python or arbitrary paths.

The running host validates a separate candidate module, checks its interface and
renders against a detached state copy before swapping presentation methods on the
curses thread. The Guile process, active turn, approvals, draft/cursor/history,
retained events, scroll anchor and pane state stay in place; requests are not
replayed. Syntax/import/render validation failures keep the working UI and show
an error. A failed unchanged revision is not continually retried.

Only compatible presentation/input method and layout-helper edits reload. Imports,
host lifecycle, model/event protocol, initialization/state-schema, backend changes
and changes to the reload controller itself require restart. This is not an
in-place reload of live globals, nor a backend restart disguised as hot reload.
Older already-running TUI processes cannot acquire this bootstrap without the
initial restart.

The header shows the loaded Shift installation's short commit and `+dirty` when
its tracked or unignored source files differ. It is not the working project's SHA.
The Session pane and `/ui get` include full commit, process-start identity and the
loaded presentation-source fingerprint. Identity is sampled at startup and a
successful presentation reload, not every frame; later disk edits are not
misrepresented as already loaded. Archives or missing Git show `source unavailable`.

Preferences live in `ui.json` beside existing settings: user config, project
`.shift/`, and named session directory, in that precedence order. Patches are
saved to the current session (project for an explicitly ephemeral session). Identity
and explicit placement survive theme changes. There is a bounded, process-local
undo stack separate from agent generations; it resets on restart.

Presentation packs are one Scheme association list under `themes/NAME.scm` in
the installation, user config, or project `.shift/` (project wins). `ui get`
reports the active path. Copy a bundled pack under a new name to make it yours.
Valid saved changes activate within the next half-second without restarting the
agent. `scripts/ghostty_themes.py` turns each bundled pack into a Ghostty theme
under `site/ghostty/` so the surrounding terminal can match; regenerate after
editing a bundled pack. Packs are data, not executable Scheme, and are bounded at 32 KiB. Packs, `ui.json`
and the frontend pipes are read and written as UTF-8 regardless of the process
locale, so a `C`/POSIX locale neither rejects the block-glyph wordmarks nor
miscounts their width. The
renderer supports colors (ANSI 0–255 or `"#RRGGBB"`), three-line cell wordmarks, borders,
density, placement, and inspector section order (`session`, `context`, `files`,
`checks`). Theme defaults yield to explicit preferences. For example:

```text
/ui {"action":"patch","patch":{"accent":154,"ascii":true,"sections":["files","checks"]}}
```

Acid uses a deep purple `#170626` canvas, lime, cyan and
lavender hierarchy. Paddock keeps paper colors and compact spacing; Blueprint
keeps its spaced wordmark, double composer border and bottom strip. Explicit
user color overrides are never replaced by theme defaults.

RGB themes use direct RGB when curses reports direct-color support. A
programmable 256-color terminal instead receives dedicated palette entries,
without repurposing any explicitly selected ANSI indices; their original values
are restored on theme change and exit. This is palette programming, not a claim
of direct-color support. A fixed 256-color terminal gets nearest indexed colors;
eight-color dark backgrounds fall back to black, not harsh magenta. Monochrome
uses no color-pair attributes, and `ascii` supplies text-only marks and bars.
The frontend does not force a different `TERM`. Terminal capabilities and fonts
still control the final appearance; curses cannot reproduce the mocks' font
rasterization, antialiasing or gradients.

The `///` mark cycles one accent, bold slash against two muted slashes at four
steps per second only while the session is `WORKING`; on the same clock a lit
pair sweeps across the header checkerboard, and the transcript's next line
shows a ticking `...` where the reply will land. A trailing mark beside a
multi-line wordmark uses cell-based strokes at the wordmark's height; custom
single-line identities and ASCII keep literal `///`. Animation never changes the
mark's footprint, and timer updates repaint just those cells without moving the composer
cursor. Startup, idle, approval waiting, and cancellation are static; completion
or errors return to the ready view. Hidden/clipped marks and custom art without
`///` are not animated. ASCII and monochrome use the same bold/dim cells.
`/motion off` persists with other presentation preferences and leaves the
`WORKING` text visible; it is also available as the boolean `"motion": false` in
UI patches and theme packs. There is no automatic OS reduced-motion detection in
curses. No other UI animation is enabled.

Validation includes geometry across 450 size/placement/visibility combinations,
Unicode clipping and composer cursor positions, overscroll bounds, real PTY
input/resize/exit and default-launch tests, live theme saves and rejected reloads,
preference persistence, agent-driven UI patches, frontend keyboard routing while
an approval waits, and busy/motion-off/completion/error/cancellation behavior.
A browser mock remains a design reference, not rendering proof.
Arbitrary executable component renderers and custom widgets remain future work;
this implementation hot-swaps validated presentation data through a fixed cell
renderer. It renders the existing transcript, rather than a new rich diff editor.

## TUI design direction (September 10, 2026)

Original design direction; the implemented subset and remaining limits are
described above. Apex and Afterhours packs were added from later mocks and
removed on September 11, 2026 because they only rearranged Acid's panes, which
`/place` already does; QDOS was added as a fourth, structurally distinct pack. The interactive study is
`output/design/shift-tui/live-prototype.html`. It uses a simulated session and a
small demonstration phrase parser; it does not call a provider or mutate Shift.

The conversation and composer are the primary surface. Tool activity folds into
one work section, with inline diffs available even when the inspector is hidden.
The inspector adds session identity, context usage, changed files, connections,
and the latest test result. Avoid repeating the full transcript in that panel.

Inspector preference is `auto`, `on`, or `off`. Start Auto at 120 terminal columns,
with a minimum readable conversation width and a bounded inspector width; tune
this breakpoint in the real terminal. Narrow Auto hides the inspector. Explicit
On docks it when it fits and uses an opaque dismissible drawer otherwise. Off
remains hidden across resize. Ctrl+B toggles; the command menu restores Auto.
Resize, theme changes, and toggles preserve draft, cursor, focus, scroll anchor,
and expanded work sections. A drawer must leave the composer accessible.

Ship three distinct presentation packs, rather than three palette swaps:

- **Acid Garage (default):** purple, acid lime, cyan, a pixel wordmark and racing
  stripes; airy transcript with a right inspector.
- **Paddock:** warm paper, racing red and dark green; compact timing tables,
  heavier rules, italic branding, and a left inspector.
- **Blueprint:** cobalt and white with yellow highlights; technical annotation
  columns, dashed rules, restrained branding, and sparse framing.

All three render the same semantic session data. User packs can replace layout,
component renderers, spacing, borders, glyphs, role styles, grouping, inspector
contents, and status placement, as well as colors. Character-cell dimensions,
terminal-selected font, Unicode width, and reduced-color/ASCII fallbacks remain
real terminal constraints. The browser study approximates these, not pixel parity.

### Making it mine

Identity belongs to the user, independently of the theme. `thrashr888` can appear
beside the wordmark or replace `shift` entirely. Theme names belong in the picker,
not in the user's session header. Preserve exact casing; allow custom wordmarks,
role labels, and optional branding. Custom names are display text, not executable
markup or terminal escape sequences. Clip or wrap them by display-cell width.

Panel placement is independent of visibility and theme: left, right, top, bottom,
or a dismissible overlay. Theme defaults are suggestions; explicit user placement
wins when themes change. Model layouts as bounded horizontal/vertical splits,
stacks, and overlays with minimum sizes and overflow rules. This permits further
user-defined arrangements without promising arbitrary pixels in a terminal.

Character-cell feasibility is exercised by
`output/design/shift-tui/terminal-layout.py --check`: 300 combinations of terminal
size, placement, and visibility. It can print actual ASCII layouts, including
80×24, without a browser. This proves geometry only, not a production renderer.
Docked panels must not overlap the session, and overlays must not cover the
composer. Short terminals need height fallbacks as well as width breakpoints.
Below the supported minimum, retain a compact transcript and prompt.

The actual renderer must use terminal rows/columns, display-width-aware clipping,
and capability-aware color and glyph output. Large wordmarks require multi-cell
ASCII/block art; proportional font sizing, pixel padding, shadows, and arbitrary
font families in the browser mock are not terminal features. Verify resize,
wrapping, focus, overlays, Unicode, and color fallbacks in a PTY before adopting a
layout as implemented. Keep an ASCII mode and do not depend on italic support.

### A live, user-owned presentation

Use the existing permanent-runtime / user-owned-image split. Keep terminal I/O,
input dispatch, authoritative session events, approval decisions, and recovery in
the host; make presentation composition a reloadable Scheme extension. Render
functions consume a read-only view of session data and return a bounded cell tree.
Changing how an approval is drawn must not change what is being approved.

Data preferences follow the existing user → project → session precedence. Add
UI preferences for theme, inspector policy, density, section order, glyph style,
and status fields. Session edits apply immediately; explicitly saving to project
or user scope makes them defaults there. Presentation code loads through a
validated generation boundary; ordinary appearance preferences should not consume
the agent code-patch budget. Track a separate UI revision and retain the previous
working presentation. A render error keeps the last good UI and exposes recovery
through a host-owned command path.

Give Shift tools to inspect the current UI configuration and capabilities, apply
a validated preference patch, and undo its last UI change. Requests such as
“hide telemetry,” “put files on the left,” or “make this more compact” should use
those tools and redraw immediately, without restarting or losing a running turn.
Structural requests can edit the user-owned presentation extension and activate
it atomically after validation. Record the changed keys or source, scope, and UI
revision in the receipt. A UI revision may change during streaming while the
provider turn stays pinned to its original agent generation.

Implement in this order: semantic session view and terminal adapter; responsive
conversation/composer/inspector; the three interchangeable presentation packs;
validated UI preference tools and persistence; hot-swappable render extensions.
Validation must cover live resize during streaming, draft/focus retention,
invalid preference patches, renderer failures and recovery, theme switching,
scope precedence, narrow layouts, and non-color-only status indicators.
