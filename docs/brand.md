# Shift: the brand

Status: proposal, September 22, 2026. This defines what Shift claims to be
before the website is rebuilt around it. The site today leads with
"an agent, made yours" and hedges every section with "spike", "experiment"
and "not a production coding agent yet". That was true in August. It is not
what the repository holds now, and it undersells the one thing no other agent
offers.

## What Shift is, in one sentence

Shift is a coding agent whose behavior is your own live program: you change
it while it runs, every turn leaves a receipt, and it improves itself under
measurement.

Everything below serves that sentence. If a page, a paragraph or a feature
does not make one of its three clauses more believable, it does not belong on
the site.

## Positioning

Every other coding agent is a product whose behavior belongs to its vendor.
You configure it; you do not own it. Shift inverts that: the permanent
runtime owns authority, transport, tools and the switch between generations,
and the user-owned Scheme image owns the agent. The difference is not a
setting. It is who the agent belongs to.

That claim is what to lead with, and it is defensible because the runtime
enforces the boundary: live changes are validated before they become a
generation, in-flight turns stay pinned, rollback is one command, and no live
change can grant a permission the runtime withheld.

Against the field:

| Them | Shift |
| --- | --- |
| Behavior fixed by the vendor, adjusted through settings and prompts | Behavior is a live image you edit in the session; a validated change is the next generation |
| A transcript | A receipt per turn: files, runs, tokens, judge verdicts, the trace id, the resume command |
| Trust the agent, or approve every step | Three modes, allowlists, a judge with a confidence, and rules that never reach the judge |
| Skills you write | Skills the agent proposes after a hard or a good turn, disabled until you accept them |
| Benchmarks in a blog post | Evals in the repo, with the misses and the reruns written down |
| Cloud first | A local model first; keys and secrets redacted from every log |

## The three pillars, each with its proof

**Yours.** The agent file is Scheme you edit live; `/eval` and the `extension`
tool make generations, `/rollback` undoes one, extensions persist as
artifacts. The terminal is yours too: themes that are also Ghostty themes,
project panes as data, a wordmark you replace. Proof: the generation model in
`docs/coding-workflow-rfc.md`, the live-repair evals, the TUI captures.

**Accountable.** Every turn ends in a receipt. Every session is a folder;
subagents are folders under their parent; traces are searchable from any
session. Policy is explicit: manual, plan, autopilot, run allowlists, a typed
judge (Jev) whose confidence is logged, fixed deny rules that run first.
Proof: `/receipt`, `/judge report`, the judge cases in `evals/judge`, the
redaction tests.

**Compounding.** Workflows are procedures with checks that decide. Field
notes turn each tool rejection into one line every later session reads.
Reflection after a hard turn and distillation after a good one propose
skills, disabled until accepted. `/workflow improve` keeps a change only
when two subagent runs say it won. Proof: `docs/workflows-rfc.md`, the run
records under `.shift/workflows/*/runs`, the versions log.

Measurement is the fourth thing and it is not a pillar; it is the reason the
other three can be claimed at all. The site shows the numbers the repo shows:
the SWE-bench slice, the Terminal-Bench and DeepSWE probes, the judge
agreement, each with its date and its caveat. A number without a caveat is
marketing; Shift's brand is that it does not do that.

## Who it is for

Developers who want to read, change and hold to account the agent they work
with all day. Concretely: people running local models who are tired of agents
that assume a cloud key; people who have hit a vendor agent's ceiling and
want to change the behavior, not file a request; people who need to know
what an agent did to their tree before they commit. Not: people looking for
a chat window, and not people who want an agent to run unwatched for a day
without a receipt.

The maturity statement, said once and plainly: Shift is early. Its author
uses it daily on its own repository, its evals are in the repo, and its
edges are documented. That replaces "spike", "experiment", "toy" and "not
production" everywhere they appear.

## Voice

Plain, specific, evidence first. Short sentences that say what happens. No
adjectives doing the work a fact should do. Numbers only with a date and a
caveat. Second person for the reader, first person never for the agent.

