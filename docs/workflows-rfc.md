# Workflows RFC: durable procedures that Shift runs, measures and improves itself

Status: RFC. Nothing here is implemented; decisions are proposed, the open
questions change the work.

## Why

Shift can already change itself: live patches become generations, named
extensions persist them, `/learn` turns a conversation into a skill, notes
survive a context reset, and subagents run pinned to a generation. What it
cannot do is *decide* to improve itself, or run a multi-step procedure the same
way twice and know whether the second run went better. Every improvement so
far came from a person reading traces. The evals of the last week showed
where that leaves a local model: the same argument mistakes in every session,
rounds spent rediscovering a tool's quirks, a fix found in one turn and
forgotten by the next.

Hermes writes skills from its own chat history. Shift has a stronger lever:
its behavior is a live image with a validated, attributable, reversible
generation model, plus receipts and traces that say whether a change helped.
The missing piece is a unit of work that carries its own checks.

## The workflow

A workflow is a named, durable procedure: an ordered list of steps, each a
prompt for one turn (optionally handed to a subagent), with checks that decide
whether the run succeeded, a round budget, and the skills and extensions it
relies on. It lives as data under `.shift/workflows/NAME/`:

```text
.shift/workflows/release-check/
  workflow.scm       steps, checks, budget, requires
  README.md          what it is for, written for people
  runs/              one receipt per run, plus the notes each run kept
  versions/          earlier workflow.scm files, by number
```

```scheme
((workflow "release-check" 3)
 (description "Verify a checkout before tagging a release")
 (requires (skill "checkout-health") (extension "verified-selector"))
 (budget (rounds 20))
 (step "status" "Run git status --short and git log --oneline -3; report whether the tree is clean.")
 (step "tests" "Run make test as a background job and report the outcome with the failing files if any." (check (run "make" "test")))
 (step "summary" "Write the release notes for the last five commits to notes/release.md." (check (notes "release.md"))))
```

Checks are the ones the evals already use: a command that must exit 0, an
answer that must contain given text, a note or file that must exist, a receipt
field (`changed`, `runs`, `blocked`) with a bound. A run is resolved when every
check passes within the budget.

`/workflow run NAME` executes the steps as ordinary turns of the session, so
approvals, the judge, the receipt and the trace all apply; the run's receipts
land under `runs/`. `/workflow list`, `/workflow show NAME` and a `workflow`
tool with the same actions let the model start one.

## Self-improvement

The loop has three sources of candidates and one gate.

1. **Reflection after a hard turn.** When a turn ends at a limit, repeats a
   tool call, or takes three or more tool rejections of the same kind, the
   session review's facts for that turn are handed to the model as one
   ephemeral note with a request: propose a durable fix as a skill note, a
   workflow edit, or an extension, or say none. Proposals are written as
   *disabled* artifacts (an extension via the `extension` tool, a skill under
   `.shift/skills`, a new workflow version), never activated.
2. **Distillation after a good run.** A resolved workflow run, or a turn with
   many tool calls that ended cleanly, is offered to `/learn`-style
   distillation: the procedure that worked becomes a skill or a new step. This
   is Hermes's move, with the receipt as the evidence that it worked.
3. **Field notes.** Tool quirks the model hits and works around (argument
   shapes, a repo's test command, a flaky suite) are appended to a per-project
   skill, `.shift/skills/field-notes`, loaded into every turn. This is the
   cheapest and, from the evals, the most valuable: most wasted rounds were
   the same mistake in a new session.

The gate is measurement, not judgment. A candidate is promoted only when it
beats the baseline on the workflow's own checks: the workflow runs twice in
subagents pinned to two generations, baseline and candidate, on the same
task, and the candidate must resolve at least as often in no more rounds. The
live-repair harness already does exactly this comparison for extensions; the
workflow just gives it a task to run. Two runs are enough to reject a
regression and not enough to prove much else, which is the honest bar for a
single user's machine.

`/workflow improve NAME` runs the loop on demand: read the last runs'
receipts and notes, propose one change, compare, keep or discard, record why
in `versions/`. Nothing promotes without a comparison; nothing is deleted.

## Techniques worth building into the loop

- **Error-driven notes** (source 3) before anything model-generated: the
  harness already knows when a tool rejected an argument shape. Recording the
  corrected shape in field notes costs nothing and removes whole classes of
  waste.
- **Exemplar reuse**: before writing a new function, a workflow step can ask
  ripwire (or `rg`) for the repo's best instance to imitate. Cheap, and the
  evals show models copy well and invent badly.
- **Test gates as steps**: diagnostics already name the failing file and line;
  a workflow step that runs the narrowest relevant test after each edit turns
  that into a loop instead of a final surprise.
- **Generation-pinned A/B** as the only promotion path, above.
- **Budgets per step**, not per turn, so a runaway exploration step cannot
  starve the verification step.

## Decisions

1. Workflows are data files in `.shift/workflows`, committable like panes and
   settings; steps are prose prompts, not code.
2. Proposals are always disabled artifacts; only a measured comparison
   promotes them, and promotion is per project.
3. Field notes are a plain skill the loop appends to, so a person can edit or
   delete lines; nothing else writes to skills automatically.
4. Reflection runs at most once per turn and only after a hard turn, as one
   ephemeral note, so an easy session sees none of it.

## Open questions

1. Should reflection proposals be created automatically as disabled artifacts,
   or only offered in the transcript for the user to accept? The draft says
   created, since they are disabled and listed by `/extensions` and
   `/skills`; a user who dislikes clutter turns reflection off.
2. Which comparison counts for a skill or field note, which are not
   generations? The draft says a workflow run with and without the skill
   loaded, same mechanism as extensions, using `skill-dirs` per child.
3. Is `/workflow run` a sequence of turns in the current session, or always
   a subagent so a long workflow does not fill the parent's window? The draft
   says the current session by default and `--spawn` for the child form.
