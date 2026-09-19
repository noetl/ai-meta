# SLM execution context on EHDB — design + phased plan

**Status:** DESIGN ONLY. Nothing built, nothing merged, no prod change, no
running config touched. Branch `design/slm-ehdb-context`, cut from `origin/main`
at `7c2fad0b`.
**Date:** 2026-09-19.
**Subject:** use EHDB as the context-management substrate for noetl's internal
execution of AI-driven, dynamically generated playbook steps, with **Gemma 4**
as the small language model.

---

## 0. How to read the evidence marks

This program has been burned by confident-but-wrong claims, so every load-bearing
statement below carries one of:

- **VERIFIED** — read in this tree at the cited `file:line` during this session.
- **ASSUMED** — a design choice or an inference I did not execute. Named as such
  so a reader can attack it.
- **UNVERIFIED (external)** — Gemma 4 product facts supplied to this session.
  Not checked against a running model; nothing in the plan depends on a
  capability claim beyond "it serves an OpenAI-shaped chat/function-call API
  locally".

⚠ **Two links in this document point at a branch, not at `main`.** The
multi-region specs (`specs/active/2026-09-18-multiregion-ehdb/`) and the sibling
handover documents live on **`docs/multiregion-ehdb-plan`, unmerged**. On this
branch those paths do not exist. They are cited by branch name deliberately
rather than as relative links that would resolve to nothing.

---

## 1. Problem

noetl can already route between models. It cannot yet **accumulate the context
of an AI-driven run as first-class platform state**, and it cannot let a model
*propose work* under provenance and guardrails.

Concretely, today (§2) an AI step is a statically-authored step whose *routing*
is data-driven. The model's inputs and outputs live in the generic event payload
and in a per-step Python parse; there is no typed record of "what was in the
prompt when the model decided this", no fold that assembles the next prompt from
prior turns, and no schema gate between "the model emitted a step" and "the
worker ran it" — because the model cannot emit a step at all.

The goal is to make **AI execution context a projection over an append-only
event stream in EHDB's internal-context tier**, so that an AI-driven run is as
replayable, auditable and boundable as any other noetl run.

## 2. Grounding — what the DSL already does

### 2.1 Model calls are a registered tool kind

**VERIFIED.** `tool.kind: mcp` exists and is registered in the default registry:
`repos/tools/src/tools/mod.rs:108` (`registry.register(McpTool::new())`), with
the `Tool` impl and `fn name() -> "mcp"` at `repos/tools/src/tools/mcp.rs:219`,
`:221`. The registry registers **20** tools at `mod.rs:90–109`.

**VERIFIED.** There is **no `agent` tool kind** in that registry. `metadata.agent:
true` is playbook metadata, not a dispatchable kind — consistent with
noetl/ai-meta#252. Any design that says "add a `tool.kind: agent`" is proposing a
new kind, not using one.

The MCP tool is a JSON-RPC-over-HTTP bridge with endpoint resolution by
`config.endpoint`, then `NOETL_MCP_<SERVER>_ENDPOINT`, then `NOETL_MCP_URL`
(`mcp.rs` module doc). **This is the seam Gemma 4 plugs into** — §11.

### 2.2 The live cheap-first SLM pattern

**VERIFIED** in `repos/ops/automation/agents/troubleshoot/diagnose_execution.yaml`:

| Line | What it establishes |
| :-- | :-- |
| `:75` | `triage_model: "gemma3:4b"` — the local SLM default is a workload knob |
| `:287` | `triage_model: "{{ workload.triage_model }}"` — backend chosen by pointer, not by branch |
| `:301` | `kind: mcp` — the model call itself |
| `:338–342` | the completion is parsed in a **`python` step**, not trusted raw |
| `:431–432` | ⭐ **parse failure forces `confidence = 0.0`** — degrade-to-escalate, never degrade-to-invent |
| `:479–493` | `next:` + `when:` guards on `confidence` route to trust / stop / escalate |

So the existing pattern is: **statically-authored steps, data-driven routing,
code-validated model output.** The design below keeps all three properties and
adds one thing — the model may propose a *step spec*, which is then validated
and provenance-tracked exactly as harshly.

### 2.3 What "dynamic" already means — three real primitives

The DSL has no construct where a step's output becomes a new step body. It has
three composable primitives whose **effect** is runtime-determined work:

