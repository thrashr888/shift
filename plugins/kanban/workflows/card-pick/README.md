# card-pick

Choosing is the part worth a procedure. `kanban_board` answers "what is on the
board" in one call; what it cannot do is notice that something is already in
Doing, or make you say why the top card and not the one under it.

The judge check on the choose step is there for the second one. A reason that
restates the card's title is not a reason, and it is the failure mode of asking
a model to justify a choice it already made.
