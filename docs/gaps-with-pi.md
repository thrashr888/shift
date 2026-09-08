# Gaps between this spike and Pi

Snapshot: 2026-09-04, rows refreshed 2026-09-08 after the daily-driver and
coding-workflow slices. “Pi” means the current Pi coding agent maintained at
[`earendil-works/pi`](https://github.com/earendil-works/pi) (the former
`badlogic/pi-mono` URL redirects there).

The two projects are not peers yet. Pi is a mature coding harness; this project
is an experiment around a constrained live language, atomic generations, and
observability. The useful comparison is therefore asymmetric.

## What this harness still lacks

| Gap | Why it matters |
| --- | --- |
| Coding workflow depth | `read`, `rg`, `write`, `edit`, `apply_patch`, `status`, `diff`, and an argv-only `run` with timeouts now cover the loop, with diff previews at approval, a hash-gated `/undo`, and `/recover restore`. Still missing: an end-of-turn receipt, diagnostics integration, and background jobs. |
| Session lifecycle depth | Named conversations now resume, compact, cancel, fork fixed checkpoints, and expose explicit interrupted-tool and interrupted-mutation recovery, but there is no share/export workflow or exact mid-process continuation. |
| Provider breadth | Native Ollama, streaming OpenAI Chat Completions, and a native Claude adapter with `/model`, `/effort`, `/fast`, and `/thinking` are still behind Pi’s provider catalog, authentication, retries, and multimodal handling. |
| Terminal product | There is no rich TUI, multiline editor, tool-call renderer, queueing, keybindings, themes, settings UI, or model picker. |
| Extension ecosystem | Named Scheme artifacts can now be created, listed, loaded, disabled, and exported, but there are no skills, prompt templates, dependencies, package registry, lifecycle/event API, custom UI, signatures, or compatibility metadata. |
| Embedding modes | There is no print/JSON mode, RPC protocol, SDK, web UI, or supported library boundary. |
| Long-session behavior | Boundary-safe model compaction, a token-budget preflight with `/context`, provider-reported usage on exit, cancellation, and interrupted-tool records now exist, but there is no provider retry/backoff, deterministic replay, or quality evaluator for summaries. |
| Production hardening | The Scheme evaluator’s authority surface needs a deeper audit, fuzzing, resource limits, symlink/race analysis, secret redaction, trace retention controls, and cross-platform testing. |
| Mutation lifecycle | Project-file mutations are now previewed as diffs, journaled with pre-images, and undoable. Live-image state can be exported as a named artifact and disabled, but there is still no reviewed diff for live patches, promotion into base source, migration, signature, or replay guarantee. |
| Performance evidence | There are no benchmarks showing that live Scheme changes are faster or more reliable than editing and reloading an extension. |

Pi already covers most of that surface: four run modes, broad providers,
`read`/`write`/`edit`/`bash`, session trees and compaction, extensions, skills,
prompt templates, themes, packages, and a full TUI. See Pi’s
[`README`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md),
[`usage`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md),
and [`extension`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
documentation.

## What Pi lacks relative to this experiment

| Gap | Important nuance |
| --- | --- |
| Transactional code generations | Pi can hot-reload extensions, but a reload replaces the extension/resource runtime. It does not expose a first-class, immutable generation with a fingerprint attached to every turn and tool call. |
| Granular live rollback | Pi’s session tree can branch conversation history, but it is not a rollback stack for an individual behavior definition. This harness can reject an invalid patch atomically or return to the prior code generation. |
| In-session constrained language | Pi extensions are TypeScript modules with normal process authority. This harness evaluates a curated Scheme surface with no direct filesystem, process, network, module-loading, or ambient `eval` bindings. |
| Stable capability ceiling | Pi explicitly has no built-in permission system; extensions run with the user process’s permissions. Here the live image cannot widen shell policy beyond `ask`, and file reads cross a stable project-root boundary. This is promising, not yet a security proof. |
| Generation-attributed diagnosis | Pi has a vendor-neutral telemetry contract, but it deliberately ships without an exporter. It also has no equivalent code-generation identity to correlate a changed function with before/after answers. This harness records the selector, selected paths, generation, result, and tool/LLM tree locally and in Phoenix. |
| Direct behavior patching by the model | Pi can ask the model to edit an extension and can arrange a follow-up reload, but the documented reload flow keeps the running handler in its old call frame. Here `live_eval` validates and activates a single function change for the next turn without rewriting a source file. |
| Built-in subagents and plan mode | Pi deliberately omits these and expects packages to add them. This harness now has one generation-pinned supervised child with linked traces and a durable narrower authority ceiling, but not parallel fan-out, isolated workspaces, or a plan-mode product. |

Sources: Pi’s
[`extension reload semantics`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md),
[`permissions statement`](https://github.com/earendil-works/pi#permissions--containerization),
and [`telemetry contract`](https://github.com/earendil-works/pi/blob/main/packages/telemetry/README.md).

## Gaps both projects still leave open

- A deterministic eval proving that a live context-selection change improves a
  realistic task set instead of one hand-built example.
- A safe promotion path from an exported Scheme artifact to reviewed base source
  code; persistence now exists, but review and promotion do not.
- Clear trace privacy defaults for prompts, model reasoning, file contents, and
  tool output.
- A replay model that says what happens when provider output, repository state,
  or external tools have changed since the original generation ran.

The next meaningful milestone is not “become Pi in Scheme.” It is to prove that
generation-attributed live repair produces a debugging loop Pi’s file-edit plus
reload model cannot express as clearly.
