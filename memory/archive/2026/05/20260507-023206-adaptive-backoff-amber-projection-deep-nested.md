---
date: 2026-05-07T03:00:00Z
title: Adaptive backoff RED — v2.37.0 ships, projection chokepoint strips nested telemetry under error.diagnosis (audit predicted this)
tags: [noetl, projection, adaptive-backoff, telemetry, audit-vindicated, codex-bridge]
---

## Outcome

RED. Round 4 (adaptive backoff) shipped the algorithm correctly:
v2.37.0 deployed, GKE spike 621244014842347855 returns vertex-ai
GREEN with attempts=0. **But the new `_meta.diagnosis_fetch`
telemetry field is missing from persisted execution documents** —
the worker's projection chokepoint
(`_extract_control_context` in `repos/noetl/noetl/worker/nats_worker.py`)
strips it before validators can read it.

## What landed

- **noetl/noetl#420** merged. Adaptive exponential backoff
  shipped: 0.5s initial → 1.5x growth → 4s cap → 60s deadline.
  Algorithm is correct in code; new tests pass; existing 6 ai-meta
  smokes pass.
- **Released as v2.37.0** (semantic-release picked minor for
  `feat(agent)`).
- **Deployed to GKE** noetl-server + noetl-worker. Pods healthy.
- **GKE spike 621244014842347855**: vertex-ai / gemini-2.5-flash
  / attempts=0. Functionally GREEN.
- **ai-meta**: noetl pointer bumped at `0033c4c`.

## What's broken: nested telemetry under error.diagnosis silently stripped

The new code emits `_meta.diagnosis_fetch.{poll_count,
elapsed_seconds, deadline_seconds, hit_deadline}` in the diagnose
envelope's `error.diagnosis._meta` path. Live response includes
it. **Persisted events do not.** The worker's
`_extract_control_context` carve-out preserves
`error.diagnosis`'s scalar fields but doesn't recurse to preserve
nested structures within it.

This is **the same projection chokepoint pattern as noetl#417
(May 5)**, but one level deeper. The original carve-out
preserved the diagnosis dict against being scalarized at the
parent level; this round needs the same carve-out applied at the
next nesting level.

## The audit predicted this exactly

From `bridge/outbox/event_projection_audit.md` (May 6):

> Worker `_extract_control_context` still scalarizes arbitrary
> nested non-error dictionaries unless they are reference
> wrappers or the special error.diagnosis shape. Current reviewed
> contracts are covered, but **future nested control contracts
> need explicit carve-outs and parity tests.**

The audit was filed at the close of the prior arc with this
exact warning. We added a new nested control contract
(`_meta.diagnosis_fetch` under `error.diagnosis`), didn't extend
the carve-out, didn't add it to the parity smoke's static
fixtures. The audit's "future risk" became this round's RED.

This vindicates the audit's value — projection chokepoint risk
is real and the carve-out has to be maintained alongside any
new nested control field. **The parity smoke is the regression
detector that should have caught this at PR-time.** It didn't,
because its fixtures don't yet include the nested telemetry
shape.

## Why Codex correctly stopped RED

The telemetry contract is fundamental to this round's deliverable:

- Operators monitor `_meta.diagnosis_fetch` in persisted events
  for backend-latency observability.
- Docs would document a field that exists in code but not in
  the persisted state.
- Validation log would claim a feature that's not actually
  visible to consumers.

Stopping RED keeps documentation honest. The next round's fix
makes the telemetry actually visible, then docs + validation log
catch up.

## Next round (focused, 1 noetl PR)

Extend `_extract_control_context`'s carve-out so nested control
content under `error.diagnosis` survives projection. Two
architectural options:

- **A. Targeted**: allow `error.diagnosis._meta` specifically.
  Smallest fix; future nested fields would still need their own
  carve-out.
- **B. Recursive**: when preserving `error.diagnosis`, recursively
  preserve any nested dict within it. More general; handles
  future nested telemetry without further carve-out churn.

Recommend B. Plus update the parity smoke's static fixtures so
the next nested control contract is caught at PR-time, fulfilling
the audit's "explicit carve-out + parity test" prescription.

## Submodule pointer (already committed by Codex)

```
0033c4c chore(sync): bump noetl to v2.37.0 adaptive backoff
```

ai-meta is clean of staged changes. Codex correctly didn't stage
the validation log (RED) or docs (telemetry contract not
visible).

## Refs

- bridge/outbox/20260507-023206-adaptive-retry-backoff.result.json
- noetl/noetl#420 (v2.37.0 — adaptive backoff, algorithm correct)
- bridge/outbox/event_projection_audit.md (the audit that
  predicted this exact failure mode)
- noetl/noetl#417 (the prior projection-chokepoint fix at the
  parent level, May 5)
