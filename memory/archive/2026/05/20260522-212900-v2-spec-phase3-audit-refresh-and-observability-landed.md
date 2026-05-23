# v2 spec Phase 3 audit refreshed + IPC observability landed
- Timestamp: 2026-05-22T21:29:00Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,ipc,arrow,observability,storage,projector,phase3,release,audit

## Summary

Closing the loop on Phase 3 of the v2 distributed-runtime spec.
Two related outcomes this round:

1. **Audit refresh.** The audit table being carried forward from
   round to round (originally written 2026-05-16) marked Phase 3 as
   "partial — Feather encoding + decode in projector; no
   shared-memory cache". That description was already stale before
   this round started — the cache + IpcHint + TempStore fast-path
   landed in earlier releases. The actual gap was observability.

2. **Observability shipped.** PR #587 (noetl v2.92.0) exposes
   TempStore's internal IPC Tier 1.5 counters as Prometheus metrics
   on the projector endpoint, plus a `/summary` JSON block with
   derived ratios. Operators can now see `read_hit_ratio`,
   `admit_success_ratio`, and `fallback_ratio` per pod.

## What the v2 spec Phase 3 actually means now

Implemented end-to-end:

- `ArrowIpcSharedMemoryCache` (`noetl/core/storage/ipc_cache.py`)
  with put/get/sweep/delete, 256-MiB default budget, LRU-by-lease
  eviction, configurable namespace + lease.
- `IpcHint` Pydantic model
  (`noetl/core/storage/models.py:93`) carrying `shm_name`,
  `schema_digest`, `byte_length`, `row_count`, `producer`,
  `node_id`, `lease_expires_at`, `media_type`, plus
  `is_expired()`.
- `ResultRef.ipc` / `TempRef.ipc` fields — payload references
  carry an optional IPC hint alongside the durable ref.
- Producer side: `cursor_worker.py` stages frame outputs into
  the IPC cache + durable tier.
- Consumer side: `TempStore.get_ipc_bytes` attempts the
  shared-memory read first, falls back to the durable tier on
  expired-hint / cross-node / segment-evicted. Tracks
  `admit_*` + `read_*` + `fallback_*` counters.
- Frame commit endpoint validates `output_ref.ipc` requires a
  durable companion ref (`noetl/server/api/frames/schema.py`).

This round added:

- `default_ipc_stats()` module-level helper at
  `noetl.core.storage.result_store` re-exported via
  `noetl.core.storage`.
- 7 new Prometheus counters on the projector metrics endpoint:
  `noetl_ipc_admit_attempts_total`, `_admit_success_total`,
  `_admit_failures_total`, `_read_attempts_total`,
  `_read_hits_total`, `_read_misses_total`,
  `_fallback_reads_total`.
- `summary["ipc"]` block on `/summary` JSON with the 7 raw
  counters plus 3 derived ratios (`admit_success_ratio`,
  `read_hit_ratio`, `fallback_ratio`).

## What's still open under "Phase 3" if you stretch the scope

- **Wider producer adoption.** Only `cursor_worker.py` stages
  results in IPC today. Promoting other tools (python, http) to
  stage their results in IPC is a separate adoption pass — not
  strictly required by the v2 spec wording.
- **Cross-system integration test** that round-trips an IpcHint
  through `frame.committed` → outbox JSONB → projector decode is
  worth adding when a future round needs the regression guard.

Neither is a Phase 3 blocker; treating the spec phase as **done**.

## Pointers

- noetl: `c7f3cbd5 -> cf3ea88b` (v2.92.0, including PR #587 merge `818ac81e`)
- noetl-wiki: `1fdb8c6 -> a096134`
- ai-meta: `948f038` (pointer bump) + `72b3c93` (handoff archive) + this entry
- Handoff archive: `handoffs/archive/2026-05-22-phase3-ipc-observability/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | **done (this round)** |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter payload store | partial |
| 6 — stage planner for fanout/reduce | done |

Five of seven phases now done. Remaining work splits cleanly:

- **Phase 5** — payload-store port + reference adapter + cloud
  adapters. Medium-large scope (1-2 weeks across 2-3 rounds).
- **Phase 4** — Unified Resource Locator extension + KEDA scaler
  + NATS supercluster topology. Largest scope (2-4 weeks across
  3-5 rounds).

Phase 5 is the natural next target — `event_store` and
`projection_store` ports exist with the same pattern, so payload
store is the third port in a known shape.
