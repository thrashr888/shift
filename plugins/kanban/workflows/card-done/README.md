# card-done

The reason pane actions exist.

Moving a card to Done is two `edit` calls. Deciding it belongs there is running
the tests, reading the diff, and being honest about what changed that nobody
asked for. Done by hand, the first part happens and the second is assumed.

The checks are judged rather than commands because the test command is the
project's, not this plugin's. Each one asks whether something actually happened
in the session rather than whether the answer claims it did — a model reporting
that tests "should pass" fails the verify step, which is the whole point.

Runs land under `runs/`, so a card that moved without its checks passing is
visible afterwards rather than indistinguishable from one that earned it.