1. **Runtime-sized iterator fan-out. VERIFIED.**
   `repos/server/src/handlers/execute.rs:1589–1596` renders `loop.in` as a
   template against the live context (`renderer.render_to_value(loop_cfg.in_expr,
   &context)`), requires a JSON array, and sets `total = items.len()` at
   `:1615`. `step.enter` then carries `iterations_expected`. A second fan-out
   site exists at `:2039`. Modes `sequential | parallel | cursor` are validated
   at `repos/server/src/playbook/parser.rs:396–409`.
   **→ the NUMBER of step-runs is data at runtime; the SHAPE is authored.**

2. **Runtime-chosen child playbook. VERIFIED.**
   `repos/tools/src/tools/playbook.rs:99–102` renders the **entire** tool config
   through the template engine *before* deserialising into `PlaybookConfig`, so
   `path:` is itself runtime-resolvable.
   **→ WHICH playbook runs is data at runtime.**

3. **Runtime catalog registration. VERIFIED.**
   `repos/server/src/handlers/catalog.rs:26,49` (`POST /api/catalog/register`)
   and `:74,86` (`/register/batch`).
   **→ a playbook body can be created at runtime.**

⭐ **The design consequence, and it is the most important sentence in this
document: (3) then (2) is already "generate a playbook, then run it".** The
platform needs **no new execution primitive** for AI-generated work. What it
lacks is the *context substrate*, the *provenance*, and the *gate*. That is what
this plan adds, and nothing else.

**ASSUMED:** that composition has not been exercised as an AI-generation path in
this tree; I found no playbook that registers a generated body and then calls it.

## 3. Grounding — EHDB's internal-context boundary

**VERIFIED.** `docs/rfc/ehdb-layered-platform.md` §0 carries a **⛔ PROGRAM
INVARIANT**: EHDB is a noetl-centric internal store over a **fixed** set of
predefined datasets; it is never the durable system of record for business data;
it may hold business *processing context* transiently as a **write-behind cache**
— bounded, sunk to the customer's store, evictable.

**VERIFIED.** §0.1 enumerates the whole universe as **D1–D10**. The four that
matter here:

| Dataset | Key | Why it matters to this design |
| :-- | :-- | :-- |
| **D1** Event log | `global_sequence`, scoped by `execution_id` | where SLM context events append |
| **D3** Execution / projection read-models | `execution_id`, `event_id` | where the folded working context materialises |
| **D5** Object / blob | content digest | where an over-floor folded prompt goes, by reference |
| **D6** Vector / RAG | `(collection, point_id)` | the future semantic-retrieval plug — **platform docs only** |

⭐ **Design result: this plan adds no new EHDB dataset.** Everything maps onto
D1/D3/D5 (+ D6 later). That matters because §0.1 states adding a dataset is "a
deliberate, compiled-in change, never runtime DDL" — so a design that needed one
would be fighting the invariant.

**VERIFIED.** `docs/rfc/postgres-to-ehdb-internal-data.md` measures ~97% of the
prod Postgres bytes as internal orchestration, and names `result_store` (172 MB)
as the only genuine user/business store. The internal-vs-user split this plan
honours is therefore the established direction, not a new claim.

⚠ **VERIFIED and binding on §9.** The layered-platform RFC records: *"**never
wire a playbook user-document ingest to `rag::ingest`**"* — user-document RAG
goes to the user's own vector store via connector; noetl/ai-meta#197 tracks the
remaining guard test. **D6 in this design is for the platform's own SLM context
only. A user's documents never enter it.**

## 4. Constraints inherited

From the multi-region plan (branch `docs/multiregion-ehdb-plan`, its §2 + umbrella
spec), carried here unchanged because the SLM read path sits on top of them:

- **C1** — EHDB has no consensus and will not grow one for storage
  (`ehdb-l0/src/lib.rs:85`). VERIFIED there.
- **C2** — ordering is leaderful per shard; gaplessness depends on it
  (`ehdb-l0/src/engine.rs:712`). One writer per shard at any instant.
- **C3** — `FRAME_HEADER_LEN` is a fixed 12 bytes shared byte-identically with
  `durable_eventlog.rs`. New fields go in the **record body** as `Option<T>` +
  `skip_serializing_if`, or in an out-of-band per-shard marker.
  **→ every event type in §6 is additive in the body. No header change.**
