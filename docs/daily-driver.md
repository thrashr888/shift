# Daily-driver foundation

This is the first implementation slice of [the agreed plan](daily-driver-plan.md).
The terminal UI is the interactive default and shares the scripted session loop. Dynamic skills,
cross-session trace recall, extension packs, and model-tested automatic approval
remain later work.

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
`/run deny cargo test` removes it, and `/run list` shows them with their settings
source (`user`, `project`, `session`, or `default`). Terminal changes are session
preferences; lists replace lower-priority lists rather than merging them. Allowlisted prefixes
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
dirty files shift did not touch. It also reports `last undo: none` or the most
recently undone turn, including after reopening the session. Failed undo attempts
and later edits leave that value unchanged. `diff` takes `scope` `turn` (default), `session`, or
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


## Terminal interface

Launch `bin/shift` from your project, or `make` in the Shift checkout (the optional
`SHIFT_ARGS` make variable forwards CLI options). It requires Python 3 with curses and
an interactive terminal. It uses the existing Guile session, tool permissions,
streaming, receipts, and cancellation; it does not start a separate agent.
`--tui` remains a compatibility alias, not a required flag. There is no separate
interactive REPL mode. Redirected/scripted input, `--print`, MCP, help, and session
maintenance still use their non-screen paths. No additional model is loaded by
the frontend. For a no-model demo, run:

```sh
./bin/shift --session ui-demo --set 'agent-model="demo"'
```

The host terminal controls the font. Layout is measured in cells, with Unicode
width-aware clipping and word-aware prose wrapping. Fenced/indented code and diffs
preserve whitespace; basic headings, bold and inline-code markers are simplified
without introducing a full Markdown renderer. **Acid** uses a lowercase pixel
wordmark, a separate session/model/mode strip, and a two-thirds transcript beside
a one-third output pane. **Paddock** docks that pane on the left. **Blueprint**
keeps the transcript full width and places a three-row telemetry band above the
composer. Explicit `/place` preferences still win under any theme: left/right use
the side-pane arrangement, top/bottom the full-width transcript with a telemetry
band, and a multi-line wordmark then shares its header rows with session details.
Side panes dock from 96 columns when height permits; telemetry bands from 72.
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
The side pane's Work, Diff and Session tabs show output/files/telemetry, the
unified diff, or session/receipt details. Ctrl+W and Ctrl+O fold work and diff
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
| Tab outside suggestions | Select Work, Diff or Session in a side pane/overlay |
| Shift+Tab or click mode badge | Cycle manual -> plan -> accept -> auto -> manual when idle |
| Click sidebar hint / Work, Diff, Session | Toggle inspector / select pane without submitting the draft |
| Wheel / trackpad | Scroll the pane under the pointer; navigate suggestions over a popup |
| Ctrl+W | Fold/unfold tool work groups |
| Ctrl+O | Fold/unfold committed diffs |
| PageUp / PageDown | Scroll the transcript |
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
questions, tool JSON and legacy prompt chatter are not duplicated in the transcript.
Command completion never answers an approval; Escape first dismisses completion.
The agent's `ui` tool supports get/patch/undo/reload/save. Manual mode
asks for tool approval; plan mode permits only get. Accept and auto modes allow
validated UI changes. Mode switching is an explicit user-only `/mode` operation,
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

The `///` mark cycles one bold slash against two dim slashes at four
steps per second only while the session is `WORKING`. A trailing mark beside a
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
