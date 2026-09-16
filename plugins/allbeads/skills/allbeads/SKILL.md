---
name: allbeads
description: Track and pick up work with beads (bd) in one repository and AllBeads (ab) across all of the user's repositories. Use when asked what to work on next, to file or close an issue, or to see blocked and dependent work.
---

# allbeads and beads

`bd` is the per-repository tracker: issues live in a local Dolt database,
`.beads/issues.jsonl` is a passive export, and sync rides on git. `ab`
aggregates every registered repository and adds cross-repo orchestration.

```sh
bd ready                 # unblocked work here
bd show ID               # one issue with its dependencies
bd create --title "..."  # file work; bd close ID when done
bd blocked
ab ready                 # prioritized unblocked work across all contexts
ab list -C QDOS,AllBeads # filter to projects
ab show ID
```

Reads are on the run allowlist through this plugin. Creating, updating and
closing issues are judged or asked like other runs; state the id and the
change. `bd ready` before starting and `bd close` after finishing keeps the
graph honest.