- **C4** — the `primary`-serving event-log **tier** runs on
  `ehdb-reference::LocalReferenceEventLogDriver` over `ehdb-stream`, **not** on
  `ehdb-l0`. It has no seal, no parts, no replication.
  **→ bounded-staleness reads (§6.4) are inert on the tier until M0.5 lands.**
- **C5 (this plan)** — `global_sequence` is per-engine, not a global order
  (handover README fact 4). **→ a fold must not assume cross-engine ordering;
  the SLM context fold is scoped to one `execution_id` on one engine.**

⛔ **Forbidden instruments, inherited.** The handover README records that the
cross-store parity comparator and `/api/ehdb/projection-fold/diff/{id}` are
**forbidden as proof instruments** while stage-1 `digest_mismatch` is open. No
spec in this plan may use them. Each phase names its own instrument instead.

## 5. Concept → primitive mapping

The whole design in one table. Left column is the AI-execution concept; right is
the noetl/EHDB primitive it becomes. Nothing in the right column is new.

| AI concept | noetl / EHDB primitive | Dataset | New? |
| :-- | :-- | :-- | :-- |
| conversation / working context | **projection folded over the event log**, scoped to `execution_id` | D1 → D3 | no |
| a turn (prompt + completion) | two append-only **events** in the internal-context tier | D1 | new *event types*, additive |
| the folded prompt actually sent | event payload; over a size floor, a **`ResultRef`** to the blob | D1 + D5 | no |
| model decision / confidence | event payload field, already the routing input (§2.2) | D1 | no |
| an AI-proposed step | a **step spec** validated against the DSL schema, then registered | D7 catalog | no |
| running the proposed step | catalog register → child playbook by runtime path (§2.3) | — | no |
| provenance of a generated step | the register event + the call event, by `content_digest` | D1 + D7 | no |
| replay of an AI run | the existing per-execution replay over D1 | D1 | no |
| working-memory compaction | a **fold operation** that emits a summary event | D1 → D3 | no |
| semantic retrieval | D6 vector tier — **future**, platform docs only | D6 | not deployed |
| model version pinning | registry entry + digest in every turn event | G3 (SLM RFC §3) | no |

## 6. Context as events

### 6.1 The event family

Six additive event types on D1, all scoped by `execution_id`, all carrying the
step identity so a fold can attribute them. Names are proposals.

| Event | Emitted when | Carries |
| :-- | :-- | :-- |
| `slm.turn.prompted` | immediately before the model call | `model_ref` (§8.1), folded-prompt inline **or** `ResultRef`, `prompt_digest`, sampling params, the ordered list of `source_event_ids` the fold consumed |
| `slm.turn.completed` | on a parsed completion | raw completion **or** `ResultRef`, `completion_digest`, token counts, latency, `finish_reason` |
| `slm.turn.degraded` | on parse failure / timeout / refusal | the reason, and the fallback taken (`escalate` \| `abort` \| `computed_findings`) |
| `slm.step.proposed` | the model emits a candidate step spec | the spec, its `content_digest`, the turn that produced it |
| `slm.step.admitted` | the spec passed schema + policy validation | validator version, which gate admitted it (auto / human) |
| `slm.step.rejected` | the spec failed validation | the failing rule, so rejection is auditable and countable |

⭐ **`slm.step.rejected` is not bookkeeping — it is the instrument.** A phase that
can only observe admissions cannot tell "the model proposes nothing invalid" from
"the validator never runs". The rejection counter is what makes the RED→GREEN
control in §13 possible.

**C3 compliance:** every field above lives in the record **body**, `Option<T>` +
`skip_serializing_if`. No frame-header change. **ASSUMED** the existing event
envelope tolerates new optional body fields without a format break — this is the
first thing S0 must prove, not assert.

### 6.2 The fold is the context

Context assembly for turn *N+1* is a **deterministic fold** over the events of
turns *1..N* for that `execution_id`:

```
fold(execution_id, up_to_seq) -> WorkingContext {
    turns:      Vec<Turn>,          // prompted + completed pairs, in global_sequence order
    admitted:   Vec<StepSpec>,      // proposals that passed the gate
    rejected:   Vec<Rejection>,     // kept — the model is told what it got wrong
    summaries:  Vec<Summary>,       // §9 compaction output
    budget:     Budget,             // §10 loop bound, decremented by admissions
}
```

