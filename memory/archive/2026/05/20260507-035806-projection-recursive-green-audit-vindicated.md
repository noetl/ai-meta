---
date: 2026-05-07T21:24:00Z
title: Projection-recursive GREEN — v2.37.1 ships, _meta.diagnosis_fetch telemetry visible, May 6 audit fully vindicated
tags: [noetl, projection, telemetry, audit-vindicated, parity-smoke, codex-bridge, arc-complete]
---

## Outcome

GREEN. v2.37.1 deployed; nested telemetry under `error.diagnosis`
now survives projection end-to-end. The May 6 event-projection
audit is fully operationalized — its prescription ("explicit
carve-outs + parity tests for future nested control contracts")
is now codified in both the noetl carve-out logic AND the
parity smoke's static fixtures.

## What landed

- **[noetl/noetl#421](https://github.com/noetl/noetl/pull/421)**
  → released as v2.37.1. `_extract_control_context` recursively
  preserves nested content under `error.diagnosis` with
  `max_depth` guard.
- **[noetl/docs#35](https://github.com/noetl/docs/pull/35)** —
  `vertex_ai_triage_backend.md` + `triage_model_selection.md`
  updated to document the now-visible `_meta.diagnosis_fetch`
  telemetry surface.
- **Deployed to GKE** noetl-server + noetl-worker.
- **ai-meta commit** by Codex: `d2bf24e chore(sync): close
  adaptive backoff projection telemetry round`.

## Telemetry now visible end-to-end

GKE spike `621262477380026909`:

```
events[15].result.context.error.diagnosis._meta.diagnosis_fetch:
  poll_count       = 1
  elapsed_seconds  = 0.064
  deadline_seconds = 60.0
  hit_deadline     = false
```

That's a 64ms warm-path round-trip — the adaptive backoff's
initial 0.5s sleep wasn't even reached because the persisted
diagnosis was already there on the first poll. Architecturally
ideal: typical case is fast, cold case stretches up to 60s
without breaking either path.

## The audit's value, end to end

The May 6 event-projection audit at
`bridge/outbox/event_projection_audit.md` flagged:

> Worker `_extract_control_context` still scalarizes arbitrary
> nested non-error dictionaries unless they are reference
> wrappers or the special error.diagnosis shape. Current reviewed
> contracts are covered, but **future nested control contracts
> need explicit carve-outs and parity tests.**

The cycle that played out:

1. **May 6**: audit filed with this exact warning.
2. **May 7 morning**: v2.37.0 (round 4 — adaptive backoff) added
   a new nested control contract (`_meta.diagnosis_fetch`) under
   `error.diagnosis`. Didn't extend the carve-out. Didn't update
   parity smoke fixtures. Result: silent strip, RED.
3. **May 7 evening (this round)**: fix applied recursively.
   Parity smoke fixtures grew from 2/2 to 3/3 — the new shape
   (with telemetry) plus a regression fixture (with telemetry
   stripped) are both static-tested.

Every link of the audit's prescription is now codified:

- **The carve-out**: `_preserve_recursive` with `max_depth=8`
  guard handles arbitrary nested telemetry under
  `error.diagnosis` without further code changes.
- **The parity test**: `live_vs_persisted_parity_smoke.py`'s
  fixtures cover `_meta.diagnosis_fetch` shape. Future field
  additions follow the same template — add a fixture pass + a
  fixture-stripped regression case.

The next contributor adding a nested control field doesn't
need to know about the carve-out manually — the recursive
preservation handles it. They DO need to add a parity smoke
fixture, but that's a 5-minute change with a clear precedent.

## Submodule pointer (already committed by Codex)

```
d2bf24e chore(sync): close adaptive backoff projection telemetry round
```

ai-meta is clean of staged changes. Codex committed the noetl
pointer + docs pointer in one wrap-up commit.

## What this completes

The full **GKE Vertex AI arc** plus the **adaptive backoff
follow-up**:

| Round | Change | Release | Verdict |
|---|---|---|---|
| 1 | Worker key-forwarding generalisation | v2.36.0 | GREEN |
| 2 | Deprecated alias removal | (no release) | GREEN |
| 3 | Static retry budget tuning | v2.36.1 | AMBER (cold-start tail) |
| 4 | Adaptive exponential backoff | v2.37.0 | RED (telemetry stripped) |
| 5 | Recursive projection carve-out | v2.37.1 | **GREEN** |

The architectural invariants now operational in production:

- Agent envelope is the contract — wait for terminal, then read.
- Persisted events agree with live response on nested-dict
  shape (recursive preservation under `error.diagnosis`,
  scalar-only elsewhere).
- Adaptive backoff absorbs cold-start tail latency at the
  noetl side (60s deadline, 0.5s start, 1.5x growth).
- Telemetry surface (`_meta.diagnosis_fetch`) gives operators
  per-execution latency observability.
- Parity smoke is the regression detector with growing
  fixture coverage.
- Worker forwards workload keys generically; canonical-only
  naming surface; deployment-mode-aware triage backend.

## What's still open

Nothing actionable from this arc. The previously-filed sync
issues are all addressed:

- `2026-05-06-future-vertex-ai-gemini-mcp-pointer-swap.md` —
  shipped (May 6 GKE deploy).
- `2026-05-06-noetl-retry-budget-cloud-aware.md` — option (a)
  shipped in v2.36.1, option (c) shipped in v2.37.0/v2.37.1.
- `2026-05-07-noetl-adaptive-retry-backoff-tail-latency.md` —
  shipped in v2.37.0 + v2.37.1.

Future architectural work isn't scheduled and shouldn't
gate anything operational.

## Refs

- bridge/outbox/20260507-035806-projection-recursive-error-diagnosis.result.json
- noetl/noetl#421 (v2.37.1 — recursive carve-out)
- noetl/docs#35 (telemetry visibility docs)
- bridge/outbox/event_projection_audit.md (May 6 audit, fully
  operationalized this round)
- bridge/outbox/codex-spike-green-validation.md (chronological
  validation log — should be appended with v2.37.1 closing
  paragraph)