Before and after, from the current site:

| Now | Instead |
| --- | --- |
| "An agent, made yours." | "Your agent. Live, and on the record." |
| "Shift is a tiny coding-agent harness with a live Scheme heart." | "Shift is a coding agent whose behavior is your own live program." |
| "An executable spike. Not a production coding agent yet." | "Early, used daily, measured in the repo." |
| "Your tools feel better when they feel like you." | "Change the agent while it runs. Read the receipt when it stops." |
| "A Shift experiment. Make the agent your own." | "Shift. The coding agent that belongs to you." |

Words retired: spike, experiment, toy, tiny, heart, playground, magic.
Words kept: live, generation, receipt, trace, judge, workflow, yours.

## Name and mark

The name stays Shift; the command stays `shift-agent` because `shift` is a
shell builtin, and the site says so once. The wordmark is `shift ///`; the
three strokes are the mark, and they move only while the agent works. That
motion is the one animation the brand owns, and it means the same thing on
the site as in the terminal: work in progress, not decoration.

Tagline, recommended: **The coding agent that's yours to change.** It states
the ownership claim, it is a promise the runtime can keep, and it survives
without the word "live", which readers outside Lisp do not feel.
Alternatives considered: "Change the agent while it runs" (true, narrower),
"An agent with a receipt" (true, leads with the audit trail rather than the
ownership), "Own your agent" (a slogan, not a sentence).

## Visual system

- **Palette:** Acid stays primary: deep purple canvas, lime cursor, cyan
  selection. It is already the TUI's default and the Ghostty theme, so the
  site, the terminal and the screenshots are one palette. Paddock, Blueprint
  and QDOS remain as the proof that themes are real, not as site modes to
  choose from on arrival.
- **Type:** one monospace family for everything the agent says or shows,
  one humanist sans for the site's own voice. Code is never set in the sans.
- **Imagery:** real captures of the real TUI, rendered from PTY recordings
  (the capture harness exists), never the simulated terminal. The simulated
  terminal survives only as the try-it-without-a-model demo, below the fold,
  labelled as a simulation.
- **Motion:** the `///` mark while work runs; nothing else moves.
- **Layout:** the receipt is a recurring visual element: a bordered block
  with files, runs, tokens, judge. It appears on the hero capture, in the
  accountability section and at the end of the install section as "your
  first receipt".

## The site, section by section

1. **Hero.** Wordmark, the tagline, one sentence of what it is, one real
   capture with a receipt visible, `brew install thrashr888/tap/shift`.
2. **Change it while it runs.** `/eval`, a validated generation, `/rollback`.
   A capture of a live change and the line that says which generation is
   current.
3. **Every turn leaves a receipt.** The receipt block, annotated. Sessions
   and subagents as folders. `/recall` across sessions.
4. **Policy you can read.** Modes, allowlists, the judge with its confidence,
   the rules that run first. One line on Jev with its date.
5. **Workflows that improve themselves.** A workflow file, its run record,
   a field note, a proposed skill, an improve log line: kept or discarded,
   and why.
6. **Measured.** The evals table from `docs/evals-rfc.md`, dated, with
   caveats. This section is the brand's spine; it is what makes the rest
   believable.
7. **Make it yours.** Themes, Ghostty, panes, the wordmark. Demoted from
   first to seventh; still true, no longer the headline.
8. **Start.** Install, first session, the demo without a model, the docs.

The theme and display-name controls that today sit above the hero move
into section seven. The first screen shows Shift, not a control panel.

## Open questions

1. Tagline: the recommendation above, or "Change the agent while it runs"?
2. Does local-first belong in the hero sentence, or in section four? The
   draft keeps it out of the hero: ownership is the claim, local is a
   consequence.
3. How much of the evals table goes on the site: the three headline rows, or
   the whole thing with reruns? The draft says the whole thing; the point is
   that nothing is hidden.
4. Whether to keep the site static HTML in `site/` (no build, no analytics)
   or move it. The draft keeps it: the constraints are part of the brand.