Two properties make this worth doing rather than passing a blob between steps:

- **It is re-derivable.** The working context at any point is a pure function of
  (event log prefix, fold version). Nothing is lost when a worker dies.
- **It reuses the existing read path.** It is a per-execution range scan on D1 —
  D1's declared access pattern in §0.1 is exactly *"append; range-scan after seq;
  per-execution replay"*. No new access pattern, therefore no new index.

### 6.3 Where the fold runs

**ASSUMED, and this is a real fork (F1, §14):** the fold belongs in the
**projection engine** (D3) rather than in the worker's Python. Rationale: it is
the same shape as every other read-model, it gets the projection tier's
replay-validation for free, and a fold in playbook Python would be a second
implementation nobody could compare against the first.
⚠ But D3's EHDB projection engine is **shadow, not authoritative** (the target
model in the saqbit-facing docs and the layered RFC both say so), so the honest
first implementation is a **fold in the server, reading D1**, with the projection
engine as the later home. S2 does the former; S5 moves it.

### 6.4 Reads, and the one thing not to invent

An SLM context read is a per-execution prefix read. It **must reuse** the
multi-region read path, not grow a parallel one:

- `ReadConsistency::{Strong, Bounded{max_staleness_ms}, Exact{at: Hlc}}` and
  `ClosedTimestamp` from **M3** (branch `docs/multiregion-ehdb-plan`,
  `specs/active/2026-09-18-multiregion-ehdb/M3-closed-timestamp.md`).
- The `VisibilityResolver` / `VisibilityPlan` from **M0** (same branch,
  `M0-resolvers.md`), whose degenerate arm is today's behaviour.
- Flags `NOETL_EHDB_READ_CONSISTENCY` (default `strong`) and
  `NOETL_EHDB_MAX_STALENESS_MS` (default `0`).

⚠ **Two dependency facts, stated so a later session does not trip on them.**
(a) Per **C4**, the tier has no closed timestamp until **M0.5**; a bounded read
requested before then is *inert*, not wrong — it silently behaves as `strong`.
An inert flag that reads as armed is precisely the failure class this program
keeps hitting, so **S4 must assert inertness explicitly** rather than assume.
(b) **Default `strong` is correct for the SLM fold** anyway: a turn must see its
own predecessor. Bounded staleness is for *observers* of an AI run — the console,
drift monitors — not for the generate loop.

## 7. Dynamic steps with provenance

The generate→run path, composing only §2.3's verified primitives:

```
slm.turn.completed
  └─> slm.step.proposed      (spec + content_digest)
        └─> VALIDATE         §10 — schema, policy, budget
              ├─ fail -> slm.step.rejected      (fold feeds it back to the model)
              └─ pass -> slm.step.admitted
                    └─> POST /api/catalog/register      (catalog.rs:49)
                          └─> tool: playbook, path templated  (playbook.rs:99)
                                └─> ordinary noetl execution, ordinary events
```

Provenance is a chain of digests, not a narrative: the admitted spec's
`content_digest` is what gets registered, and the registered catalog entry is
content-addressed (**ASSUMED** — D7's key in §0.1 is "catalog id / path", so
digest-addressing may need to ride in the register payload; S3 must check
`catalog.rs` rather than assume).

⭐ The child execution then produces **ordinary** events. An AI-generated step is
not a special execution mode — it is a normal execution whose *origin* is
recorded. That keeps replay, retry, metrics and the drill-down working with zero
new machinery.

## 8. Determinism and replay

This is the section where "dynamic" has to stop being hand-waved.

### 8.1 Pin the model as a value, not a name

`model_ref` is recorded on **every** turn event as a struct, never a bare string:

```
ModelRef { family: "gemma-4", variant: "31b-it", digest: "sha256:…", server: "ollama|vllm|gke", api: "openai-chat" }
```

`gemma-4-31b-it` alone is a moving target the moment a registry re-tags.
**UNVERIFIED (external):** Gemma 4 is distributed as `gemma-4-31b-it` via Ollama
and on HuggingFace; whether the local server exposes a content digest is exactly
the thing **S6 must verify before the field is called authoritative.** If it does
not, the honest record is `digest: null` plus the resolved local blob hash, and
the design says so rather than storing a name and calling it a pin.

### 8.2 Sampling is where determinism actually breaks

