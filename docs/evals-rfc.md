# RFC: a minimal evaluation set for Shift

Status: accepted September 8, 2026 with the draft answers to the open
questions: Sonnet 5 as the baseline and Haiku 4.5 for cheap regression runs,
dogfood tasks against the current tree, and local `pytest` for the first
SWE-bench run. Step one of the implementation order (print mode,
`--allow-run`, the 64-round ceiling, and `turn-token-budget`) is implemented,
and `scripts/evals.py` with the seeded slice exists ahead of order. First
graded result, September 8, 2026: `django__django-11099` resolved by Sonnet 5
in 17 seconds, 6 rounds, 33k prompt tokens of which 92% were cache reads.
The receipt landed September 9, 2026; `scripts/evals.py` now reads each
instance's `--receipt` file instead of reconstructing the turn from traces
and the ledger. Provider retries landed September 10, 2026, along with a
once-per-turn limit nudge (three rounds left or 80% of the budget) aimed at
the five round-limit misses. The dogfood task set is not implemented.

Rerun of the two misses with the corrected budget, September 9, 2026
(`evals/results/misses-2`): still 0 of 2. Sphinx-10435 patched
`sphinx/writers/latex.py` but hit the 40-round cap without running a single
test; SymPy-15875 completed with a fix that still fails `test_Add_is_zero`.
Both are model failures now, not harness artifacts. The agentkernel backend
was validated the same day on `matplotlib-22719` (`evals/results/ak-mpl`):
resolved, 6 rounds, two test commands inside the harness image, 62k prompt
tokens with 86% cache reads.

## Slice results, September 9, 2026

Single pass over the seeded 25-instance slice with Sonnet 5, graded by the
official harness: **16 of 25 resolved** (`easy-9`: 7 of 9 locally;
`rest-16`: 9 of 16 through the agentkernel backend). Two misses were
harness defects, both fixed and rerun (`rerun-2`): `sympy-23413` then
resolved, `django-15957` did not, which makes 17 of 25 with the fixes. A
third, `xarray-4695`, has the correct one-line patch applied but the
harness's own pytest segfaults under amd64 emulation on this machine before
any test runs, so it can only be graded on a native amd64 host. The other
six misses are model failures: five ended at the 40-round cap still working
(`seaborn-3187`, `pylint-8898`, `sphinx-9461`, `sphinx-10435`,
`django-15957`), and two completed with wrong fixes (`django-16877`,
`sympy-15875`).

Cost over the 16 sandboxed runs: 19.4M cached, 1.07M uncached, and 173k
output tokens across 67 minutes of wall time, dominated by emulated test runs.
Round limits, not budgets, are now the binding constraint on hard instances.

The 16 remaining slice instances ran through the agentkernel backend on
September 9, 2026 (`evals/results/rest-16`). Its first hard instance,
`django-15957`, exposed a harness defect: a 25 KB `edit` argument came back
from Claude as JSON our reader rejected, and the parse error failed the whole
turn after 30 rounds and 2M tokens. Tool arguments that are not a valid JSON
object now fail only that call, with the parse error returned to the model,
in all three adapters; the streaming request timeout also rose from 120 s to
600 s so long generations cannot truncate. Instances later in that batch ran
with the fix, since `bin/shift` rebuilds on launch. The batch's last instance,
`sympy-23413`, failed differently: a response hit the 8192-token output
reserve, and a completion cut off at `max_tokens` fails the turn by design
rather than executing a partial tool call. The driver now sets
`output-reserve` to 32768. A softer recovery, keeping the partial text and
nudging the model to continue in smaller steps, is a candidate follow-up.

First graded batch, September 8, 2026, the nine `<15 min fix` instances of the
slice with Sonnet 5 (`evals/results/easy-9`): 7 of 9 resolved. All five
Django instances, `matplotlib-22719`, and `sphinx-9698` passed; `sphinx-10435`
ended in exploration with no patch and `sympy-15875` left an applied but
incomplete fix. Five of nine runs were stopped by the token budget, three of
which still resolved, because the budget counted cache reads at full weight:
the batch read 3.79M cached tokens against 376k uncached and 52k output. The
budget now counts uncached prompt plus completion tokens, `shell` is excluded
from unattended runs through `SHIFT_TOOL_CEILING` since nobody can approve
it, and matplotlib's editable install failed on its C extensions, which the
record flags.

## Why now

On September 8 Shift implemented one of its own RFC features in a single turn
(session `dogfood-status`, commit 74d4922). That is one trial on a hand-scoped
task with the file and function named in the prompt. Before claiming Shift is
a dependable coding agent, it needs a small, repeatable set of tasks it did
not write itself, graded by tests it cannot see, with cost and failure modes
recorded per task. The set has to be cheap enough to run after every change
to the coding loop, not once a quarter.

## Candidates

### 1. Self-dogfood tasks

Ten hand-written tasks against Shift's own repository, each a short ticket
plus a hidden test file that the task must make pass. The driver checks out a
fixed commit, runs Shift with the ticket, then runs the hidden test. Examples:
the `undoable turns` line, a `/run list` source column, an `apply_patch`
error message, a `status` line for the last undo.

