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
the five round-limit misses. The first two dogfood tasks and the local runner
are implemented; the remaining three tasks have not been selected.

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
seven misses are model failures: five ended at the 40-round cap still working
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

## Seven-miss rerun, September 10, 2026

Rerun of the seven model misses with `ollama/qwen3.8:27b-mlx`, through
agentkernel and graded by the official harness (`evals/results/ollama-misses-7`):
**1 of 7 resolved**, `sympy-15875`. All four nonempty patches were graded
without harness errors; the three empty patches remain unresolved. The run
included provider retries and the finish nudge, with a 40-round cap, a 4M
uncached-input-plus-output budget, a 262,144-token context limit, and an
8,192-token output reserve.

| Instance | Graded outcome and turn ending | Rounds | Prompt tokens | Output tokens | Wall seconds |
| --- | --- | ---: | ---: | ---: | ---: |
| `django-16877` | Unresolved; completed with a wrong fix | 22 | 893,234 | 3,236 | 451.1 |
| `sympy-15875` | Resolved; completed | 26 | 1,442,697 | 3,851 | 667.4 |
| `sphinx-10435` | Unresolved; token budget, no edits | 39 | 4,036,787 | 3,323 | 1,270.2 |
| `seaborn-3187` | Unresolved; round limit with a patch | 41 | 2,296,297 | 6,313 | 1,819.5 |
| `pylint-8898` | Unresolved; round limit, no edits | 41 | 1,551,775 | 2,371 | 797.2 |
| `sphinx-9461` | Unresolved; context guard, no edits or test runs | 21 | 1,458,275 | 1,705 | 1,171.2 |
| `django-15957` | Unresolved; round limit with a patch | 41 | 2,594,327 | 5,669 | 2,059.0 |

Total: 14,273,392 prompt tokens, all uncached as reported by Ollama, and
26,468 output tokens over 8,235.6 seconds (137.3 minutes), excluding grading.
Rounds are receipt counts of model responses; the 40-tool-round limit can
produce a 41st response before refusing another tool call. The context
guard still stopped `sphinx-9461` in the larger window. After this run,
the estimate was calibrated against the last provider-reported full prompt
count for later rounds of the same turn, retaining the safety margin and
output reserve. That fix is regression-tested; this batch has not been rerun
with it. This rerun changes both provider and model, so it does not
isolate the effect of retries or the finish nudge.

## Dogfood assessment, September 10, 2026

Two tasks were attempted with `ollama/qwen3.8:27b-mlx` against clean commit
`35eb811`, locally, in `evals/results/dogfood-2-qwen`. One hidden-test pass
from one graded attempt; the second attempt was stopped by the user and is
ungraded. **Neither attempt delivered a completed, regression-clean patch.**

| Task | Outcome | Rounds | Prompt tokens | Output tokens | Wall time |
| --- | --- | ---: | ---: | ---: | ---: |
| status-last-undo | Hidden test passed; token budget exhausted; final coding suite had 3 failures | 38 | 2,007,389 | 5,657 | 861.8 s |
| run-list-source | User stopped; no edits or final receipt | — | — | — | — |

All first-task prompt tokens were uncached. Its implementation correctly exposed
undo chronology, but its tests mutated an existing shared fixture and included
an incorrect expected turn. Local follow-up isolated that fixture and corrected
the assertion. The allowlist source feature was implemented locally after the
second attempt stopped; it is not a model success. Both external acceptance tests
and the full regression suite validate the repaired tree. Original candidate
patches and logs remain unchanged for assessment.

Qwen's reported allocation grew from about 21 GB to 34 GB with a 131,072-token
context. Sampled macOS pressure stayed normal, while swap jumped from about
4.3 GB to 11.2 GB around the second task's start. The timing does not establish
which process caused the increase. Context size and container limits do not cap
the host Ollama allocation; pressure-only checks missed the swap increase.
No more model runs are planned for this batch.

The driver now saves a partial patch and an ungraded `user_stop` result on
interruption, then exits without starting another workload. A hidden-test pass
also requires `make test` to pass before future attempts count as resolved;
`grade_exit_code` and `regression_exit_code` distinguish the two checks. These
changes do not retroactively alter the original result. The two implemented
tickets now serve as regression cases: their baseline checks intentionally refuse
to launch another model against a tree where they already pass. New dogfood
attempts need an unsolved ticket.

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

Hand-written tasks against Shift's own repository, each a short ticket plus
a hidden test file that the task must make pass. The first two are
`status-last-undo` (successful undo chronology and ledger replay) and
`run-list-source` (settings precedence, terminal changes, and resume).

`scripts/evals.py dogfood --tasks status-last-undo,run-list-source --run-id NAME`
runs them sequentially. Each gets a fresh snapshot of the current working tree,
including non-ignored uncommitted files, with `evals/`, `.env`, and Git history
excluded. A fresh Git baseline captures the resulting patch. The host Shift
runtime conducts the attempt; the candidate's own code is rebuilt and tested
in its snapshot. Hidden tests run from outside the snapshot, before the model
to establish failure and again afterwards to grade the patch. They are withheld
from the model's checkout, not protected by an OS sandbox. Dogfood test commands
run locally; this path does not use agentkernel.

Results, patches, receipts, build/grader/model logs, and memory samples live under
`evals/results/NAME/`. Existing run names are refused. Model output goes directly
to disk; timeouts terminate the attempt's process group. User interruption saves
the partial patch without starting grading or another task. A hidden-test pass
is followed by the candidate's full `make test` suite before declaring resolution. On macOS, elevated
memory pressure prevents starting another task. Defaults are Qwen via Ollama,
40 tool rounds, 2M uncached-plus-output tokens, a 131,072-token context window,
an 8,192-token output reserve, a 1,800-second timeout, and a one-minute model
keep-alive. These are recorded in the run configuration and do not change the
SWE-bench defaults.

- Cost target: a few hundred thousand input tokens with caching. The first
  uncached local-model task used 2M prompt tokens, exceeding that target.
- Measures the loop, not the model: tool choice, stale handling, approval flow,
  round limits, and whether the model's summary matches the diff.
- No Docker or dataset download. The first local-model task took 14.4 minutes;
  cheap repeatability remains unproven. This is the regression
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
