# memory-sweep

What a session learned is lost unless someone writes it down, and at the end of
a long session nobody wants to. This is that job as a procedure.

The hard part is not saving; it is deciding what is durable. A fix whose cause
was found is worth keeping. A note that `main.scm` has a function at line 3400
is worth nothing by tomorrow. The judge check on the save step is there to
catch the second kind, because the failure mode is a store full of file
trivia that makes recall worse rather than better.

Runs land under `runs/`, so a sweep that saved nothing is visible as such.
