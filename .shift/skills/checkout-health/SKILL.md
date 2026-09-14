---
name: checkout-health
description: Check a Git checkout's health by reporting whether the working tree is clean and what the recent commits are; use when asked to assess, summarize, or sanity-check the current repo state before or after work.
---

# checkout-health

Report a Git checkout's health in one or two sentences: whether the working tree is
clean (no uncommitted changes) and what the last commit was.

## When to use

- User asks to "check the checkout", "is the tree clean", "what did we last commit",
  or to summarize repo state before/after a change.
- Pre-flight before a risky task or before reporting work done.
- Triage: distinguish a dirty tree (needs attention) from a clean one.

## Steps

1. Run `git status --short` and `git log --oneline -3` **in parallel** (independent reads).
   In this runtime, use the `run` tool with an argv list:
   `["git","status","--short"]` and `["git","log","--oneline","-3"]`.
2. Read the status output:
   - No output lines → tree is clean.
   - Any line (`M`, `A`, `D`, `??`, `R`, etc.) → tree is dirty; list the paths.
3. Read the log output: the first line is the last commit. Take its short SHA and subject.
4. Summarize in two sentences:
   - Sentence 1: clean vs. dirty, naming the dirty paths (if any).
   - Sentence 2: "The last commit was `<sha>` — `<subject>`."

## Commands that worked

```
git status --short          # porcelain, one line per changed path; empty = clean
git log --oneline -3        # last 3 commits: "<sha> <subject>"
```

Both returned exit 0 and are safe read-only commands.

## Pitfalls

- **Not clean ≠ broken.** A dirty tree just means uncommitted changes; report it, don't fix.
- **Read the paths, don't guess.** Quote the exact paths from `git status --short`.
- **Bare SHA + subject.** `--oneline` gives `<sha> <subject>`; use that, not full hashes.
- **Not a repo / no commits.** If a command exits non-zero, report the error instead of a
  clean/dirty verdict. See [reference.md](reference.md) for edge cases.
- **argv, not shell.** Prefer the `run` tool with an argv list so `--` and paths are
  not mangled by shell parsing.

## What to verify

- Confirm exit code 0 for both commands (or report the real error).
- Confirm the two-sentence summary matches: status output → clean/dirty verdict, and
  first log line → last commit SHA + subject.
- No secrets or machine-specific paths in the report.

See [reference.md](reference.md) for the full status-code table, edge cases, and examples.
