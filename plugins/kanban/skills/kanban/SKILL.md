---
name: kanban
description: Keep and change this project's board — read the columns, move a card, add or retire one. Use when asked what is in progress, what to pick up next, or to move a card between columns.
---

# kanban

The board is one file, `.shift/kanban.md`. The pane renders it and the
`kanban_board` tool reads it; both see the same text you would.

```markdown
# Board

## Todo
- [c1] Wire the receipt to the ledger
- [c2] Decide the compaction budget

## Doing
- [c3] Declared tools

## Done
- [c4] Pane actions
```

The format is the whole contract:

- A column is a `## ` heading. Name them whatever the project wants; three is
  a good default and nothing enforces it.
- A card is `- [id] title` under a column. The id is short, unique, and never
  reused — it is how a later session refers to a card whose title has been
  reworded.
- Order within a column is priority, highest first.

A project without a board starts one with `write`. Never create it as a side
effect of some other request; an empty board someone did not ask for is noise
in their repository.

## Moving a card

There is no kanban command. A card moves by editing the file, which means
`edit` with the exact card line as `old_text`, twice: once to remove it from
its column and once to add it under the new one. Read the board first, because
an `edit` against a line you assumed rather than saw is how two cards end up
merged into one.

Do not renumber, reword or reorder cards you were not asked to touch. A diff
that moves one card and silently reflows the rest is unreviewable, and the
board is a shared record rather than your scratch space.

## The two workflows

`card-pick` and `card-done` exist because moving a card is the easy half and
deciding whether it should move is the hard half.

- **card-pick** reads the board, chooses the next card with reasons, moves it
  to Doing, and says what the first concrete change will be.
- **card-done** verifies the work before the card moves: the project's own
  tests, the diff, then the move. Its checks are what stand between "I believe
  this is finished" and the card actually moving.

Run either with `/workflow run NAME`, or from the BOARD pane's actions. Prefer
the workflow over a bare edit when finishing a card: a run leaves a record
under `runs/` saying whether the checks passed, and a hand-moved card leaves
nothing.

## What the board is not

It is not an issue tracker. There are no dependencies, no cross-repository
view, no history beyond what git kept. If work needs those, use `bd` and the
allbeads plugin; this is for the handful of cards one project is holding in
its head right now.
