# Live-repair tasks

Each task is a behavior defect in `agent.scm`, fixable two ways: with
`live_eval` in the running session (live) or by editing the agent file and
reloading (reload). `scripts/evals.py live-repair` runs every task both ways
in print mode and reports resolved rate, rounds and wall time per mode. The
claim under test is the README's: generation-attributed repair is faster and
no less correct than edit-plus-reload.

A task is a folder with `task.md` (what the user says), `defect.scm`
(definitions appended to the fixture agent that introduce the defect) and
`check.scm` (a `(define (check g) ...)` returning #t when the generation `g`
behaves correctly; `generation-ref` is available).
