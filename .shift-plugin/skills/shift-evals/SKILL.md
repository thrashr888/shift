---
name: shift-evals
description: Run and read Shift's evaluations — the SWE-bench slice, dogfood tickets, judge agreement, compaction scoring, and Terminal-Bench or DeepSWE through Harbor. Use when asked to measure a harness change, investigate a miss, or interpret an eval result.
---

# Evaluations

`docs/evals-rfc.md` is the source of truth: the slices, every recorded run and
what each one showed. This skill is the operating instructions and the traps
that cost the most time; read the RFC for results and history rather than
trusting a summary here.

## The driver

```sh
python3 scripts/evals.py --help
```

```sh
python3 scripts/evals.py fetch                       # cache SWE-bench Verified
python3 scripts/evals.py slice                       # the seeded 25-instance slice
python3 scripts/evals.py run [--instances A,B]       # print-mode run per instance
python3 scripts/evals.py grade RUN_ID                # official harness
python3 scripts/evals.py dogfood [--tasks A,B]       # current-tree tickets, hidden local tests
python3 scripts/evals.py session [NAME|--all]        # per-turn review
python3 scripts/evals.py judge [--cases|--session N] # judge agreement
python3 scripts/evals.py compaction [--replay]       # summary fact coverage
python3 scripts/evals.py live-repair [--tasks A,B]   # live_eval vs edit-plus-reload
python3 scripts/evals.py terminal-bench [--tasks ..] # through Harbor
python3 scripts/evals.py deepswe [--tasks A,B]       # through Harbor
```

Results land in `evals/results/RUN_ID/`: `predictions.jsonl` is what the
harness grades, `results.jsonl` is one metrics record per instance. Both come
from the receipt Shift writes with `--receipt`, never from the transcript.

## Validate a slice before believing a miss

```sh
python3 scripts/evals.py terminal-bench --tasks NAME --oracle
```

`--oracle` applies the task's reference solution through Harbor. If the oracle
run does not pass, the task is broken in this environment and a Shift failure
on it says nothing about Shift. Do this before investigating any new miss.

## Harbor gotchas

These are environmental and will waste a run each if forgotten. The RFC's
Terminal-Bench and DeepSWE section has the full reasoning.

- **Guile version.** Task images ship Debian 12's Guile 3.0.8 as often as not,
  and Shift's `run` tool needs the `spawn` that 3.0.9 added. The adapter
  installs a pinned conda-forge Guile through micromamba for this reason; if a
  container's toolchain looks like it should work and does not, check which
  Guile is actually on `PATH` there.
- **The gost 15-second timeout.** DeepSWE's agent phase runs with no network,
  and reaching a local Ollama goes through a gost sidecar that drops any
  connection whose response headers take over 15 seconds — which a local
  model's prefill routinely does. An extra compose file mounts
  `evals/harbor/gost.yaml` over the sidecar's own config to fix it. Every model
  call in the first DeepSWE run died at exactly 15.0 seconds.
- **Uncommitted work scores zero.** DeepSWE grades `git diff BASE HEAD`, so the
  adapter commits whatever changed after the turn. A change left in the working
  tree is invisible to the verifier.
- **Non-Python DeepSWE images** have shipped zero-byte toolchains in this
  environment. Confirm with `--oracle` before reading a failure as Shift's.

## Reading a result

A benchmark turn leaves a session folder next to its receipt, so
`scripts/evals.py session` reviews it like any other session. Prefer the
receipt's own numbers — rounds, tokens, cost, status — over anything narrated
in the transcript; the receipt is projected from the ledger and the trace,
and a model's account of what it did is not evidence.
