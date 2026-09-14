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
| [subagents.md](subagents.md) | The generation-pinned child contract; one supervised child is implemented, fan-out is not. |
| [dogfooding.md](dogfooding.md) | Running Shift on its own repository and what still blocks primary-agent use. |
| [gaps-with-pi.md](gaps-with-pi.md) | The asymmetric comparison with Pi, refreshed September 13. |
| [review-2026-09-04.md](review-2026-09-04.md) | The September 4 runtime review; its seven findings are fixed. |
| [ablation-2026-09-04.md](ablation-2026-09-04.md) | Evidence for those fixes and the built-in ablation. |
| [skills-and-jobs-rfc.md](skills-and-jobs-rfc.md) | RFC for skills, background jobs, concurrent read-only tools, and the composable sidebar; implemented. |
| [mcp-client-rfc.md](mcp-client-rfc.md) | RFC for the MCP client and `tool_search`; implemented. |
| [autopilot-judge-rfc.md](autopilot-judge-rfc.md) | Draft RFC: autopilot resolves rules first, then a separate judge model, with a shadow mode to evaluate it. |
| [website.md](website.md) | The showcase site, Ghostty themes, the pane pack reference, and how to publish. |

Pane packs have a published reference at
<https://thrashr888.github.io/shift/panes.html>.

## Open work

Collected from the documents above on September 13, 2026. Each item names the
document that explains why it matters.

Features:
  - **Subagent fan-out.** Parallel children with isolated workspaces ([subagents](subagents.md)).
  - **Project trace recall.** Cross-session search over a project's traces ([daily-driver-plan](daily-driver-plan.md)).
Packaging:
  - **Export and promotion.** Session export and sharing, and a reviewed path from
    an exported Scheme artifact into base source ([gaps-with-pi](gaps-with-pi.md)).
  - **Autopilot judge.** Rules, then a separate judge model, with shadow evaluation first; designed in [autopilot-judge-rfc](autopilot-judge-rfc.md).
  - **Packs.** File/URL extension packs ([daily-driver-plan](daily-driver-plan.md)).
Evals/Quality:
  - **Stable-runtime handoff.** The versioned supervisor for upgrading the trusted runtime in place ([live-updates](live-updates.md)).
  - **Compaction quality.** A summary-quality evaluator and deterministic replay ([dogfooding](dogfooding.md), [gaps-with-pi](gaps-with-pi.md)).
  - **The proof.** An evaluation showing that generation-attributed live repair beats edit-plus-reload on a realistic task set ([gaps-with-pi](gaps-with-pi.md), [evals-rfc](evals-rfc.md)).
  - **Diagnostics.** LSP or compiler JSON alongside exit status ([coding-workflow-rfc](coding-workflow-rfc.md), [dogfooding](dogfooding.md)).
  - **Hardening.** An authority audit of the Scheme evaluator, fuzzing, resource limits, secret redaction, trace privacy defaults, cross-platform testing([gaps-with-pi](gaps-with-pi.md)).