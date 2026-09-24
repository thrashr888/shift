# RFC: declared tools and pane actions

Status: implemented. Declared tools, the residency cap, pane `action` rows
bound to a run, a declared tool or a workflow, and the allbeads conversion all
ship. "What changed in the building" at the end records where the draft was
wrong.

This RFC covers two gaps and deliberately re-specifies nothing else. Plugins
already contribute MCP servers, skills, workflows, panes, themes, live-image
artifacts, run and MCP allowlist proposals, env needs and secrets — nine
sections, parsed in `(live-agent plugins)` and applied in `apply-plugins!`.
What a plugin cannot do is add a tool, or put anything in the interface that a
person can act on.

## Why

A plugin has exactly two ways to give the model a new verb today, and both are
wrong for small things.

The first is an MCP server: a separate process, a JSON-RPC protocol, a
lifecycle, schemas. That is the right weight for Alchemy or cortex, which are
real programs. It is absurd for three verbs over a JSON file.

The second is `allow-run` plus a skill that teaches the CLI. This works, and
seven of the eight bundled plugins do it. But the model gets no schema. It
guesses argv from prose, and the only thing standing between a guess and a
mistake is the allowlist prefix. The skill is charged on load; the argv
knowledge is charged again in every reasoning trace that reconstructs it.

The second gap is that panes are inert. A pane row is static text, a session
field, a built-in source, or an allowlisted command whose output is rendered.
Nothing a person sees in the interface can be acted on. A board that lists
work cannot move a card; a pane that shows a failing suite cannot rerun it.

### What the neighbours do

Three models are worth naming, because the choice between them is the whole
design.

**QDOS** compiles plugins in. Fifty-nine Rust crates implement a `Plugin`
trait with `capabilities`, `menu_item`, `status_info`, key and mouse handlers,
`draw_modal` and `tick`. Plugins own their rendering and their input, and the
ceiling is high — but adding one means editing and rebuilding QDOS, so only
its author ever adds one.

**oh-my-pi** makes an extension a TypeScript module against the same tool API,
slash-command registry and hotkey table the built-ins use, reloadable with
`/reload-plugins` and publishable to npm. Anyone can add one. The cost is that
an extension is now arbitrary code in the host language, with the host's
authority.

**Shift** makes a plugin data: a manifest read like a pane pack and never
evaluated, pointing at more data. Anyone can add one, nothing executes, and
`--check-plugin` can tell you it is well-formed before you enable it.

That third property is the one to protect. Shift's distinguishing claim is not
that it has plugins; it is that the agent can write and revise its own
behavior, transactionally, with a generation to roll back to. That only holds
while behavior is data the runtime validates. An escape hatch to host-language
code would buy tools and lose the thing that makes the harness interesting.

**So the surface grows by adding declarative sections the agent itself can
author, never by adding a way to run plugin-supplied code.** Both features
below are built to that rule.

## 1. Declared tools

A `tool` section names a tool, gives it a JSON Schema, and binds it to an argv
template. The runtime renders the template and executes it through the same
path as `run`, under the same allowlist and the same judge.

```scheme
(tool "kanban_move"
  (description "Move one card to another column of this project's board.")
  (parameter "card" string "Card id as the board lists it")
  (parameter "column" string "Target column: todo, doing or done")
  (run "kanban" "move" "{card}" "{column}"))
```

- **The plugin supplies no code.** It supplies a schema and an argv shape.
- **The allowlist is still the boundary.** `("kanban" "move")` has to be in
  `allow-run` for the call to skip approval, exactly as if the model had
  called `run` itself. A declared tool that is not allowlisted asks, and in
  plan mode it is denied. A plugin cannot widen its own authority by wrapping
  a command in a tool.
- **Substitution is argv-positional, never a shell.** `{card}` replaces one
  whole argv element. A value containing spaces, quotes, `;` or `|` stays one
  element and cannot become a second command. This is the property `shell`
  gives up and `run` keeps, and a declared tool must keep it too.
- **The template's fixed prefix must satisfy the declared parameters.** A
  template whose first element is a substitution (`(run "{cmd}" ...)`) is
  rejected at lint: the allowlist matches leading elements, so a substituted
  head would make the prefix unknowable and every allow meaningless.

### Cost, which is the reason to bound this

A tool schema rides in every request for as long as it is in static context.
Cursor found that moving low-frequency tools out of static context cut
tool-description tokens by 60%, and that doing the same for integration tools
cut total tokens 46.9% in sessions that used them. Shift already acts on this:
MCP tools are discoverable through `tool_search` and never sit in the prompt.

Declared tools must not quietly undo that. Therefore:

- A plugin's declared tools are **discoverable, not resident**. They are
  listed by name and one line in the same place MCP tools are, and
  `tool_search` loads their schemas for the turn that needs them.
