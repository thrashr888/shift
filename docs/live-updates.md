# Live updates

In terminal sessions, the harness watches its selected agent image by default.
For redirected input it skips the watcher; use `--watch` to opt in. A distinct saved file
is rebuilt in a fresh Guile module, validated against the same authority ceiling
as `/reload`, and atomically becomes the current generation. Active session
patches are reapplied to the candidate. A turn that already captured an older
generation finishes on that immutable image; only later turns see the new one.

An invalid save never replaces the working image. The watcher reports and
journals one rejection for that exact content, then waits for another distinct
save instead of retrying noisily. This makes ordinary editor write patterns and
temporarily incomplete files safe to iterate on.

```sh
./bin/shift             # watcher enabled
./bin/shift --no-watch  # explicit/manual reload only
```

The boundary is intentional: this watches `agent/default.scm` (or the image
selected by `--agent`). It does not dynamically load changes to `src/live-agent`
or the trusted built-ins in `extensions/shift` inside the running process. Those modules own validation, filesystem
confinement, shell approval, transport, and tracing, so treating an arbitrary
source save as a trusted in-process production upgrade would erase the safety
boundary.

## Evolution toward production releases

A production release should use a supervisor and a versioned handoff rather
than mutating the stable runtime in place:

1. Fetch a content-addressed, signed release artifact into a staging slot.
2. Start a candidate process with a new runtime version and isolated endpoint.
3. Run startup validation and a read-only health turn.
4. Stop routing new turns to the old process while allowing pinned turns to
   finish.
5. Transfer durable references—session ID, transcript cursor, enabled extension
   names, active patch source, checkpoint version, and trace lineage—not live
   Guile objects or hidden model state. The current named-session checkpoint is
   the development-scale version of this handoff contract.
6. Atomically switch the endpoint to the candidate and record the release ID on
   every later trace.
7. Keep the previous process and artifact available for bounded rollback.

That path preserves the useful property of live generations: every result can
be attributed to both a behavior generation and a stable runtime release. The
current file watcher is the development-scale proof of the behavior-generation
half of that design.
