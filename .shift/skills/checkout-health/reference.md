# checkout-health — reference

Extended material for the `checkout-health` skill. Keep this separate from SKILL.md so the
main file stays short and progressive.

## `git status --short` porcelain codes

Each line: `XY <path>`. `X` = staged, `Y` = unstaged. `??` = untracked.

| X / Y | Meaning |
|-------|---------|
| ` ` / ` ` | (not listed) |
| `M` / ` ` | staged modification |
| ` ` / `M` | unstaged modification |
| `A` / ` ` | staged new file |
| `D` / ` ` | staged deletion |
| `??` | untracked file |
| `R` / `R` | rename (staged / worktree) |
| `U` | unmerged (merge conflict) |

Any non-empty output means the tree is **dirty**. An empty output means **clean**.

## `git log --oneline -3` format

`<short-sha> <subject>`, one per line, newest first. The first line is the last commit.

Example:

```
9312272 Persist run allowlists per scope, add sidebar source rows, and grow skills
a0dc632 Render host command errors as one readable line
0c7a86e Add skills, background jobs, parallel reads, and a paginated tab strip
```

→ "The last commit was `9312272` — Persist run allowlists per scope, add sidebar source
rows, and grow skills."

## Worked example (clean-ish case)

Status:

```
 M docs/index.md
 M src/live-agent/tools.scm
 M test/tools.scm
```

Verdict: "The tree is **not clean** — three files have unstaged modifications: `docs/index.md`,
`src/live-agent/tools.scm`, `test/tools.scm`. The last commit was `9312272` — Persist run
allowlists per scope, add sidebar source rows, and grow skills."

## Edge cases

- **Not a git repo:** commands exit non-zero with "fatal: not a git repository". Report the
  error; do not claim clean/dirty.
- **No commits yet:** `git log` exits 128 ("your current branch 'main' does not have any
  commits yet"). Say "no commits yet" and still report the status.
- **Detached HEAD:** log still works; note the detached state if relevant to the user.
- **Submodule / nested repos:** a `M` on a submodule path means the submodule pointer moved.
- **Large output:** `--short` is compact; cap with `--porcelain=v1 -z` only if piping.

## Command variants

```
git status --short            # default: relative paths, compact
git status --porcelain=v1 -z  # NUL-separated, script-friendly
git log --oneline -5          # more history if context is wanted
git log -1 --pretty=%h        # short SHA only
git log -1 --pretty=%s        # subject only
```

## Do / don't

- Do report the real paths and the real last-commit subject.
- Do keep the summary to two sentences unless the user asks for more.
- Don't stage, commit, stash, or otherwise mutate the tree.
- Don't include absolute machine paths or secrets in the report.
