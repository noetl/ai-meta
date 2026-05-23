# v2 spec Phase 5 round 3 — GCS payload-store adapter landed
- Timestamp: 2026-05-22T22:38:19Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,payload-store,gcs,google-cloud-storage,unittest-mock,phase5,release

## Summary

Phase 5 round 3 complete. NoETL gains a Google Cloud Storage adapter
that mirrors the Protocol contract proven by the filesystem reference
and the S3 cloud adapter. The three-port shape now has filesystem
+ S3 + GCS adapters; Azure Blob, SeaweedFS-native, and the
`EventRecord.payload_ref` typed binding remain for round 4.

NoETL released **v2.95.0**. PR #590 merged. **103 tests** green in the
focused regression sweep (51 payload-store + 52 across Phase 1 / 3 / 6
regression guards).

## What landed

- `noetl/core/payload_store/gcs.py` — `GCSPayloadStore` async adapter:
  - Sync `google-cloud-storage` + `asyncio.to_thread` bridging (same
    canonical pattern as `S3PayloadStore`; the SDK has no native
    async client).
  - Key layout `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>` matches the
    filesystem + S3 adapters.
  - Metadata via GCS custom blob metadata (`Blob.metadata = ...`
    before `upload_from_string`). ASCII boundary check matches
    `S3PayloadStore` for cross-backend uniformity.
  - Dedup via `Blob.exists()` before `upload_from_string`.
  - Protocol-compliant delete (`True` if removed, `False` if absent)
    via `Blob.exists()` + `Blob.delete()` — `Blob.delete()` raises
    `NotFound` rather than returning a boolean.
  - Constructor accepts pre-built `storage.Client`, or builds one
    from `project` + `credentials`.

- `tests/core/payload_store/test_gcs.py` — 15 GCS-specific tests via
  `unittest.mock.MagicMock` stubbing the
  `Client → Bucket → Blob` chain. Cover constructor injection,
  upload call shape, dedup, `NotFound → PayloadNotFound`,
  exists pass-through, delete True/False semantics, key layout,
  prefix normalization, `gs://` URI scheme, ASCII metadata check,
  missing-bucket propagation.

- `noetl/core/payload_store/__init__.py` — re-exports `GCSPayloadStore`.

- Wiki: `noetl/core/payload_store` page extended with a full
  `## GCSPayloadStore` section + status / "Where this fits" diagram /
  compliance-suite update.

## Why no compliance-fixture extension this round

`moto` provides an in-process S3 mock cleanly decorated as
`@mock_aws`. There is **no equivalent in-process GCS library**
today — `fake-gcs-server` is a process-based emulator (Docker /
standalone binary) and `gcp-storage-emulator` is a Python wrapper
around that emulator binary, not a decorator-based mock.

Options considered and deferred:
- `gcp-storage-emulator` — viable but adds CI infra (port
  allocation, async startup, Docker on the host). Not worth the
  friction for round 3.
- Mock the entire `google.cloud.storage.Client` surface inside the
  compliance fixture — the resulting parametrized run mostly
  exercises the mock, not the adapter. Skip.
- Real GCS — too much friction for unit tests.

GCS gets dedicated unit tests with `unittest.mock` this round.
Round 4 revisits compliance-fixture extension if Azurite (the
Azure storage emulator) ends up co-installable on the same fixture
harness as a GCS emulator — the same infra would cover both.

## Pointers

- noetl: `e4e13945 → 217203c5` (v2.94.0 → v2.95.0, including
  PR #590 merge `1fa3108a`)
- noetl-wiki: `3638f8e → f064e57`
- ai-meta: `1563d25` (pointer bump + handoff archive) + this entry
- Handoff archive: `handoffs/archive/2026-05-22-phase5-payload-store-gcs/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | done |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter event/projection/payload | rounds 1 + 2 + 3 done; Azure Blob / SeaweedFS / payload_ref binding remain |
| 6 — stage planner for fanout/reduce | done |

## Notes for next round

- **Phase 5 round 4** — Azure Blob + SeaweedFS-native + the
  deferred `EventRecord.payload_ref` typed binding:
  - Azure Blob adapter via `azure-storage-blob` (sync SDK) +
    `asyncio.to_thread`. New runtime dep. Same canonical pattern.
    Azurite (the local Azure storage emulator) is process-based
    like fake-gcs-server, so the compliance-fixture extension
    decision repeats here — likely keep `unittest.mock` tests for
    round 4 and circle back to fixture-extension in a dedicated
    test-infra round.
  - SeaweedFS: two paths. S3-mode (re-use `S3PayloadStore` with
    `endpoint_url`) is essentially free. SeaweedFS-native HTTP
    adapter only worth it if the S3-mode fallback falls short of
    something needed.
  - `EventRecord.payload_ref` typed binding — switch the event-store
    envelope's `payload_ref` field from an opaque string to a
    `PayloadReference` shape, and wire the storage tier's
    spill-to-payload-store path through it.

- **Phase 4** remains the largest pending piece. Three independent
  subareas (URN extension, KEDA scaler, NATS supercluster), each
  its own round.

## Lessons / side observations

- The sync-SDK + `asyncio.to_thread` pattern is now confirmed
  canonical for cloud-storage adapters in NoETL. S3 (round 2)
  and GCS (round 3) ship the same shape; Azure Blob will too.
  Round 4 should not revisit the async-SDK temptation.
- The handoff prompt's test sketch suggested calling `blob.patch()`
  after `blob.metadata = ...`. The GCS SDK actually ships custom
  metadata in the same request as `upload_from_string` for new
  blobs, so no separate `patch()` call is needed. Surfacing this
  as a small process note: when a prompt enumerates SDK calls,
  the executor should verify against the SDK rather than
  encoding the prompt's call list verbatim into test assertions.
- `google-cloud-storage` 3.2.0 was already a runtime dep
  (via the existing `noetl/tools/gcs/executor.py`), so this round
  added zero pyproject.toml changes. CI install of the runtime
  deps is sufficient; no dev-extra change needed.