- A plugin may mark at most **two** tools `(resident)`, for verbs a session
  reaches for on the first turn. The lint counts them; the `/plugins` listing
  prints them, so the cost is visible at enable time.

### What it replaces

`allow-run` and a skill stay the right answer for a CLI with many verbs — the
skill teaches the tool, and the model composes. Declared tools are for the
handful of verbs a plugin wants the model to reach for reliably and by name.
The two coexist; cider would keep its skill, kanban would declare three tools.

## 2. Pane actions

A pane row gains an `action` form: something a person can select and run.

```scheme
((pane "board" "BOARD"
   (text "Doing")
   (command "kanban" "list" "doing")
   (action "Move to done" (workflow "card-done"))
   (action "Rerun tests" (tool "run" (argv "make" "test")))))
```

An action binds to one of three things, in increasing order of what it leaves
behind:

| Binds to | Runs as | Leaves |
| --- | --- | --- |
| `(run ...)` | one allowlisted command | a run record in the ledger |
| `(tool NAME ...)` | one tool call in the current session | a tool span, a receipt line |
| `(workflow NAME)` | a workflow run | a run under `runs/`, with checks |

Three rules, all of them the same rule:

1. **An action is a turn, not a side door.** It goes through `tool-decision`
   with the session's mode and allowlists. Plan mode denies the ones that
   mutate. Autopilot judges them. A keystroke cannot do what the model could
   not have done at that moment.
2. **An action is recorded.** It appears in the transcript as the tool call it
   is, lands in the receipt, and leaves a span. A board whose cards move
   without the trace knowing is a board that lies to the next session.
3. **Actions are never implicit.** A pane cannot run one on load, on tick, or
   on a timer. A person selects it.

### Why a pane row should be able to invoke a workflow

This is the form worth having, and it is the reason to build actions at all.

A workflow is the only unit in Shift that carries its own checks and leaves a
run record. Binding a pane action to `(run ...)` gives you a button. Binding
it to `(workflow NAME)` gives you a procedure whose success is *decided* and
*recorded* — so "move this card to done" can mean "run the tests, confirm the
tree is clean, write the note, and only then move it," and the board shows the
outcome because the run says so rather than because someone clicked.

It also closes the loop the workflows RFC opened. `/workflow improve` compares
a baseline and a candidate over runs. Runs happen when someone remembers to
start one. A board that starts workflows in the course of ordinary work
produces the run history that self-improvement measures, without anyone
setting out to produce it.

## 3. What we are not doing: an escape hatch

For the record, since it will keep coming up.

A `(tool ... (scheme "handler.scm"))` form — plugin-supplied code the runtime
calls — is out. The `agent` section already lets a plugin patch the live image
under the restricted contract, and the plugins RFC's first open question is
whether even that is too much for third-party text. A handler would be
strictly more: arbitrary evaluation at tool-call time, with the runtime's
authority, from a folder someone installed with `plugin add`.

If a plugin needs real code, it ships an MCP server. That boundary already
exists, is already a separate process, and already has `allow-mcp`.

## 4. Language servers

Raised alongside this; the answer belongs here because it is the same question
about where capability lives.

Not in the runtime. An LSP client is a stateful protocol — server lifecycle
per language, `initialize`, document synchronisation, position-based
requests — and `mcp-client.scm` is already thirty kilobytes of the comparable
job. A second protocol of that size in a harness whose premise is that it is
small would be the wrong trade.

As a plugin, yes, and mostly it already is. `ripwire` supplies call-graph
context over MCP today. An LSP bridge is an MCP server like any other, and it
lands on `tool_search`, `allow-mcp` and the judge with no new runtime concepts.
The parts worth having — go-to-definition, find-references, rename — are exactly
the parts that save exploration turns, and Cursor measured semantic search
alongside grep raising codebase question-answering accuracy 12.5% on average.

One piece to leave alone: diagnostics injected after every edit. Cursor
dropped that as models improved, along with directory trees and pre-retrieved
snippets. It is a per-edit tax on every later request, and the model asks for
a build when it wants one. If diagnostics arrive, they arrive because a tool
was called or a check ran.

## Decisions

1. Plugins never supply code. Declared tools are a schema plus an argv
   template; anything needing real code is an MCP server.
2. Substitution is argv-positional. A parameter fills exactly one element and
   can never introduce a second command.
3. A declared tool has no authority of its own. It is subject to `allow-run`,
   the mode and the judge exactly as the equivalent `run` call.
4. Declared tools are discoverable through `tool_search` by default; at most
   two per plugin may be resident, and the count is printed at enable time.
