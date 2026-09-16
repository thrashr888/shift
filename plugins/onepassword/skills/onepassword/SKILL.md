---
name: onepassword
description: Work with the user's 1Password through the op CLI for non-secret operations (which vaults and items exist, whether a session is signed in) and know how Shift gets secrets from it. Use when a server or command needs a credential, or the user asks about their vaults.
---

# 1Password

Secrets never pass through the model. A plugin manifest or `.shift/mcp.scm`
names a secret reference and the runtime resolves it with `op read` when the
server connects, straight into the child's environment or a header:

```scheme
(secret DOCS_TOKEN (op "op://Private/Docs/token"))
(server "docs" (url "https://docs.example.com/mcp") (header "Authorization" "Bearer $DOCS_TOKEN"))
```

`op read`, `op item get`, `op document` and `op inject` are refused by a fixed
autopilot rule, so do not try to read a secret to paste it anywhere. What you
can do:

```sh
op whoami                 # signed-in account, or a prompt to sign in
op vault list
op item list --vault Private
```

If a secret reference is wrong, the server's failure reason names it; ask the
user for the right `op://vault/item/field` rather than guessing.
