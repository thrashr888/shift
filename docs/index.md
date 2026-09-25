# Shift documentation

One line per document, then the open work those documents still describe.

| Document | What it holds |
| --- | --- |
| [daily-driver.md](daily-driver.md) | The user guide: projects, settings, providers, policy modes, print mode, MCP, and the terminal interface. |
| [daily-driver-plan.md](daily-driver-plan.md) | The September 4–6 plan for the daily-driver foundation and what has shipped since. |
| [coding-workflow-rfc.md](coding-workflow-rfc.md) | Accepted RFC for `status`, `diff`, `apply_patch`, `run`, the change ledger, `/undo` and the receipt. All implemented. |
| [evals-rfc.md](evals-rfc.md) | Accepted RFC for print mode, unattended runs, retries and the evals driver, with the SWE-bench slice results. |
| [live-updates.md](live-updates.md) | How live Scheme generations validate, activate and roll back, and the handoff a production runtime would need. |
| [durability-and-prompt-cache.md](durability-and-prompt-cache.md) | Trace history, compaction evidence and prompt-cache strategy. |
| [subagents.md](subagents.md) | RFC: subagents as session folders under their parent, spawned as background jobs, plus project trace recall; implemented. |
| [dogfooding.md](dogfooding.md) | Running Shift on its own repository and what still blocks primary-agent use. |
| [gaps-with-pi.md](gaps-with-pi.md) | The asymmetric comparison with Pi, refreshed September 13. |
| [review-2026-09-04.md](review-2026-09-04.md) | The September 4 runtime review; its seven findings are fixed. |
| [ablation-2026-09-04.md](ablation-2026-09-04.md) | Evidence for those fixes and the built-in ablation. |
| [skills-and-jobs-rfc.md](skills-and-jobs-rfc.md) | RFC for skills, background jobs, concurrent read-only tools, and the composable sidebar; implemented. |
| [mcp-client-rfc.md](mcp-client-rfc.md) | RFC for the MCP client and `tool_search`; implemented. |
| [plugins-rfc.md](plugins-rfc.md) | RFC: plugins as folders of data that bundle skills, MCP servers, panes, themes, allowlist proposals and live-image artifacts; implemented, seven bundled. |
| [plugin-tools-rfc.md](plugin-tools-rfc.md) | Draft RFC: declared tools as a schema over an argv template, pane rows that act, and pane actions that invoke workflows. Plugins still supply no code; language servers stay a plugin concern over MCP. |
| [autopilot-judge-rfc.md](autopilot-judge-rfc.md) | RFC: autopilot resolves rules first, then a separate judge model, with a shadow mode; implemented. |
| [quality-rfc.md](quality-rfc.md) | RFC: judge evals, session review, compaction scoring, diagnostics, hardening, the runtime handoff and the live-repair proof, in that order. |
| [context-notes-rfc.md](context-notes-rfc.md) | Notes-first compaction after Codex's context management: one `notes` tool, `/compact` and the budget guard do the loop on the backend, summary as fallback; implemented. |
| [brand.md](brand.md) | The brand proposal: what Shift claims to be, its three pillars with their proof, voice, the words retired, the mark, the visual system, and the site section by section. |
| [workflows-rfc.md](workflows-rfc.md) | Workflows as durable procedures with checks, and the self-improvement loop: field notes after every turn, reflection after hard turns, distillation after good ones, `/workflow improve` kept only by a measured comparison. All implemented. |
| [jev-rfc.md](jev-rfc.md) | RFC: TypeSafe Jev as a typed judge backend behind `judge-model`, then `tool_search` and skill selection; never on by default. All five phases implemented; the gates await session data. |
| [website.md](website.md) | The showcase site, Ghostty themes, the pane pack reference, and how to publish. |

Pane packs have a published reference at
<https://thrashr888.github.io/shift/panes.html>.

## Open work

Collected from the documents above on September 16, 2026. Each item names the
document that explains why it matters.

Features:
  - **Distilled steps.** Distillation proposes skills; proposing a new workflow step from a good run is the part of source 2 still open ([workflows-rfc](workflows-rfc.md)).
  - **DeepSWE and Terminal-Bench slices.** The two benchmarks worth adding ([evals-rfc](evals-rfc.md)).
  - **Workspace forks for children.** Subagents share the working tree; a git worktree per mutating child is the follow-up ([subagents](subagents.md)).
Packaging:
  - **Export and promotion.** Session export and sharing, and a reviewed path from
    an exported Scheme artifact into base source ([gaps-with-pi](gaps-with-pi.md)).
  - **Packs.** File/URL extension packs ([daily-driver-plan](daily-driver-plan.md)).
Features:
Evals/Quality:
  - **Job resource limits.** Memory ceilings for jobs and subagents; macOS does not honour RLIMIT_AS and the run path has no shell ([quality-rfc](quality-rfc.md)).
  - **Symlink and race analysis** of the filesystem confinement ([gaps-with-pi](gaps-with-pi.md)).
  - **The proof, continued.** Rerun the live-repair set as the sandbox teaches the model less painfully; edit-plus-reload still wins on rounds ([quality-rfc](quality-rfc.md)).
