---
spec: 2026-09-19-slm-ehdb-context-S1
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S1 — The six SLM context event types, in shadow

Phase of [`spec.md`](spec.md). **Planning only.** Depends on **S0**.

## Scope

Emit six additive event types on **D1** around an existing model call, scoped by
`execution_id`. Shadow only: they are written and never read by anything that
makes a decision.

**In scope:** the event types, their emission points, their payload shapes.
**Out of scope:** the fold (S2), step generation (S3), any behaviour change.

## Flags

| Flag | Values | Default |
| :-- | :-- | :-- |
| `NOETL_SLM_CONTEXT_EVENTS` | `off` \| `shadow` \| `on` | `off` |
| `NOETL_EHDB_SLM_TIER` | `off` \| `shadow` \| `primary` | `off` |

`shadow` = emit, never read. `on` is not reachable until S2 has a reader.

## Event types

All fields in the record **body**, `Option<T>` + `skip_serializing_if` (C3).

| Event | Emitted at | Key payload |
| :-- | :-- | :-- |
| `slm.turn.prompted` | before the `kind: mcp` call | `model_ref`, folded prompt or `ResultRef`, `prompt_digest`, sampling params, `source_event_ids[]` |
| `slm.turn.completed` | on parsed completion | completion or `ResultRef`, `completion_digest`, tokens, latency, `finish_reason` |
| `slm.turn.degraded` | parse fail / timeout / refusal | reason, fallback taken |
| `slm.step.proposed` | model emits a candidate spec | spec, `content_digest`, producing turn id |
| `slm.step.admitted` | spec passed the S3 gate | validator version, gate taken |
| `slm.step.rejected` | spec failed | the failing rule |

⭐ The last two are emitted by S3 but **declared here** so the envelope,
migration and reader-compat story is settled once.

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `repos/tools/src/tools/mcp.rs:219` | **VERIFIED** — the `Tool` impl for `kind: mcp` | emit prompted/completed/degraded around the call, flag-gated |
| `repos/ops/automation/agents/troubleshoot/diagnose_execution.yaml:301` | **VERIFIED** — the live `kind: mcp` call site | the first workload to carry the events |
| `:338–342`, `:431–432` | **VERIFIED** — completion parsed in `python`; parse failure forces `confidence = 0.0` | `degraded` is emitted on exactly that path |
| `repos/server/src/handlers/event_write.rs` | **VERIFIED** it is the write chokepoint | new event types flow through it unchanged |

## Size floor

A folded prompt can be large. Over a floor (`ASSUMED` 64 KiB; S1 measures a real
distribution before fixing it) the payload is a **`ResultRef`** into D5 rather
than inline, following the existing reference-first model. Under it, inline.
⚠ The floor must be measured, not guessed — the layered RFC's permanent-log-lean
work exists because payloads accumulated where they were not expected to.

## Acceptance criteria

- **A1** — flag `off`: the event stream for an existing execution is
  **byte-identical** to before. This is the AC1 of the umbrella and S1 is where
  it is first at risk.
- **A2** — flag `shadow`: the six types appear, well-formed, with correct
  `execution_id` scoping, and **nothing reads them**.
- **A3** — a `degraded` event is emitted on a real parse failure, proven by
  feeding the parser a malformed completion.
- **A4** — over-floor payloads land as `ResultRef`; under-floor inline. Both
  round-trip.

## Instrument

Event-type counters by name (`slm_turn_prompted_total`, …), **pinned at 0** so
absence and zero are distinguishable — per the absent-is-not-zero rule, a
labelled metric is absent until it fires and a scrape cannot tell that from a
build that lacks it.

## RED→GREEN control

Plant a defect that makes `degraded` unreachable: force the parse-failure branch
to emit `completed` instead. **Expected RED:** A3 fails, and
`slm_turn_degraded_total` stays 0 while the malformed input is fed — which is
exactly the signature of a mechanism that exists and cannot fire.

## Rollback

Flag to `off`. Events already written are additive and harmless — they are read
by nothing until S2.

## Exit criteria

A1–A4 green on kind, the RED control demonstrated, the size floor replaced by a
measured value, and `slm.step.*` declared but not yet emitted.
