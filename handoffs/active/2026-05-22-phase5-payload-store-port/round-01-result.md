---
thread: 2026-05-22-phase5-payload-store-port
round: 1
from: claude
to: claude
created: 2026-05-22T21:43:59Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase 5 round 1 result — payload-store port + filesystem reference adapter

Phases A–D executed in this session. Phase E is N/A (filesystem
adapter exercised via unit tests — no kind / Postgres / NATS
required). Phase F **open as PR #588**, merge gated on
`merge phase 5`.

## Phase A — design + drift check

- Re-read the two existing port files
  (`noetl/core/event_store/ports.py`,
  `noetl/core/projection_store/ports.py`) on `origin/main` —
  both match the prompt's template description. No drift.
- Decided `PayloadReference` field set per the prompt's
  recommendation: `sha256` / `byte_length` / `content_type` /
  `uri` (optional) / `metadata`. Frozen dataclass, mirrors the
  shape of `EventRecord` and `ProjectionRecord`.
- `store(...) -> PayloadReference` returned directly, no wrapping
  envelope.
- Sharding: 2 levels × 2 chars (`<sha[0:2]>/<sha[2:4]>/<sha>`).
  Constructor validates `shard_depth * shard_width <= 32` so the
  caller can't request more sharding than SHA-256 hex provides.
- Atomic writes via `tempfile.NamedTemporaryFile(delete=False,
  dir=parent) + fsync + os.replace` per the prompt. Temp file
  prefix `.tmp-`, suffix `.blob` so any leftovers from a crash
  are easy to spot.

## Phase B — implementation

Branch: `kadyapam/phase5-payload-store-port` in `repos/noetl`.
Commit: `140db9da feat(payload-store): add port + filesystem reference adapter` (+519/-0).

Files created:

- `noetl/core/payload_store/__init__.py` — re-exports
  `PayloadStore`, `PayloadReference`, `PayloadNotFound`,
  `content_hash`, `FilesystemPayloadStore`.

- `noetl/core/payload_store/ports.py` (~100 lines):
  - `PayloadNotFound(KeyError)` — raised on fetch of missing
    payload.
  - `content_hash(payload)` — canonical lowercase hex SHA-256
    helper. Type-guard on bytes input.
  - `PayloadReference` frozen dataclass.
  - `PayloadStore` async Protocol — 4 methods with full
    docstrings on contract.

- `noetl/core/payload_store/filesystem.py` (~180 lines):
  - `FilesystemPayloadStore` async adapter.
  - Constructor enforces sane sharding bounds.
  - `_path_for(sha)` builds the sharded blob path.
  - `_sidecar_for(blob)` builds the metadata sidecar path.
  - `store(payload, ...)` async wrapper around `_write_atomic`.
  - `_write_atomic(...)` synchronous: parent mkdir, temp-file
    write, fsync, replace, sidecar JSON. Skips blob rewrite on
    dedup hit; sidecar always rewritten when metadata supplied.
    Cleans up temp file on exception.
  - `fetch(ref)` → `await asyncio.to_thread(Path.read_bytes)`;
    raises `PayloadNotFound` on `FileNotFoundError`.
  - `exists(ref)`, `delete(ref)` similarly async-via-thread.
  - `delete` returns `False` for missing payloads (never raises).

## Phase C — tests

14 tests in `tests/core/payload_store/test_filesystem.py`:

- `test_store_and_fetch_round_trip`
- `test_content_addressing_is_deterministic`
- `test_store_skips_write_when_blob_exists` (verifies mtime
  unchanged on second store)
- `test_atomic_write_temp_file_cleanup` (no `.tmp-*` leftovers)
- `test_fetch_missing_raises_payload_not_found`
- `test_exists_reflects_state`
- `test_delete_returns_false_when_missing`
- `test_metadata_sidecar_round_trip`
- `test_content_type_default`
- `test_delete_also_removes_sidecar`
- `test_sharded_layout_uses_sha_prefix`
- `test_constructor_rejects_invalid_shard_config`
- `test_content_hash_rejects_non_bytes`
- `test_content_hash_is_stable`

Test runs:

```
pytest tests/core/payload_store/ -q
→ 14 passed in 0.48s

pytest tests/core/payload_store/
       tests/core/test_projector_metrics.py
       tests/core/test_replay_state_projector.py
       tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
→ 66 passed (Phases 1, 3, 5, 6 all green)
```

## Phase D — wiki update

Wiki: `repos/noetl-wiki/` commit `acd5c68 wiki: add Payload Store page`. Pushed to `origin master`.

Files in the wiki commit:

- **New** `noetl/core/payload_store.md` (~245 lines) following
  the structure of `event_store.md` / `projection_store.md`:
  - Status (port + reference adapter, where it sits)
  - Why a port given Storage exists (deliberately minimal
    Protocol; coexists with TempStore)
  - Interface contract (Protocol signature)
  - `PayloadReference` field table
  - `FilesystemPayloadStore` behavior: sharded layout, atomic
    write, dedup, sidecar, delete
  - Usage example
  - Where this fits (3-port diagram)
  - Configuration table (shard_depth / shard_width / default_content_type)
  - Operations (verify-without-fetch, missing sidecar, migration
    to S3)
  - Error taxonomy
  - Related links

- **Updated** `Home.md` — new row under Core between
  Projection Store and Storage.

- **Updated** `_Sidebar.md` — same insertion.

## Phase E — verify locally

**N/A.** The filesystem reference adapter is fully exercised by
unit tests (no Postgres / NATS / cloud dependencies). Local kind
verification will become useful in the next round when cloud
adapters land and need real S3/GCS/Azure auth + endpoints.

## Phase F — open PR and merge

**PR open, merge gated on wait phrase `merge phase 5`.**

- PR: [noetl#588 — feat(payload-store): add port + filesystem reference adapter](https://github.com/noetl/noetl/pull/588)
- Branch: `kadyapam/phase5-payload-store-port` pushed to origin.
- PR body cross-references this handoff + the wiki commit.
- After merge, coordinating commits:
  - `chore(sync): bump noetl to <merge sha>`
  - `chore(sync): bump noetl-wiki to acd5c68`

## Issues observed

- `event_store/ports.py` imports `Optional` from typing, but my
  `payload_store/ports.py` ended up not needing it as a top-level
  import — the `Optional` is only used inside Protocol method
  signatures. Kept the import for parallelism with the other two
  ports.
- The sidecar metadata write semantics deserve a follow-up: today
  the sidecar is rewritten on **every** non-empty-metadata
  `store()` call, even when the blob already exists. That's the
  intended behavior (callers want fresh metadata reflected) but
  means a write contention path under high concurrency. Acceptable
  for the reference adapter; production cloud adapters can
  optimize differently.

## Manual escalation needed

- **Wait phrase**: human says `merge phase 5` to unlock Phase F's
  merge.
- After merge:
  ```bash
  cd repos/noetl && git checkout main && git pull origin main
  cd ../.. && git add repos/noetl repos/noetl-wiki
  git commit -m "chore(sync): bump noetl + noetl-wiki for Phase 5 round 1 payload-store port"
  git push origin main
  ```
- Plan future Phase 5 rounds:
  - **Round 2**: S3 adapter (`S3PayloadStore`) + compliance test
    suite that runs against both filesystem and S3 (with
    moto / minio).
  - **Round 3**: GCS adapter (`GCSPayloadStore`) + Azure Blob
    adapter (`AzureBlobPayloadStore`).
  - **Round 4**: SeaweedFS adapter + (optionally)
    `EventRecord.payload_ref` typed binding.
