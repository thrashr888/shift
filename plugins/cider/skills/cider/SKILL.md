---
name: cider
description: Read and act on macOS Apple apps (Calendar, Reminders, Contacts, Notes, Mail, Music, Safari, Home and 30 more) with the cider CLI, which prints JSON. Use when the user asks about their calendar, reminders, contacts, notes, mail or Mac state, or wants one of those changed.
---

# cider

Every command prints JSON on stdout; add `--pretty` only when a human will read
it. Errors and progress go to stderr. Bulk reads use macOS's own indexes and are
fast; writes go through each app's supported automation interface and prefer
the durable ids the read commands return over titles or positions.

```sh
cider auth-status              # which apps can be read without a prompt
cider doctor                   # local databases, tools and permissions
cider calendar list --days 7   # upcoming events with ids
cider reminders list
cider contacts search "Ada"
cider notes list
cider apps                     # installed applications
```

Run `cider COMMAND --help` for the flags of any app. Reads are on the run
allowlist through this plugin; a write (create, update, delete) is judged or
asked like any other run, so name the exact id you are changing.