Being blunt, because this is the part that is usually fudged:

**A sampled completion is not reproducible, and no amount of event-sourcing makes
it so.** Same prompt + same weights + `temperature > 0` gives a different string.
Even at `temperature = 0`, bitwise identity across a batch-size change, a kernel
change, or a different GPU is not guaranteed.

So the design offers **two honest modes, named differently on purpose**:

| Mode | What is guaranteed | How |
| :-- | :-- | :-- |
| **Replay** (default) | The run re-executes **exactly**, because the recorded completion is *the input*. The model is **not called**. | Fold reads `slm.turn.completed` from the log and returns it |
| **Re-derive** | The run is re-attempted with pinned inputs. The completion **may differ**. | Model called with recorded prompt + sampling params + `model_ref` |

⭐ **Replay does not re-run the model.** That single decision is what makes an
AI-driven run auditable: the audit question is "given this context, what did the
model say and what did we do with it", and that is fully answered by the log.
Re-derive answers a different question — "is this still what it says" — and is
for drift monitoring, not for audit.

`seed` is recorded when the server accepts one, and `temperature: 0` is the
**recommended default for step generation** (F3, §14) — not because it makes
replay work (it does not), but because it narrows the re-derive delta, which is
the only thing it can honestly buy.

### 8.3 What a replay proves

A replayed AI run proves: the same folded prompts were assembled, the same
specs were admitted or rejected by the same validator version, and the same child
executions were launched. It does **not** prove the model would say it again.
The design states that in the doc rather than letting a reader infer the stronger
claim.

## 9. Working memory, windowing, compaction

- **Working context = the projection.** Windowing is a fold parameter
  (`up_to_seq`, `max_turns`, `max_tokens`), not a separate store.
- **Compaction is a fold op that emits an event.** When the fold exceeds its
  token budget it emits `slm.context.summarised` carrying a summary + the range
  of `source_event_ids` it replaces. The originals are **never deleted** — D1 is
  append-only — so a later fold can choose the summary or the detail. This is the
  same shape as the platform's other read-models: derive, don't destroy.
- ⚠ **Summarisation is itself a model call**, so it emits its own turn events and
  is subject to the same budget. A compaction loop that can trigger compaction is
  the unbounded-recursion hazard §10 bounds.
- **Vector retrieval is a future plug, not a phase.** D6 exists in §0.1 and is
  **not deployed**. When it is, `fold()` gains an optional retrieval arm.
  ⛔ **Bound, repeated from §3:** D6 here holds the platform's own SLM context
  only. A user's documents go to the user's own vector store via connector.

## 10. Safety and guardrails

Five gates, each independently flag-gated, each failing **closed**.

1. **Schema validation before execution.** Every proposed spec is validated
   against the DSL schema *before* anything is registered — the same validation
   the parser applies (`repos/server/src/playbook/parser.rs`). **ASSUMED** the
   validator is callable as a library from the admission path; if it is only
   reachable through the HTTP register endpoint, then register-with-dry-run is
   the gate and S3 says so. **A second implementation of DSL validation is
   forbidden** — two validators that disagree is worse than one that is strict.
2. **Policy allowlist on tool kinds.** A generated step may only use kinds on
   `NOETL_SLM_ALLOWED_TOOL_KINDS`. Recommended default (F4): `python`, `http`,
   `noop` — read-shaped only. ⚠ `python` is *not* actually read-shaped; it is on
   the default list because excluding it makes the feature pointless, and the
   honest mitigation is the sandbox the worker already runs it in **plus** gate 3,
   not a claim that `python` is safe.
3. **Human-in-the-loop for side-effectful kinds.** Any kind not on the allowlist
   — `postgres`, `provider`, `shell`, `container`, `transfer`, `playbook` —
   requires an explicit approval event before admission. The gate reuses the
   existing callback/hook pattern (`agents/rules/execution-model.md`) so no
   worker slot is held while a human decides.
4. **Bounded generate→execute loop.** Three independent bounds, all recorded in
   the fold's `Budget`: max admitted steps per execution
   (`NOETL_SLM_MAX_GENERATED_STEPS`, default **8**), max generation depth
   (`NOETL_SLM_MAX_DEPTH`, default **2**), max turns
   (`NOETL_SLM_MAX_TURNS`, default **16**). Exhaustion is a **terminal, recorded**
   outcome (`slm.budget.exhausted`), not a silent stop.
   ⭐ Depth ≥ 1 means a generated step can itself generate. Default **2** is
   deliberately small; unbounded self-expansion is the failure mode that makes
   this whole feature unshippable.
