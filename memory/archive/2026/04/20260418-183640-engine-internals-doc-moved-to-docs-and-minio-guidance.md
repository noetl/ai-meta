# engine internals doc moved to docs and minio guidance
- Timestamp: 2026-04-18T18:36:40Z
- Author: Kadyapam
- Tags: docs,noetl,engine,storage,minio,nats,tempstore

## Summary
Moved the standalone engine internals writeup out of `repos/noetl/docs/engine-internals.md` and into the docs repo as `repos/docs/docs/reference/engine_internals.md`. Updated adjacent docs to make the storage recommendation explicit: NATS KV remains for small execution-scoped control-plane state, while payloads above about 1 MB should prefer MinIO/S3-compatible object storage instead of NATS Object Store. NATS Object Store is now documented as legacy or compatibility guidance rather than the preferred transport for 1-10 MB execution data.

## Actions
- Added `repos/docs/docs/reference/engine_internals.md`.
- Updated `repos/docs/docs/features/noetl_data_plane_architecture.md` to prefer MinIO for payload-bearing TempStore traffic above KV-friendly size.
- Updated `repos/docs/docs/reference/result_storage.md` to use `nats_kv|minio|gcs|postgres` guidance and treat NATS Object Store as compatibility storage.
- Updated `repos/docs/docs/reference/tempref_storage.md` to reflect the same backend recommendation.
- Removed the local `repos/noetl/docs/engine-internals.md` copy from the workspace. On the current branch it was not tracked by git, so this was effectively a content relocation rather than a tracked delete in `repos/noetl`.

## Repos
- `repos/docs`
- `ai-meta`

## Related
- `repos/docs/docs/features/noetl_data_plane_architecture.md`
- `repos/docs/docs/reference/result_storage.md`
- `repos/docs/docs/reference/tempref_storage.md`
- `repos/docs/docs/reference/engine_internals.md`
