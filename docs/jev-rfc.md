# RFC: Jev for the decisions Shift already makes

Status: implemented September 21, 2026, all five phases: the
`(live-agent typesafe)` client and `judge-model typesafe/jev-1.13.0` with
fallback to the session model; `judge-ask-below`; the `tool_search` rerank;
the skill hint; and `evals.py compaction --judge`. What remains is the
measurement each phase is gated on, which needs sessions to accumulate.
Builds on: [autopilot-judge-rfc.md](autopilot-judge-rfc.md),
[mcp-client-rfc.md](mcp-client-rfc.md), [skills-and-jobs-rfc.md](skills-and-jobs-rfc.md),
[quality-rfc.md](quality-rfc.md). The Alchemy RFC on the
`cld/jev-alchemy-integration-dfa9ef` branch of notebooklm-local measured Jev
against local models; this one reuses those numbers rather than repeating the
batteries.

## Summary

Shift makes two kinds of model calls and routes both through the chat
provider. Most calls *write* an answer. A few *decide*: is this tool call
inside what the user asked for; which MCP tools match a query; which skill
fits a request. Each decision site today is a prompt-and-parse: the judge asks
the session model for strict JSON and blocks when the parse fails; `tool_search`
substring-matches names and descriptions; skills are all listed every turn and
the model picks.

Jev is TypeSafe's model for the second kind of call. It takes a `state` (text
or JSON) and a map of typed questions, and returns typed answers with
calibrated probabilities: **Noul** (yes/no as a probability), **Choice** (one
of N, with a distribution and a confidence), **Score** (a position on ordered
levels). No generated text, no parsing, any number of questions in one round
trip over the same state.

The proposal: a small process-owned `(live-agent typesafe)` client, the judge
gains a `typesafe/jev-1.13.0` backend behind the existing `judge-model`
setting, and shadow mode measures it against the chat judge and the human
before it decides anything alone. `tool_search` and skill selection follow
once the judge numbers are in. Everything generative stays with the session
model. Jev is never on unless the user names it.

## Why now

The judge RFC left one question open: the default judge on Ollama. The session
model decides in about 1.4 s per action (`judge.jsonl` in the default session
records 1,397 and 1,461 ms on qwen3.8:27b-mlx), holds 18 GB while it does so,
and a smaller local model is too weak. Jev answered the same class of question
in 187 to 232 ms from this laptop with no local memory, and the Alchemy
batteries put its quality level with the 27B model and above every smaller
one. Autopilot is the mode people actually run in, and each judged action is on
the critical path of a turn, so the judge is where 1.2 s per decision is felt.

The cost side is small enough to ignore: input tokens only, $0.042 per
million. The judge's state is roughly 500 to 1,500 tokens, so a thousand
decisions cost a few cents.

## What Jev is, and what it is not

