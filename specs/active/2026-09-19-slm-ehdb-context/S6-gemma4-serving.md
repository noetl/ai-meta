---
spec: 2026-09-19-slm-ehdb-context-S6
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S6 — Gemma 4 served locally, pinned, with size fallback

Phase of [`spec.md`](spec.md). **Planning only.** Depends on **S1** (for
`model_ref` to have somewhere to live). Independent of S2–S5.

## Scope

Serve Gemma 4 locally, record what actually answered, and fall back across sizes
using the confidence gate already in the tree.

**In scope:** `model_ref`, the serving targets, the fallback wiring.
**Out of scope:** training, fine-tuning, eval, packaging — that is
`docs/rfc/domain-slm-platform.md`, whose G1–G6 this phase **consumes**.

## Flags

| Flag | Values | Default |
| :-- | :-- | :-- |
| `NOETL_SLM_MODEL_REF` | struct/json | unset |

Plus the existing, unchanged workload knobs: `triage_mcp_server`, `triage_model`
(**VERIFIED** `diagnose_execution.yaml:75,287`) and the MCP endpoint env
(`NOETL_MCP_<SERVER>_ENDPOINT`, **VERIFIED** `mcp.rs` module doc).

## No new tool kind

⭐ **Gemma 4 is a pointer swap, not a code change.** It is reached through
`tool.kind: mcp` (**VERIFIED** `repos/tools/src/tools/mcp.rs:219`) exactly as
`gemma3:4b` is today (**VERIFIED** `diagnose_execution.yaml:301`). Swapping the
model is editing a workload knob. That property was bought by the existing
design (noetl#418 / ops#42 pointer-swap rationale) and this phase must not spend
it.

## Serving targets

Local / self-hosted by default — cost, latency, offline, data locality.

| Tier | Variant | Where | Role |
| :-- | :-- | :-- | :-- |
| edge | `E2B` / `E4B` | Ollama on the worker node | first pass; offline-capable |
| server | `31b-it` | vLLM / GKE in-cluster | step generation; escalation target |
| MoE | `26B-A4B` (~4B active) | in-cluster | **ASSUMED** alternative where memory binds; not benchmarked here |

**UNVERIFIED (external)** — every Gemma 4 product fact above (sizes, variants,
Ollama id, native function calling, 140 languages, thinking variants) was
supplied to this session and not checked against a running model. Nothing in
S1–S5 depends on any of it beyond *"it serves an OpenAI-shaped chat API
locally"*.

## `model_ref` — pin a value, not a name

```
ModelRef { family, variant, digest, server, api }
```

`gemma-4-31b-it` alone is a moving target the moment a registry re-tags.

⚠ **S6's first task is to check whether the local server exposes a content
digest.** If it does not, the honest record is `digest: null` plus the resolved
local blob hash — and this spec says so rather than storing a name and calling it
a pin. Recording a name in a field called `digest` would be exactly the
representation drift this program keeps finding.

**Registry (fork F5, recommended: defer).** G3/G5 in
`docs/rfc/domain-slm-platform.md` §3 are **design-only** — that RFC states *"no
model trained, no infra stood up"*. So S6 records `model_ref` **from the serving
endpoint** and integrates a registry when G3 exists. Depending on a design-only
feature would make S6 unshippable.

## Fallback

Reuses the confidence gate **already in the tree**
(**VERIFIED** `diagnose_execution.yaml:479–493`): low confidence escalates
E4B → 31B via `next:` + `when:`. One addition — the escalation emits its own turn
events (S1), so the fold sees both attempts and **the cost of escalation becomes
measurable instead of anecdotal**.

Function calling: the design does **not** depend on it. A JSON-in-a-fenced-block
completion parsed by a `python` step is the proven path here
(**VERIFIED** `:338–342`) and remains the floor; native function calling is an
optimisation to measure, not an assumption to build on.

## Acceptance criteria

- **A1** — swapping `gemma3:4b` → a Gemma 4 variant is a **config-only** change:
  zero lines of code diff.
- **A2** — every turn event carries a `model_ref` whose `variant` matches the
  model that actually answered — verified against the serving endpoint's own
  reported model, not against the requested one.
- **A3** — low confidence escalates E4B → 31B, and **both** attempts appear as
  turn events.
- **A4** — with the endpoint unreachable, the step emits `slm.turn.degraded` and
  the existing degrade path runs; it does not hang and does not invent.

## Instrument

`slm_model_calls_total{variant}` and `slm_escalations_total{from,to}`, pinned at
0 for each known variant. Latency histogram per variant, so the edge-vs-server
trade-off is a measurement rather than a claim.

## RED→GREEN control

Plant a `model_ref` that reports the **requested** model rather than the served
one: point the knob at `31b-it` while the endpoint actually serves `E4B`.
**Expected RED:** A2 fails. Without this control, `model_ref` records intent and
is indistinguishable from a real pin — which is the whole failure this field
exists to prevent.

Second plant for A4: point the endpoint at a closed port and confirm `degraded`
fires rather than a hang.

## Rollback

Unset `NOETL_SLM_MODEL_REF` and revert the workload knob to `gemma3:4b`. Because
A1 requires config-only, rollback is config-only too.

## Exit criteria

A1–A4 green on kind, both RED controls demonstrated, the digest question answered
in this spec (exposed / not exposed, with what recorded instead), and every
UNVERIFIED Gemma 4 fact above either confirmed against the running endpoint or
left explicitly marked.
