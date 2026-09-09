# Daily-driver foundation

This is the first implementation slice of [the agreed plan](daily-driver-plan.md).
The REPL remains; TUI, dynamic skills, cross-session trace recall, extension packs,
and model-tested automatic approval are later work.

## Projects and settings

Run `bin/shift` from the project you want to work on. Code loads from the Shift
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
and a copyable `./bin/shift --resume NAME` command.

`.env` is read as data without shell evaluation. Existing process environment
variables take precedence. Claude uses `CLAUDE_API_KEY`; OpenAI uses
`OPENAI_API_KEY`. Settings and checkpoints store only credential variable names.

## Providers and context

Claude is a built-in native Messages adapter, including streaming text, thinking,
signed thinking blocks, tool calls/results, and usage. Conversations normalize
legacy Ollama/OpenAI tool messages so provider switching keeps call IDs intact.
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
they are not tokenizer counts. Claude's context window is discovered from the
account's model metadata. If a provider does not report its effective window,
the limit stays unknown; set `/context limit TOKENS` explicitly. Switching models
clears that explicit override. The JSON `output-reserve` setting defaults to 8192.

Before each tool-loop request, the runtime checks an 80% input-plus-output budget.
It summarizes earlier complete turns, retaining the current turn and tool chain.
If the retained turn or summarization request cannot fit, it pauses with a useful
error and preserves the original checkpoint. Message-count compaction remains a
fallback. `/compact` also works explicitly. Raw usage and tool outcomes remain in
local traces, with Claude token counts exported to Phoenix.

## Tool policy

| Mode | Tool behavior |
| --- | --- |
| `/mode manual` (default) | Ask before each model tool execution. |
| `/mode plan` | Allow reads/search/traces, `status`, `diff`, and extension listing; deny mutations. |
| `/mode accept` | Also allow constrained project writes/edits/patches; ask for shell, `run`, and live changes. |
| `/mode auto` | Conservative prototype: allow reads, ask for everything else. |

The same policy gates model tools, selected context reads, and recovery retries.
Shell `deny` and process tool ceilings still apply. Mode is process-owned data;
`live_eval` cannot change it. Explicit terminal slash commands are user operations.
Auto does not run a model classifier or silently infer approval from prompt words.

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
trace    3f9a1b2c… span 8c21aa00…   resume ./bin/shift --resume dogfood
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

Every mode except plan asks before a run. The answer `a` approves it and adds the
exact argv to this session's allowlist; `/run allow cargo test` adds a prefix,
`/run deny cargo test` removes it, and `/run list` shows them. Allowlisted prefixes
run without asking in accept and auto, never in manual, and match exact leading
elements only. `/settings save` promotes the list like any other preference. MCP
callers cannot approve or extend it.

The `coding` built-in provides `status`, `diff`, `apply_patch`, and `run`. `apply_patch`
takes one unified diff in the exact `--- a/PATH`, `+++ b/PATH`, `@@` form that
`git diff` and `diff -u` emit, with `/dev/null` for creates and deletes. Hunks must
match their context exactly, with no fuzz; a rename is applied as a delete plus a
create; and the whole patch is prepared in memory, previewed, and committed as one
unit, so a failure in any file leaves every file untouched. `status` reports the git branch
and dirty count, files shift changed this turn and this session with diffstats, and
dirty files shift did not touch. `diff` takes `scope` `turn` (default), `session`, or
`git` (working tree against HEAD) and optional `paths`. Both are read-only, work
without git, spawn `git` and `diff` without a shell, and are bounded at 64 KiB.
Omit `coding` from `SHIFT_BUILTINS` to remove the tools.

`make build` compiles the runtime into `build/`; `bin/shift` and `make test` load
those modules and fall back to source, with a note, when a file is newer than its
compiled form. `bin/shift` runs `make build` itself before launching, so the cache
is refreshed after a pull without any notes about stale modules.

## Print mode and unattended runs

```
./bin/shift --print "Add a test for the parser" --mode accept --allow-run "pytest" \
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
answered, so anything that would ask is denied; use `--mode accept` for edits and
`--allow-run "ARGV PREFIX"` (repeatable) for the commands the task may run. These
flags seed the session's settings exactly as `/mode`, `/run allow`, `/model`, and
`/settings` would, and `--set KEY=JSON` accepts any settings key.

Every tool call is echoed as `tool> NAME SUMMARY` followed by a `✓` or `✗` line
with the first line of its result, so a session shows what the model did even
when nothing needed approval. In print mode the echo goes to stderr. `/tools`
shows the enabled tools and the echo state, `/tools off` and `/tools on` toggle
it, and `--set show-tools=false` does the same for an unattended run.

Two turn limits exist. `agent-max-tool-rounds` now goes up to 64 and can be set
per session. `turn-token-budget` caps the uncached prompt tokens plus completion tokens one
turn may spend across its tool rounds, so cache reads do not count; either limit ends the turn as a failure, keeps
the conversation unchanged, and journals a `turn-limit` event with the reason.
Files the turn already changed stay changed and remain undoable.

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

For clients that launch their own dedicated process:

```
./bin/shift --mcp --session client
```

This serves the same tools over stdio, reserving stdout for JSON-RPC. `bin/shift-mcp`
is a compatibility launcher for that command. Configure an HTTP-capable client
with the URL above to attach to an existing terminal session instead.

The older Python supervisor remains at `extensions/shift/shift_mcp.py` for existing
multi-process fork experiments and their regression tests. Its `live_session_*`
tools are a different, legacy interface; they are not the new live endpoint.

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