- Cost: a few hundred thousand input tokens for the whole set with caching on.
- Measures the loop, not the model: tool choice, stale handling, approval flow,
  round limits, and whether the model's summary matches the diff.
- Runs in minutes, no Docker, no dataset download. This is the regression
  suite for the coding workflow.

### 2. SWE-bench Verified, a fixed 25-instance slice

Real repositories, hidden tests, and a standard grader. The interface fits
Shift as it is: the task is "produce a patch", and `git diff` of the working
tree after the run is the `model_patch` the harness grades.

- Slice: 25 instance IDs chosen once by a seeded shuffle and committed to
  `evals/swebench-verified-25.txt`, so runs compare across commits and models.
- Environment: the official harness pulls one prebuilt container per instance
  (about 1.1 GB each, amd64 only; the driver pre-pulls them on Apple Silicon).
  With `--backend agentkernel` the driver creates a sandbox from that same
  image with the host checkout mounted at `/workspace`, copies the image's
  build artifacts (compiled extensions, egg-info, generated version files)
  into the checkout once, records them in `.git/info/exclude`, and symlinks
  `/testbed` to `/workspace`, so the conda environment's editable install
  resolves to the model's live edits and C-extension repositories test
  correctly with no per-run sync. The sandbox gets 4 vCPUs and 4 GB; the
  default 512 MB was killed by matplotlib's suite. Without the backend, Shift
  runs `pytest` in a local `uv` virtualenv, which works for pure-Python repos
  and fails for the ones that compile.
- Cost: capped per instance by tokens and turns; a run that hits the cap is a
  recorded failure, not a retry.
- Output: resolved rate, plus per-instance receipt fields: rounds, tool calls,
  files touched, test runs, cached versus uncached tokens, wall time, and the
  failure class (patch rejected, tests never run, round limit, provider error).

### 3. Terminal-Bench

Terminal-Bench tasks are shell workflows inside a container: install, build,
configure, recover. Shift can express most of them through `run` and `shell`,
but the harness expects an agent that drives a terminal inside the task
container, so Shift would need to be installed in each image (Guile plus
ripgrep) and driven through print mode from an adapter. That is real work
with little overlap with the coding loop we are actually testing.

Recommendation: not in the MVP. Revisit after SWE-bench, when print mode and
the receipt exist, and only if we want evidence about shell-heavy tasks
rather than code changes.

## The MVP

Candidates 1 and 2, in that order. Candidate 1 is the fast loop; candidate 2
is the external number. Both share one driver and one result format.

## Harness gaps to close first

These came out of the dogfood run and block unattended evaluation.

1. **Print mode.** `shift --print "TASK"` (alias `-p`) runs the task with no
   prompt loop, prints the final answer, writes the receipt as JSON to a path
   given by `--receipt FILE`, and exits 0 on a completed turn, 1 on a failed
   or cancelled turn, and 2 on a harness error. Stdin is not read. It reuses
   the same controller as the REPL and MCP, like `--mcp` does.
2. **Unattended run approval.** `--allow-run PREFIX` (repeatable) seeds the
   session's `run-allow` list, so the eval driver decides which commands may
   run without a prompt. No other approval is granted; edits use accept mode.
3. **Tool rounds.** Raise the validated ceiling on `agent-max-tool-rounds`
   from 8 to 64 and add a per-turn token budget setting, `turn-token-budget`,
   that ends the turn with a recorded reason instead of silently continuing.
   The dogfood run used exactly 8 rounds and would have failed one read later.
4. **Provider retries.** Retry 429 and 5xx responses with bounded backoff and
   record each retry on the LLM span. A 25-instance run will hit rate limits.
   Done: `provider-retries` setting, `llm.retries` and `llm.retry_log`.
5. **The receipt.** RFC section 9 of the coding workflow, now with a JSON
   form. It is the per-task result record, so the driver never parses
   transcripts. Done: `--receipt FILE`, `receipts.jsonl`, and `receipt.*`
   span attributes.
6. **The driver.** `scripts/evals.py` with two subcommands: `dogfood` (tasks
   under `evals/dogfood/NAME/{task.md,test.*}`) and `swebench` (the slice,
   the harness, and a results table). Each task gets a fresh named session
   and a fresh checkout, and results land in `evals/results/DATE-MODEL.jsonl`.

## Metrics

Per task: resolved (bool), rounds, tool calls by name, files changed,
diffstat, test runs and their exit codes, input tokens split into cached and
uncached, output tokens, wall time, and failure class. Per run: resolved rate
and the median of each per-task number. No aggregate scores beyond those;
the point is to see which failure class dominates.

## Open questions

1. Model for the fixed slice: Sonnet 5 as the baseline, with Haiku 4.5 as the
   cheap regression model for the dogfood set?
2. Should the dogfood tasks pin Shift to a fixed commit, or always run against
   the current tree so they double as regression tests for the loop itself?
   The draft says the current tree.
3. Local `pytest` versus agentkernel containers for SWE-bench in the first
   run. The draft says local, to keep the first run about the loop.

## Implementation order

1. Print mode, `--allow-run`, round ceiling, and the budget setting.
2. The receipt with its JSON form.
3. Provider retries.
4. The driver and five dogfood tasks; run them on Haiku and Sonnet.
5. The SWE-bench slice file, the harness wiring, and one 25-instance run.