5. Pane actions are turns: subject to the mode and the allowlist, recorded,
   never implicit, never on a timer. They read the decision rather than
   asking for one — see "What changed in the building".
6. A pane action may invoke a workflow, which is the form that makes the
   interface produce checked, recorded runs.
7. Language servers are a plugin concern, over MCP. No LSP client in the
   runtime, and no diagnostics injected after edits.

## Open questions

1. Does a declared tool's argv template get to reference session state — the
   project root, the current session name — or only its own parameters? The
   draft says parameters only, because anything else is a substitution the
   lint cannot check against the allowlist prefix.
2. Should a declared tool be able to bind to an MCP tool rather than an argv,
   as a renaming and narrowing layer over a verbose server? It would help the
   integration case, but it puts a second name on one tool and the receipt has
   to say which was called.
3. Is `(resident)` capped at two, or is the cap a setting? A cap that a plugin
   can raise is not a cap; a cap the user raises per project might be right.
4. oh-my-pi resolves sixteen internal URL schemes (`pr://`, `issue://`,
   `skill://`) inside its ordinary filesystem tools, so `grep` walks a diff
   like a directory. For read-only surfaces this is strictly better than a
   tool: no schema, no static-context cost, and `read` and `rg` already know
   how to use it. Should a plugin be able to register a scheme — `kanban://`
   resolving through `read` — instead of declaring read tools at all? This may
   be a better answer to half of section 1 and deserves its own draft.
5. Can an action appear on a row the plugin did not declare — a built-in
   `(source jobs)` row gaining "cancel"? The draft says no; built-in sources
   stay read-only until there is a reason.

## Implementation order

1. `tool` section: manifest parsing, lint (`--check-plugin` reports the
   template prefix and whether `allow-run` covers it), and the schema showing
   up in `tool_search`.
2. Execution: render template, dispatch through the existing `run` path,
   confirm the receipt and trace are indistinguishable from the equivalent
   `run` call.
3. `(resident)` and the `/plugins` cost line.
4. Pane `action` rows, bound to `(run ...)` and `(tool ...)` first, with
   `--check-panes` enforcing that an action names something that exists.
5. `(workflow NAME)` actions, once 4 is real, so the run plumbing is written
   once.
6. Convert one bundled plugin as the proof: allbeads declares
   `beads_ready` and `beads_show`, keeps its skill, and its pane gains an
   action that runs a workflow. If that does not read better than the skill
   alone, this RFC is wrong and should be dropped rather than extended.

## What changed in the building

**An action reads the policy; it cannot ask.** The draft said an action goes
through `tool-decision` and that a run nobody allowed asks, the way the model's
call would. Building it showed why that cannot be: the host handler runs on the
interface's thread and holds the session lock, so prompting from there blocks
the turn the approval belongs to. The first version deadlocked a test.

So an action reads the decision and refuses anything that is not already
`allow`, naming the `/allow-run` entry that would permit it. Plan mode still
denies what it denies and an unallowlisted run is still refused; the interface
simply cannot talk you past either. This is narrower than the draft and better:
an interface that can raise its own authority by asking a leading question is
the thing the design was avoiding.

**A pane action binds to run, a declared tool, or a workflow — not any tool.**
An arbitrary tool call needs the turn loop around it for its span, ledger entry
and receipt line. `run` and `workflow` already have non-blocking paths, and a
declared tool is a `run`, so those three work from outside a turn and nothing
else does.

**The lint checks shape, not existence.** `--check-panes` confirms an action
names a tool and carries arguments; it cannot confirm the tool or workflow
exists, because the pack is linted without a session and the registries live in
one. An action naming something absent fails when it is selected, which is late
but honest. A `--check-plugin` that resolved a plugin's own actions against its
own tools and workflows would close most of this and is worth doing.

**Residency is enforced at parse, not at enable.** The draft said the count is
printed at enable time, which it is. It is also refused at parse time, so a
plugin with three resident tools fails its lint rather than loading and costing
what it costs.

## What the allbeads proof showed

allbeads now declares `beads_ready` (resident) and `beads_show`, keeps its
skill, and its pane's "Pick up next" action runs the `bead-pickup` workflow.

The declared tools earn their place, narrowly. `bd` has far more verbs than are
worth declaring and the skill still teaches them; what changed is that the two
a session reaches for by name now arrive with a schema instead of prose the
model re-derives whenever it wants an issue id. That is the test the RFC set,
and it passes for exactly the tools it was scoped to.

The pane action is the part that reads better than the skill could. "Pick up
next" was previously three commands and a judgement call, repeated differently
every time. As a workflow it is a procedure with checks whose runs land under
`runs/`, so a session that picked badly is visible afterwards rather than
forgotten. That is the argument for actions, and it is not an argument any
amount of skill text could make.