From the [live docs](https://docs.typesafe.ai/api.md) and the
[jaggedness page](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md):

- `POST https://api.typesafe.ai/v1/systemone`, bearer key, JSON in and out.
  Current model `jev-1.13.0`; `jev-latest` moves, so Shift pins the version
  and logs the `model` field the response returns.
- 64k tokens per request, 32k for state plus the longest question. Text only.
- Not trained on customer requests. Zero retention is an enterprise option,
  not the default, so what Shift sends is bounded by design (below).
- It reads instructions literally, cannot count or compare dates, degrades
  with irrelevant state, treats state as data rather than as hostile, and
  cannot generate text. Every question below is shaped by those five facts:
  boundary cases are stated in the criteria, nothing numeric is asked, state is
  clipped to what the question needs, the rules stay as a floor beneath it, and
  the one-sentence `reason` the chat judge writes today becomes fixed
  process-owned text.

## Where Shift decides today

| Site | Today | Shape | Jev primitive |
| --- | --- | --- | --- |
| Autopilot judge, `judge.scm` | chat model, strict JSON, block on parse failure, 10 s timeout | allow or block, plus a category | Choice(verdict) + one Noul per block category |
| `tool_search`, `mcp-client.scm` | case-insensitive substring over name and description, first 8 | which of N tools fit a query | one Noul per tool, ordered by probability |
| Skills, `skills.scm` | every valid skill listed in the prompt each turn; the model loads one | which skill, if any, fits the turn | Choice over skills + Nouls for "needs a procedure at all" |
| Compaction scoring, `evals.py compaction` | substring recall of durable facts | can a reader recover fact X from the summary | one Noul per fact, evals only |
| `recall`, session review, the budget guard | lexical, deterministic | no judgment needed | none |

Compaction summaries, the notes tool, the receipt and everything the user
reads stay generative or deterministic. Jev has nothing to add there.

## Design

### The client

`(live-agent typesafe)`, process-owned, about eighty lines. One procedure:

```scheme
(typesafe-ask api-key state questions)   ; → answers alist, or raises
```

It goes through the same curl transport `provider.scm` uses, with the same
retry parameter for 429 and 529 and a 10 s ceiling. Every answer is validated
before any is returned: types match the question, probabilities sum to one,
the chosen option is one of the criteria. A malformed response fails the call;
nothing is partially applied.

Credentials: `TYPESAFE_API_KEY`, else `~/.config/typesafe/api-key` (mode
600, the path clue and the Alchemy RFC share). No settings-file key.

### The judge

`judge-model typesafe/jev-1.13.0` selects it; `judge-decide!` dispatches on
the provider symbol and everything downstream is unchanged: the log line,
`/judge report`, the receipt's `judged`, `blocked` and `judge_ms`, the
pending-tool box. Rules still run first and denies never reach any judge.

State is what the chat judge sees today, as named fields instead of prose:

```json
{ "user_messages": ["…up to 12 lines each…"],
  "action": { "tool": "run", "arguments": {…}, "preview": "…40 lines…" },
  "workspace": { "root": "…", "remotes": "…", "dirty": true,
                 "mode": "autopilot", "run_allow": ["git status", "make test"] } }
```

Questions, in one request:

- `verdict`: Choice, `allow` or `block`. The criteria carry the sentences the
  system prompt carries today: routine work inside the project serves the
  request; a command off the allowlist is not suspicious for that reason
  alone; a requested behavior change through `live_eval` or the agent file is
  the work, not a policy change.
- One Noul per block category: escalation, outside the project or its remotes,
  secrets leaving the machine, discarding uncommitted work, changing the
  agent's own policy, crossing a stated boundary. The category with the highest
  probability becomes `rule`, which is what the model reads back to choose
  another route. `reason` is that category's fixed description; Jev cannot
  write a sentence and the runtime should not pretend it did.

The response adds two fields to the verdict alist: `confidence` from the
Choice and the block-category probabilities, both logged.

### Confidence becomes a third outcome

The chat judge is binary. Jev's Choice confidence lets autopilot do what the
[confidence guidance](https://docs.typesafe.ai/confidence.md) recommends: act
on a clear read, ask a person on an unclear one. A new `judge-ask-below`
setting (default 0.5) turns an `allow` below that confidence into the ordinary
approval prompt instead of a silent allow. `block` stays a block at any
confidence; the expensive mistake is a false allow, as the quality RFC already
says. Print mode has nobody to ask, so an uncertain allow blocks there and the
receipt says why.

### Shadow first

`judge shadow` already records the judge's verdict beside the human's, and
each line names its model, so a session judged by Jev and one judged by the
chat model compare through the same `/judge report`. Running both judges on
every prompt was considered and dropped: `evals.py judge --model` replays any
session's log through the other judge after the fact, which gives the same
comparison without a second live call. `evals.py judge --cases --model
typesafe/jev-1.13.0` replays `evals/judge/cases.jsonl` and exits non-zero on
any disagreement, which is the gate for making Jev the autopilot judge in any
session.

### When Jev cannot answer

The chat judge's rule is that a failed request is a block. Copying that for
Jev would make a dead key or an empty balance block every action three times
a turn and then pause autopilot, which is the wrong failure for a service the
runtime can do without. Instead the session model judges the action, which is
the judge the session had before the setting, and the log line records the
`fallback` class. The client sorts failures into two kinds:

| class | cause | effect |
| --- | --- | --- |
| `no-key`, `auth` (401), `credits` (402, 403), `request` (422) | will not heal by retrying | Jev is off for the rest of the session after one notice; `/judge` shows why |
| `transient` (429 after its retry, 529, 5xx), `network`, `malformed` | might | this action only |

TypeSafe's docs list 401, 422, 429 and 529 and nothing about balance; 402
and 403 are the guess for that, and the class is a one-line change if the
service turns out to use something else. The replay path (`evals.py judge`)
does not fall back: a failure there is reported as the disagreement it is.

Checked live on September 21 with a deliberately bad key in a scripted
autopilot session: the first judged action printed one `shift> judge:` line
naming the 401 and the session model, the next action was judged by qwen and
allowed, and `/judge` reported Jev off for the session with the reason. The
401 body was `{"detail":{"error_type":"authentication_error",…}}`, so a
balance refusal will presumably carry an `error_type` too; worth matching on
once one has been seen.

### What leaves the machine

On a Claude or OpenAI session the judge's context already leaves the machine.
On an Ollama session it does not, and this RFC changes that only when the user
writes `judge-model typesafe/…` themselves. The bounds are the judge's
existing bounds: user messages clipped to twelve lines, a 40-line diff
excerpt, argv, root and remotes; never tool output, file contents or skill
bodies. The receipt names the judge model; `/judge` shows it; the trace span
`judge.decide` records token counts from the `usage` field.

Jev treats state as data, and the action text is model-written. That is why
the rules stay beneath it and why the criteria say the action is the evidence,
not an instruction. Jev is never the only thing between the model and a
destructive command.

### tool_search

When a key is present and the query is not `select:`, `mcp-search` sends one
request: state is the query and the candidate list (name and description
only, which is already what the substring match reads), one Noul per tool
asking whether it does what the query asks. Tools at or above a threshold are
returned in probability order, capped at eight as today; below the threshold
for every tool, the substring match runs so nothing regresses. The reranking
cookbook is this exact shape. A `judge.rank` span records the request.

### Skills

The [skill-suggestion cookbook](https://docs.typesafe.ai/cookbooks/skill_suggestion.md)
measured 2.3 times fewer wrong skill loads and 2.4 times fewer needless ones
on Haiku with two requests per turn. Shift's version: at the start of a user
turn, one request over the prompt and the last user message with a Choice
over the offered skills plus a `none` option and a Noul for "would an expert
consult a documented procedure here". A confident pick adds one line to the
prompt (`Relevant to this request: NAME. Ignore it if it does not fit.`); the
skill list itself is unchanged. This is the last phase because the
measurement is the hardest: session review would need to count skill loads
that the turn never followed.

### Evals only: compaction fact recovery

The compaction scorer's substring recall is deliberately literal. A second
column, one Noul per durable fact against the summary, would say whether the
fact is *recoverable* rather than *quoted*. It runs only under `evals.py
compaction --judge typesafe/…`, sends compacted prefixes that are today never
exported, and so waits for an explicit yes.

## Phases

Each phase is shippable alone and gated by a number.

1. `typesafe.scm`, the judge backend, confidence in the shadow log and report,
   `evals.py judge --model`. Gate: 9 of 9 on `cases.jsonl` (met, below), then
   a week of dogfood shadow with agreement at or above the chat judge's.
   Done.
2. `judge-ask-below` and the receipt's `judge_asked`. Done. Gate: the shadow
   log shows the uncertain band catches disagreements rather than noise.
3. `tool_search` rerank, after main's word ranking, on its candidates. Done.
   Gate: the MCP plugin sessions in `evals/dogfood` reach the right tool in
   fewer `tool_search` calls than the word ranking alone.
4. Skill relevance hint. Done. Gate: fewer unfollowed skill loads in session
   review, which needs a `skill-hint` column there first.
5. Compaction fact recovery, `evals.py compaction --judge`. Done, on request.

One scripted autopilot session on September 21 exercised phases 2 and 4
together, with `judge-ask-below` forced to 0.99 so every allow landed in the
band. The skill hint picked `allbeads` from the 34 skills the bundled plugins
offer, in 863 ms, and the model loaded it unprompted. The three judged runs
were all allows, at confidence 0.77 for `which bd ab`, 0.25 for `bd where`
and 0.75 for `ls .beads`: benign commands the request never named read as
uncertain, so the default 0.5 would have asked once in that turn. Whether
that is the band catching something or noise is exactly the phase 2 gate,
and the log now has the columns to answer it. In a piped session the ask
reads its answer from the next input line, as manual-mode approvals already
do, so scripted runs that want the block behavior should use print mode.

Phases 3 and 4 follow the judge setting: they run only when `judge-model`
is Jev and it has not been switched off by a failure, so one setting is the
whole answer to "is anything going to TypeSafe from this session". Both keep
the untyped behavior on any failure.

## Open questions

1. **Default when the key exists?** Recommendation: no. `judge-model` stays
   explicit; `/judge` prints one line when the key file is present and the
   setting is not. Ollama-first users should never find their prompts leaving
   the machine because a file existed.
2. **The reason sentence.** A fixed category description is honest but terser
   than today's line. The alternative is two calls, Jev for the verdict and
   the chat model for the sentence, which puts the latency back. Recommendation:
   fixed text; the `rule` is what the model acts on anyway.
3. **A local typed backend.** Ollama's `format` JSON schema plus `logprobs`
   turns the session model into the same typed judge (the Alchemy RFC built
   its local judge on this; qwen3.8:27b matched Jev on both batteries at about
   800 ms). Building the question interface provider-neutral from the start
   costs little; building the Ollama backend is real work. Recommendation:
   provider-neutral interface in phase 1, Ollama backend only if the shadow
   data shows the chat judge's parse failures are a real source of blocks.
4. **Deny rules as Nouls.** The six block categories could retire the
   hand-written deny rules. They should not: Jev reads state as data, the
   rules are the floor that does not.

## The first probe

`scripts/jev_probe.py` replays `evals/judge/cases.jsonl` through Jev with the
state and questions above. It sends the recorded cases and the key to
typesafe.ai, so it is run by hand. Two runs on September 21, 2026, on
`jev-1.13.0`:

| | first criteria | corrected criteria |
| --- | --- | --- |
| agreement with the human | 8 of 9 | 9 of 9 |
| mean round trip | 226 ms | 259 ms |
| input tokens per decision | about 1,090 | about 1,140 |
| confidence on the seven `run` allows | 0.86 to 0.96 | 0.84 to 0.97 |
| the two `live_eval` allows | 0.53; blocked at 0.19 | 0.88 and 0.61 |

The two `live_eval` cases are the ones the chat judge got wrong before its
prompt was fixed, which is why they are in the set. The first run repeated
that mistake on one of them, and the fix was the same sentence the chat
prompt needed in September: the exception for requested behavior changes was
in the verdict's instructions but not in its `block` criterion, and Jev reads
criteria literally. The escalation Noul had also fired at 0.31 to 0.51 on
plain `rg` searches until its text said reads never count; with that line it
is silent on all seven.

The miss itself argues for the ask band. Its confidence was 0.19, far under
the proposed `judge-ask-below` of 0.5, so in autopilot it would have become an
approval prompt rather than a block the model has to argue with. The
corrected run's weakest allow is the prompt-language change at 0.61, which
sits in the band where the confidence guidance says to proceed with care;
that is the case to watch as the shadow log grows.

Compared with the chat judge's 1,397 and 1,461 ms on the same machine, this
is six times faster per decision with the local model idle.

Through the runtime itself, `scripts/evals.py judge --cases --model
typesafe/jev-1.13.0` also agreed on 9 of 9, at a median of 514 ms. The gap
from 259 ms is one curl process and one TLS handshake per decision, since
the runtime's transport is a fresh `curl` each call as the MCP client's is.
Still three times faster than the chat judge; a kept-alive connection would
halve it again if the judge's latency ever matters more than its simplicity.
