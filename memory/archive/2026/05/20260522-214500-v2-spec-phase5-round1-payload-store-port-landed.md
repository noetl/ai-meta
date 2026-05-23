# v2 spec Phase 5 round 1 — payload-store port landed
- Timestamp: 2026-05-22T21:45:00Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,payload-store,ports,filesystem,phase5,release

## Summary

Phase 5 round 1 of the v2 distributed-runtime spec is complete. NoETL
now has three port-and-adapter store families with parallel shapes:

- `noetl.core.event_store` — `EventStore` Protocol + Postgres ref (done)
- `noetl.core.projection_store` — `ProjectionStore` Protocol + Postgres ref (done)
- `noetl.core.payload_store` — `PayloadStore` Protocol + Filesystem ref (**this round**)

PR #588 merged with 4 file changes (+519/-0), 14 new tests, 66 tests
green across the focused suite. NoETL released v2.93.0.

## What landed

- **Port** at `noetl/core/payload_store/ports.py`:
  - `PayloadStore` async Protocol with `store` / `fetch` /
    `exists` / `delete`.
  - `PayloadReference` frozen dataclass:
    `sha256` / `byte_length` / `content_type` / `uri` / `metadata`.
  - `PayloadNotFound` (KeyError subclass) on fetch of a missing
    payload.
  - `content_hash(payload) -> str` module helper for the canonical
    lowercase hex SHA-256.

- **Reference adapter** at `noetl/core/payload_store/filesystem.py`:
  - `FilesystemPayloadStore` implementing the Protocol.
  - Content-addressed sharded layout:
    `<root>/<sha[0:2]>/<sha[2:4]>/<sha>` by default (configurable).
  - Atomic writes via `tempfile.NamedTemporaryFile(dir=parent) +
    fsync + os.replace`. Mid-write crashes leave no visible
    partial blob.
  - Content-addressing dedup — second `store(payload)` for the
    same bytes is a no-op for the blob file.
  - Optional `.meta.json` sidecar with `content_type` /
    `metadata` / `byte_length` / `created_at`.
  - `delete(ref)` returns `False` for missing payloads (never
    raises), mirroring `os.unlink(missing_ok=True)`.

- **Wiki page** at `noetl/core/payload_store` (`acd5c68`) mirroring
  the structure of `event_store` / `projection_store`.

## Out of scope for this round (future Phase 5 rounds)

- **No migration of existing callers.** `TempStore` and the
  storage tier continue to work unchanged. The port establishes
  the contract; later rounds wire callers through it where it
  makes sense.
- **No cloud adapters.** S3 / GCS / Azure Blob / SeaweedFS land
  in subsequent Phase 5 rounds (round 2 = S3, round 3 = GCS +
  Azure, round 4 = SeaweedFS / payload_ref typed binding).
- **No event-envelope integration.** `EventRecord.payload_ref`
  stays an opaque dict; binding to `PayloadReference` is a
  follow-up.

## Pointers

- noetl: `cf3ea88b -> 0ce85337` (v2.93.0, including PR #588 merge `6534e28b`)
- noetl-wiki: `a096134 -> acd5c68`
- ai-meta: `5ad26ce` (pointer bump) + `8d105c4` (handoff archive) + this entry
- Handoff archive: `handoffs/archive/2026-05-22-phase5-payload-store-port/`

## Three-port symmetry achieved

```
event_store        projection_store     payload_store          ← three ports
  │                  │                    │
  ▼                  ▼                    ▼
Postgres ref     Postgres ref      Filesystem ref               ← three reference adapters
                                  (cloud adapters land in
                                   future rounds)
```

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | done |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter event/projection/payload | round 1 done (payload-store port + filesystem); cloud adapters pending |
| 6 — stage planner for fanout/reduce | done |

Six of seven phases now meaningfully landed (Phase 5 has remaining
rounds for cloud adapters). Outstanding work:

- **Phase 5 round 2** — S3 adapter + compliance test suite that
  runs both filesystem and S3 against the same Protocol via
  moto / minio.
- **Phase 5 round 3** — GCS adapter + Azure Blob adapter.
- **Phase 5 round 4** — SeaweedFS adapter; optionally bind
  `EventRecord.payload_ref` to typed `PayloadReference`.
- **Phase 4** — Unified Resource Locator extension + KEDA scaler
  + NATS supercluster (largest scope; multi-week, 3-5 rounds).

## Side notes

- A stray empty `tests/core/payload_store/__init__.py` was created
  at the ai-meta repo root during this round due to an
  earlier-cwd mishap. Cleaned up before pushing (the actual
  `__init__.py` landed correctly in `repos/noetl/tests/core/payload_store/`).
- Reinforces the lesson encoded in `agents/rules/handoffs.md`-adjacent
  reasoning: when working across multi-submodule sessions, prefer
  `git -C <path> ...` over persistent `cd`. Was caught by `git
  status --short` before any commit landed.