5. **No credential reach.** A generated step may not carry an `auth:` block, and
   may not reference a keychain alias absent from an explicit allowlist. This
   follows `agents/rules/no-default-connection.md` — a step with no `auth:` is
   refused by the worker, which means the *default* behaviour of a generated
   credentialed step is already refusal. Gate 5 makes that explicit rather than
   incidental.

## 11. Serving Gemma 4

**No new tool kind.** Gemma 4 is reached through `tool.kind: mcp`
(`mcp.rs:219`) exactly as `gemma3:4b` is today
(`diagnose_execution.yaml:75,287,301`) — endpoint by
`NOETL_MCP_<SERVER>_ENDPOINT`, model by a workload knob. Swapping `gemma3:4b`
for a Gemma 4 variant is a **pointer swap**, which is the property the existing
design already bought and this plan must not spend.

**Local/self-hosted by default** — cost, latency, offline, data locality:

| Tier | Variant | Where | Role |
| :-- | :-- | :-- | :-- |
| edge | `E2B` / `E4B` | Ollama on the worker node | first pass; offline-capable |
| server | `31b-it` | vLLM / GKE, in-cluster | step generation, escalation target |
| MoE | `26B-A4B` (~4B active) | in-cluster | ASSUMED alternative to 31B where memory is the binding constraint — not benchmarked here |

Fallback across sizes reuses the **confidence gate already in the tree**
(`diagnose_execution.yaml:479–493`): low confidence escalates E4B → 31B. It is
the same `when:` routing, with one addition — the escalation itself emits a turn
event, so the fold sees both attempts and the cost of escalation is measurable
rather than anecdotal.

**Registry and pinning** reuse **G3** from `docs/rfc/domain-slm-platform.md` §3
(versioned model/dataset/eval registry as a catalog resource kind) and **G5**
(lineage). ⚠ G3/G5 are **design-only** in that RFC — *"no model trained, no infra
stood up"*. So S6 either lands against a registry that does not exist yet, or
records `model_ref` from the serving endpoint directly and defers registry
integration. **Recommended: the latter** (F5, §14). Native function calling in
Gemma 4 is **UNVERIFIED (external)**; the design does not depend on it — a
JSON-in-a-fenced-block completion parsed by a `python` step is the proven path
in this tree and remains the floor.

## 12. Flag matrix

Every capability behind a flag, default OFF or shadow, additive, independently
reversible. `NOETL_EHDB_*` for substrate, `NOETL_SLM_*` for the model layer.

| Flag | Values | Default | Phase | Effect when default |
| :-- | :-- | :-- | :-- | :-- |
| `NOETL_SLM_CONTEXT_EVENTS` | `off` \| `shadow` \| `on` | `off` | S1 | no turn events emitted |
| `NOETL_SLM_CONTEXT_FOLD` | `off` \| `shadow` \| `on` | `off` | S2 | prompts assembled as today |
| `NOETL_SLM_STEPGEN` | `off` \| `propose` \| `on` | `off` | S3 | model cannot propose steps |
| `NOETL_SLM_ALLOWED_TOOL_KINDS` | csv | `python,http,noop` | S3 | allowlist; empty = refuse all |
| `NOETL_SLM_HUMAN_GATE` | `off` \| `required` | `required` | S3 | side-effectful kinds need approval |
| `NOETL_SLM_MAX_GENERATED_STEPS` | int | `8` | S3 | hard bound |
| `NOETL_SLM_MAX_DEPTH` | int | `2` | S3 | hard bound |
| `NOETL_SLM_MAX_TURNS` | int | `16` | S3 | hard bound |
| `NOETL_SLM_COMPACTION` | `off` \| `on` | `off` | S5 | no summarisation |
| `NOETL_SLM_MODEL_REF` | struct/json | unset | S6 | model recorded as today |
| `NOETL_SLM_REPLAY_MODE` | `replay` \| `rederive` | `replay` | S4 | replay never calls the model |
| `NOETL_EHDB_SLM_TIER` | `off` \| `shadow` \| `primary` | `off` | S1 | turn events to D1 as ordinary events |
| `NOETL_EHDB_READ_CONSISTENCY` | `strong` \| `bounded` \| `exact` | `strong` | S4 | **exists** in M3, reused not redefined |
| `NOETL_EHDB_MAX_STALENESS_MS` | int | `0` | S4 | **exists** in M3, reused not redefined |

