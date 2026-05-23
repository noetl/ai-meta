# v2 spec Phase 5 complete — port/adapter event/projection/payload
- Timestamp: 2026-05-23T00:57:18Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,phase5,complete,payload-store,event-store,payload_ref,milestone

## Summary

**Phase 5 of the v2 distributed-runtime spec is complete.** Five
rounds, five merged PRs, all gated on explicit human merge phrases.
The three-port shape (event_store + projection_store + payload_store)
now has a full reference + cloud adapter matrix on the payload side,
and the event-store envelope carries a typed binding so callers can
write a `PayloadReference` directly.

NoETL reached **v2.97.0** at the end of the round.

## What landed across the five rounds

### Round 1 — port + filesystem reference (PR #586)

- `noetl/core/payload_store/ports.py` — `PayloadStore` Protocol,
  `PayloadReference` frozen dataclass, `PayloadNotFound`,
  `content_hash`.
- `noetl/core/payload_store/filesystem.py` — `FilesystemPayloadStore`
  with sharded layout `<root>/<sha[:2]>/<sha[2:4]>/<sha>`, atomic
  writes via tempfile + fsync + `os.replace`, optional `.meta.json`
  sidecar.
- Wiki page created.

### Round 2 — S3 adapter + compliance suite (PR #589)

- `noetl/core/payload_store/s3.py` — `S3PayloadStore` via sync boto3
  + `asyncio.to_thread`. (The aioboto3 path was tried first but
  doesn't work with `moto.mock_aws` — sync boto3 + threading is the
  canonical pattern from this round on.)
- `tests/core/payload_store/test_compliance.py` — parametrized
  fixture across filesystem + S3 (via `moto.mock_aws`), 7 contract
  tests × 2 adapters = 14 parametrized runs.
- `moto[s3]>=5.0` added to dev extras.

### Round 3 — GCS adapter (PR #590)

- `noetl/core/payload_store/gcs.py` — `GCSPayloadStore` via sync
  `google-cloud-storage` + `asyncio.to_thread`. Same canonical
  shape.
- `tests/core/payload_store/test_gcs.py` — 15 GCS tests via
  `unittest.mock` (no in-process emulator; `fake-gcs-server` is a
  process-based binary, not a decorator).

### Round 4 — Azure Blob adapter + SeaweedFS docs (PR #591)

- `noetl/core/payload_store/azure.py` — `AzureBlobPayloadStore` via
  sync `azure-storage-blob` + `asyncio.to_thread`. Same canonical
  shape; metadata-key constraint is stricter (must be a valid C#
  identifier).
- `tests/core/payload_store/test_azure.py` — 21 Azure tests via
  `unittest.mock`.
- `azure-storage-blob>=12.20.0` added to runtime deps.
- SeaweedFS landed as doc-only: use `S3PayloadStore` with
  `endpoint_url`.

### Round 5 — payload_ref typed binding (PR #592)

- `noetl/core/event_store/ports.py`:
  - New `PAYLOAD_REF_KIND_PAYLOAD_STORE = "payload_store"`
    discriminator constant.
  - New `payload_ref_to_dict(value)` helper —
    `None` / `PayloadReference` / `dict` → canonical dict; anything
    else raises `TypeError`.
  - `EventRecord.payload_ref` typing widened to
    `Optional[Union[PayloadReference, dict[str, Any]]]`.
  - `EventRecord.envelope()` runs `self.payload_ref` through the
    helper.
- `noetl/server/api/replay/payload_resolver.py` —
  `replay_payload_ref_locator` recognizes the discriminator and
  prefers `uri` (with `sha256` fallback).
- 24 new tests (11 binding + 13 locator).

## Wire format for payload-store-backed references

```json
{
  "kind": "payload_store",
  "sha256": "abcd…",
  "byte_length": 1234,
  "content_type": "application/json",
  "uri": "gs://bucket/aa/bb/abcd…",
  "metadata": {"origin": "frame-row-spill"}
}
```

The `kind` discriminator is the stable contract that lets future
adapters (URN-shaped references in Phase 4, etc.) coexist with
payload-store-backed references without colliding.

## Project lessons

1. **Sync SDK + `asyncio.to_thread` is the canonical cloud-adapter
   pattern in NoETL.** Proven across S3, GCS, and Azure. The
   aioboto3-vs-moto incompatibility from round 2 was the
   load-bearing lesson; every subsequent round locked the pattern
   in from the prompt's Phase A.

2. **Per-adapter `_validate_metadata` was the right call.** S3
   wants ASCII keys + values, GCS the same, Azure adds the C#-
   identifier key rule. Pulling these into a shared helper would
   have over-coupled the adapters.

3. **In-process emulator dependencies are not equal.** `moto`
   gives S3 an in-process decorator. GCS and Azure have only
   process-based emulators (`fake-gcs-server`, Azurite), which
   means the parametrized compliance suite couldn't be extended in
   round 3 / 4 without adding CI infrastructure. Decision: GCS +
   Azure get `unittest.mock` unit tests this phase; the
   process-emulator compliance fixture is a future test-infra
   round that covers both backends at once.

4. **Typed binding before consumer rewiring.** Round 5 added the
   envelope-side accept path for `PayloadReference` without
   touching the postgres schema, the resolver routing, or any
   storage-tier caller. That keeps the change small and gives
   future work a clean shape to write against.

## Pointers

- noetl: `e4e13945 → b82d58ef` over the phase (v2.93.0 → v2.97.0)
- noetl-wiki: `acd5c68 → 1549932` over the phase
- ai-meta: `c5a4d2a → c0f16c4` over the phase
- Handoff archives:
  - `handoffs/archive/2026-05-22-phase5-payload-store-port/`
  - `handoffs/archive/2026-05-22-phase5-payload-store-s3/`
  - `handoffs/archive/2026-05-22-phase5-payload-store-gcs/`
  - `handoffs/archive/2026-05-22-phase5-payload-store-azure/`
  - `handoffs/archive/2026-05-22-phase5-payload-ref-typed-binding/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | done |
| 4 — URN + KEDA + NATS supercluster | **not started** |
| 5 — port/adapter event/projection/payload | **done** |
| 6 — stage planner for fanout/reduce | done |

**Phase 4 is the only remaining piece on the v2 spec.**

## Notes for next work

### Out-of-phase follow-ups from Phase 5

- **PayloadStore-aware resolver routing.** The
  `TempStoreReplayPayloadResolver` can't fetch `gs://`/`s3://`/
  `azure://` URIs today. Needs a `PayloadStore` registry + a
  router that picks the right adapter based on the `kind`
  discriminator or URI scheme.
- **Storage tier spill-to-payload-store.** Wire the existing
  `Storage`/`TempStore` spill-on-eviction path through a
  registered `PayloadStore`. Larger change touching the storage
  tier abstractions.
- **Process-emulator compliance fixture.** Wire `gcp-storage-emulator`
  + Azurite into a shared test-infra harness so the GCS + Azure
  cloud adapters join the parametrized compliance suite. Same
  infra likely covers both.

### Phase 4 split (suggested)

- **Round 1 — URN extension.** Smallest unit; extends the existing
  resource URN scheme. Likely no kind cluster needed for tests.
- **Round 2 — KEDA scaler.** Adds the worker-pool autoscaler;
  needs a kind cluster + helm chart.
- **Round 3 — NATS supercluster.** Multi-cluster NATS topology;
  the largest piece. Needs a kind cluster + multi-cluster NATS
  configuration.

Each can land as its own handoff round.
