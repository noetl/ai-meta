---
date: 2026-05-05T20:59:22Z
title: v2.35.8 regression sweep → AMBER (event-projection bug fixed in v2.35.9)
tags: [noetl, regression-sweep, event-projection, persisted-events, codex-bridge, v2.35.9]
---

## Outcome

AMBER (regressions found AND fixed in-flight per task rules). Deployed
state is GREEN on `v2.35.9`. Three consecutive spike runs:

```
exec=620315386180797314 attempts=0 GREEN
exec=620315684999790603 attempts=0 GREEN
exec=620315983944614036 attempts=0 GREEN
```

## What the sweep caught

The spike's live assertion was passing, but the **persisted event
stream was lossy for nested dicts**. Specifically, the worker's
event-projection logic preserved scalar fields under
`result.context.error` (`code`, `kind`, `message`, `retryable`)
but stripped the nested `diagnosis` dict when persisting
`trigger_failure`'s terminal event.

Why the spike was still passing: `extract_envelope` runs in the
SAME execution and reads the live response via
`{{ steps.trigger_failure }}` — that path retains the full envelope.
The lossy projection only affects what's persisted to the event
stream, which is what downstream consumers (GUI event browser,
audit replay, post-hoc analytics, anything reading events instead
of the live response) actually see.

Bucket 8 caught it because it specifically inspected the persisted
`call.done` / `step.exit` event payload for `trigger_failure`, not
just the live `extract_envelope` result. Worth keeping that bucket
in the regression sweep template.

## The fix

[noetl/noetl#417](https://github.com/noetl/noetl/pull/417) →
`v2.35.9`. Worker's event-projection now preserves nested dicts
under `error.diagnosis` (and presumably similar shapes) instead of
filtering down to scalars. Deployed via `bump_image` lifecycle
across server / worker / ollama-bridge.

## Operational note: GHCR availability race

The first v2.35.9 bump began before GHCR had exposed the new image
tag, failing the `noetl-server` rollout. Recovery: idempotent
re-runs of the same `bump_image` playbook once GHCR caught up.
Worth a small follow-up: have `bump_image` probe
`HEAD https://ghcr.io/v2/noetl/noetl/manifests/<tag>` before
issuing the rollout, and fail fast with a "tag not yet available"
message rather than letting the rollout deadline expire. Adds
~1s, prevents the failed-rollout-then-recover dance.

## Verification (post-v2.35.9)

- All 4 smokes pass: carveout 8/8, gap41_wait 7/7,
  auto_troubleshoot 9/9, optional_ai 6/6.
- Cluster healthy on v2.35.9: server/worker/ollama-bridge.
- Spike stable: 3/3 GREEN, `attempts=0` each.
- MCP JSON-RPC: `tools/list` returns 1 tool, `tools/call` returns
  HTTP 200 with structured result (`isError=true` is expected
  because the diagnosed subflow is intentionally failing).
- bump_image idempotent: all components "unchanged", no
  `declare -A` shell errors.
- Auto-troubleshoot contract: all 5 keys present, source=ollama.
- Catalog re-register: `bump_image` v6, `diagnose_execution` v8,
  `spike_e2e_test` v11.
- **Bucket 8 (the regression's home)**: persisted
  `result.context.error.diagnosis` now carries the full dict
  including `category, confidence, root_cause, suggested_action,
  source, execution_id, escalated`.

## Submodule pointer (committed locally in ai-meta, awaiting push)

```
noetl  8b641b056fc3867a515b3196913c0aa2febad937   (v2.35.9 tip, +3 from v2.35.8)
```

ai-meta `main` is now 1 commit ahead of origin:

```
a2a3282 chore(sync): bump noetl pointer for v2.35.9 regression fix
```

## Follow-ups (not blocking)

1. **GHCR availability probe in `bump_image`** — probe
   `HEAD ghcr.io/v2/noetl/noetl/manifests/<tag>` before triggering
   rollout. Tiny PR, prevents the v2.35.9-style race on every
   release deploy. Lives in repos/ops.
2. **Event projection audit** — the regression was nested-dict
   stripping under `result.context.error`. Worth a one-shot audit
   to find any other persisted-event paths where nested dicts may
   be silently filtered. Likely candidates: `step.exit.result`,
   `call.done.response`, `command.completed.response`. Could
   surface as another bucket in the next sweep.
3. **Live-vs-persisted parity test** — generalise bucket 8 into a
   reusable check: for any step's response, assert that the
   live-response shape and the persisted-event shape agree on the
   set of nested dict keys. Would have caught this regression at
   PR-time rather than several releases later.

## Refs

- bridge/outbox/20260505-191122-v2358-regression-and-fix.result.json
  (full sweep iteration log, 5 iterations)
- bridge/outbox/codex-spike-green-validation.md (validation log
  appended with v2.35.9 supersession)
- noetl/noetl#417 (event-projection fix → v2.35.9)
