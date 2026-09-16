---
name: tauri-browser
description: Automate, inspect and verify a running Tauri app through its debug bridge: DOM snapshots with element refs, screenshots, clicks and typing, JavaScript, Tauri command invocation, console and error history. Use when checking a Tauri app's UI or behavior end to end.
---

# tauri-browser

The app must be built with the tauri-browser plugin and running; `tauri-browser
connect` confirms the bridge. Output is designed for a model to read.

```sh
tauri-browser snapshot            # accessibility tree with @refs
tauri-browser click @e12          # by ref, or a CSS selector
tauri-browser fill @e7 "text"
tauri-browser run-js "document.title"
tauri-browser invoke command_name '{"arg":1}'
tauri-browser screenshot out.png
tauri-browser console             # recent console output, newest last
tauri-browser errors              # JS throws, rejections, Rust panics
tauri-browser state               # managed state
```

Take a snapshot before acting, act by ref, then snapshot again to verify.
Reads are on the run allowlist through this plugin; clicks, fills, JavaScript
and invokes change the app and are judged or asked.