⚠ The last two are **M3's flags, cited not invented**. If M3 lands with different
names, this matrix follows M3; it does not fork.

## 13. Phased plan

Seven phases. Each: flag-gated, kind before prod, additive on disk, a named
instrument that is **not** a forbidden one (§4), and a **RED→GREEN control with a
planted defect** — a phase whose check has never failed is indistinguishable
from a check that cannot fail.

| Phase | Spec | Delivers | Gating flag |
| :-- | :-- | :-- | :-- |
| **S0** | `S0-envelope-compat.md` | prove optional body fields are additive; no header change (C3) | none — identity proof |
| **S1** | `S1-context-events.md` | the six event types, emitted in shadow | `NOETL_SLM_CONTEXT_EVENTS` |
| **S2** | `S2-fold.md` | the deterministic fold; shadow-compare against today's prompt | `NOETL_SLM_CONTEXT_FOLD` |
| **S3** | `S3-stepgen-gate.md` | propose → validate → admit/reject; all five gates | `NOETL_SLM_STEPGEN` |
| **S4** | `S4-replay.md` | replay-without-calling-the-model; re-derive as a separate mode | `NOETL_SLM_REPLAY_MODE` |
| **S5** | `S5-compaction.md` | summarisation as a fold op; move the fold to D3 | `NOETL_SLM_COMPACTION` |
| **S6** | `S6-gemma4-serving.md` | Gemma 4 local serving, `model_ref`, size fallback | `NOETL_SLM_MODEL_REF` |

Ordering rationale: **S0 before everything** because a format break discovered at
S3 invalidates S1–S2. **S4 before S5** because compaction changes what a replay
reproduces, and a replay guarantee has to exist before it can be weakened.
**S6 last** because every earlier phase works with `gemma3:4b` — the model is the
least coupled part of this design, which is the point.

## 14. Open forks, with recommended defaults

| # | Fork | Options | Recommendation |
| :-- | :-- | :-- | :-- |
| **F1** | Where the fold runs | server-side over D1 / D3 projection engine / playbook Python | **server over D1 first, D3 at S5.** Never Python — a second fold implementation cannot be compared against the first |
| **F2** | Generated-step carrier | new catalog entry / inline spec in an event / ephemeral non-catalog body | **catalog entry.** It is the only one with existing versioning, ACLs and a content key. Inline specs skip the parser, which is the whole safety story |
| **F3** | Sampling for step generation | `temperature 0` / low-temp / model default | **`temperature: 0`**, stated as narrowing re-derive delta, *not* as buying determinism (§8.2) |
| **F4** | Default tool-kind allowlist | `noop` only / `python,http,noop` / all read-shaped | **`python,http,noop`**, with the honest caveat in §10 gate 2 that `python` is not read-shaped |
| **F5** | `model_ref` source | G3 registry / serving endpoint / both | **serving endpoint now**, registry when G3 exists. Depending on a design-only feature would make S6 unshippable |
| **F6** | Human gate default | `off` / `required` | **`required`.** A side-effectful generated step running unattended is the failure this program would least survive |
| **F7** | Depth default | `0` (no recursion) / `2` / unbounded | **`2`.** `0` makes the feature a one-shot and misses the actual use case; unbounded is unshippable |
| **F8** | Turn events on D1 vs a new dataset | D1 / new D11 | **D1.** A new dataset is a compiled-in change against the §0.1 invariant, for no access pattern D1 lacks |

## 15. What this design deliberately does NOT do

- It does not add a tool kind. It does not add an EHDB dataset. It does not add
  an execution primitive.
- It does not make sampled model output reproducible, and says so in §8.2.
- It does not put user documents in D6, per the §3 bound.
- It does not touch the in-flight stage-1 / `digest_mismatch` track, and forbids
  itself the two instruments that track has invalidated.
- It does not train, fine-tune or evaluate a model — that is
  `docs/rfc/domain-slm-platform.md`'s scope, and this plan consumes G3/G5 rather
  than re-specifying them.
