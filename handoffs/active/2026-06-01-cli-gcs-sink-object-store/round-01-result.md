---
slug: 2026-06-01-cli-gcs-sink-object-store
round: 1
status: complete
tracks: noetl/ai-meta#31
pr: https://github.com/noetl/cli/pull/48
branch: kadyapam/r3-gcs-sink-object-store
date: 2026-06-01
---

## Summary

PR [noetl/cli#48](https://github.com/noetl/cli/pull/48) implements all acceptance criteria from noetl/ai-meta#31.

## What shipped

**Helper shape** (`executor/src/tools_bridge.rs:763–849`):
- `pub async fn gcs_upload(bucket, key, data)` — production entry point; builds `GoogleCloudStorageBuilder::from_env().with_bucket_name(bucket).build()` then delegates to `gcs_upload_with_store`.
- `pub async fn gcs_upload_with_store(store: Arc<dyn ObjectStore>, key, data)` — inner path shared by production and tests. Wraps the `ObjectStore::put` call in a `gcs.upload` tracing span with `key` + `bytes` fields; emits `duration_ms` debug event on completion (observability.md Principle 1).

**CLI call site** (`src/playbook_runner.rs:1113–1130`): `SinkTarget::Gcs` arm replaced with `block_in_place(|| Handle::current().block_on(gcs_upload(bucket, key, data)))`. `sink_to_gcs` method and `std::process::Command` import removed. `tempfile` dep removed from root `Cargo.toml`.

**Dep bump** (`executor/Cargo.toml`): `object_store = { version = "0.11", features = ["gcp"] }` + `bytes = "1"`.

## Test coverage

- 4 unit tests in `tools_bridge.rs` (lines 2132–2218): write + read-back, overwrite, nested key, empty payload — all via `InMemory` backend.
- 5 integration tests in `executor/tests/gcs_upload.rs`: same patterns plus CSV payload + compile-time signature check.
- Total executor tests: 125 passed, 0 failed (was 116 before).
- No new clippy warnings (7 pre-existing warnings in `playbook.rs` / `worker/source.rs` unchanged).

## Auth chain

`GoogleCloudStorageBuilder::from_env()` checks in order: `GOOGLE_SERVICE_ACCOUNT_KEY` env (CI containers), `GOOGLE_SERVICE_ACCOUNT` path, ambient ADC. On GKE pods this reaches the metadata server (same as `gcp_auth`); on dev hosts it reads `~/.config/gcloud/application_default_credentials.json`.

## Wiki

`repos/noetl-cli-wiki/executor-crate-architecture.md` updated at `noetl-cli-wiki@a7266e4`: two semantic-divergence rows (transport + credential chain), deferred-work item marked complete, R-1.1 next-phases note updated.

## Blockers

None. PR awaits review + merge. Pointer bumps for `repos/cli` and `repos/noetl-cli-wiki` in ai-meta follow after merge.
