# Answer tasks

Questions about this repository with a checkable answer and a checkable
method. `task.md` is the prompt; `expect.json` lists substrings the answer must
contain (`answer_contains`, all; `answer_contains_any`, at least one), optionally an `mcp_tools_prefix` that at least one MCP tool the model
called must start with (proof it used the plugin), and `plugins` on or off.
`scripts/evals.py answers` runs them in print mode against the current tree.
