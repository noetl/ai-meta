---
title: SLM execution context on EHDB — design + 7 phase specs (design only, unmerged)
date: 2026-09-19
tags: [ehdb, slm, gemma4, context, ai-driven-steps, design-only, specs]
---

# SLM execution context on EHDB — plan + specs

**Branch `design/slm-ehdb-context`, cut from `origin/main` @ `7c2fad0b`. Design
only — nothing built, nothing merged, no prod change.**

## Where it is

- Design doc:
  `loops/active/2026-09-11-ehdb-resilient-core-phases/handover/SLM-EHDB-CONTEXT-PLAN.md`
- Umbrella + 7 phase specs: `specs/active/2026-09-19-slm-ehdb-context/`
  (`spec.md`, `S0-envelope-compat`, `S1-context-events`, `S2-fold`,
  `S3-stepgen-gate`, `S4-replay`, `S5-compaction`, `S6-gemma4-serving`)

## The finding that shaped the design

⭐ **noetl needs NO new execution primitive for AI-generated work.** Three
primitives already compose into "generate a playbook, then run it":

1. runtime-sized iterator fan-out — `loop.in` is template-rendered against live
   context, `total = items.len()` (**VERIFIED** `server/src/handlers/execute.rs:1595,1615`;
   second site `:2039`)
2. runtime-chosen child playbook — the **whole** playbook tool config is
   template-rendered before deserialisation, so `path:` is data
   (**VERIFIED** `tools/src/tools/playbook.rs:99–102`)
3. runtime catalog registration — `POST /api/catalog/register`
   (**VERIFIED** `server/src/handlers/catalog.rs:49`)

What is missing is the **context substrate, the provenance and the gate**. That
is all the plan adds.

## Other grounding worth not re-deriving

- ⚠ `tool.kind: mcp` **is** registered (`tools/src/tools/mod.rs:108`, 20 tools
  total at `:90–109`); there is still **no `agent` kind** (consistent with #252).
- The live cheap-first SLM pattern is `diagnose_execution.yaml`: `gemma3:4b` at
  `:75`, pointer-swap at `:287`, `kind: mcp` at `:301`, completion parsed in
  **python** at `:338`, ⭐ **parse failure forces `confidence = 0.0`** at `:432`,
  confidence routing at `:479–493`. Degrade-to-escalate, never degrade-to-invent.
- **No new EHDB dataset needed.** Everything maps onto the fixed §0.1 set:
  D1 event log, D3 projection, D5 object, D6 vector (future). Adding a dataset
  would fight the layered-RFC program invariant.
- ⛔ D6 is **platform SLM context only** — the RFC's *"never wire a playbook
  user-document ingest to `rag::ingest`"* bound holds (#197 tracks the guard).
- ⛔ The parity comparator and `/api/ehdb/projection-fold/diff/{id}` are
  **forbidden as proof instruments** while stage-1 `digest_mismatch` is open;
  every spec names its own instrument instead.

## The determinism position, stated because it is usually fudged

**Sampled output is not reproducible and event-sourcing does not make it so.**
Two named modes: **`replay`** (default) re-executes exactly because the recorded
completion *is* the input — **the model is not called**; **`rederive`** re-runs
with pinned inputs and may differ. Replay is audit; re-derive is drift.

## Dependencies outside this umbrella

- Bounded-staleness reads reuse **M0/M3** on branch `docs/multiregion-ehdb-plan`
  (unmerged). Per **C4** the tier has no closed timestamp until **M0.5** — a
  `bounded` read before then is **inert**, and S4 asserts that rather than
  assuming it.
- Model registry / lineage reuse **G3/G5** of `docs/rfc/domain-slm-platform.md`,
  which are **design-only**. S6 therefore records `model_ref` from the serving
  endpoint and defers registry integration (fork F5).

## Open forks

F1–F8 in the plan §14, each with a recommended default. **F2 (generated-step
carrier) and F4 (tool-kind allowlist) must be settled before S3 implements.**
