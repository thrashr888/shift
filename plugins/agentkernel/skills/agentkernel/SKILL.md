---
name: agentkernel
description: Run commands in an isolated agentkernel sandbox (Linux container or microVM) instead of the host. Use for untrusted or generated code, package installs, and test suites that could touch the machine; not for macOS-only builds, signing, or git with the user's keys.
---

# agentkernel

`agentkernel run CMD...` executes one command in a temporary sandbox and removes
it afterwards. The runtime image is picked from the command (`python3`, `npm`,
`cargo`, `go`); `--image IMAGE` overrides it and `--no-network` cuts the network.
On this Mac the backend is a Linux container, so the sandbox has no macOS
toolchain: `cargo tauri build`, `codesign`, `xcodebuild` and `git` with signing
keys stay on the host.

Inside Shift, prefer the session-level switch to per-command wrapping:
`/sandbox NAME` routes every `run` through `agentkernel exec NAME` with the
project mounted at `/workspace`, and runs headed there need no approval; the
`run-host` prefixes (git, cargo tauri, codesign, xcodebuild, xcrun, notarytool,
open, swift, swiftc, brew) still execute on the host. `/sandbox off` returns
to the host.

Note the sandbox's working directory is `/` unless a named sandbox was created
in the project; `agentkernel run pwd` shows which case you are in.
