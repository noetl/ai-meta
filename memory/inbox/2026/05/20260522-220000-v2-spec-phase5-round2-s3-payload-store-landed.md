# v2 spec Phase 5 round 2 — S3 payload-store adapter landed
- Timestamp: 2026-05-22T22:00:00Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,payload-store,s3,boto3,moto,compliance,phase5,release

## Summary

Phase 5 round 2 complete. NoETL gains an S3 / S3-compatible adapter
matching the Protocol established in round 1, plus an adapter-
agnostic compliance test suite that pins down the contract for
future adapters.

NoETL released v2.94.0. PR #589 merged with 5 file changes (+523/-0).
**88 tests** green in the focused regression sweep (36 payload-store +
52 across Phase 1 / 3 / 6 regression guards).

## What landed

- `noetl/core/payload_store/s3.py` — `S3PayloadStore` async adapter:
  - Sync boto3 + `asyncio.to_thread` bridging (same pattern as
    `FilesystemPayloadStore`).
  - Key layout `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>` matches the
    filesystem reference.
  - Metadata via S3 native object headers (PutObject `Metadata`
    kwarg). ASCII validation at the boundary.
  - Dedup via HeadObject before PUT.
  - Protocol-compliant delete (True if removed, False if absent)
    via HeadObject + DeleteObject — needed because S3 DeleteObject
    is idempotent.
  - Supports MinIO / SeaweedFS / LocalStack via the `endpoint_url`
    constructor arg.

- `tests/core/payload_store/test_compliance.py` — parametrized
  fixture yielding both `FilesystemPayloadStore` and
  `S3PayloadStore` (via `moto.mock_aws()`). 7 contract tests ×
  2 adapters = 14 parametrized runs. Long-term contract gate.

- `tests/core/payload_store/test_s3.py` — 8 S3-specific tests
  (key layout, prefix normalization, dedup-skipping the PUT,
  non-ASCII metadata `ValueError`, URI scheme, missing-bucket
  `ClientError`, empty-bucket constructor rejection,
  object-metadata round-trip).

- `pyproject.toml` — `moto[s3]>=5.0` added to dev extras. No
  runtime-deps change.

- Wiki: `noetl/core/payload_store` page extended with S3 adapter
  + compliance suite sections.

## Project lesson — aioboto3 vs moto

`aiobotocore` (the async backend for `aioboto3`) doesn't work with
`moto.mock_aws` because aiobotocore's endpoint expects an awaitable
`http_response.content` while moto returns sync bytes:

```
TypeError: object bytes can't be used in 'await' expression
```

The S3 adapter was initially wired through `aioboto3` per the
handoff prompt's recommendation, but the test suite immediately
exposed the incompatibility. Resolved by switching the adapter to
sync boto3 + `asyncio.to_thread`. Same pattern as the filesystem
reference.

**Implication for future async-AWS work:** plan for either real-AWS
/ LocalStack integration testing OR sync SDK + thread bridging.
Pure `moto.mock_aws` is the easy path but only intercepts sync
boto3. If aiobotocore-native testing is required, the cleanest
path is `moto_server` (process-based mock) rather than the
decorator-based `mock_aws`.

This is the second time this kind of mock-vs-runtime mismatch has
bitten this session (the first was the pytest async-fixture mode
caught earlier in the same round). General principle: when
swapping the runtime backend, prefer the simplest test-infra
that works rather than fighting the mock-runtime compatibility
matrix.

## Pointers

- noetl: `0ce85337 -> e4e13945` (v2.94.0, including PR #589 merge `5f4baba9`)
- noetl-wiki: `acd5c68 -> 3638f8e`
- ai-meta: `c5a4d2a` (pointer bump) + `cf8d9df` (handoff archive) + this entry
- Handoff archive: `handoffs/archive/2026-05-22-phase5-payload-store-s3/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | done |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter event/projection/payload | rounds 1 + 2 done; GCS / Azure Blob / SeaweedFS remain |
| 6 — stage planner for fanout/reduce | done |

## Notes for next round

- **Phase 5 round 3** — GCS + Azure Blob adapters. Both follow the
  same sync-SDK + `asyncio.to_thread` pattern proven in round 2.
  The existing compliance suite extends by appending fixture
  branches.
  - GCS adapter uses `google-cloud-storage` (sync) — already a
    transitive dep through existing GCS tooling.
  - Azure Blob adapter uses `azure-storage-blob` (sync) — would
    be a new dep.
- **Phase 5 round 4** — SeaweedFS adapter. Two options:
  - SeaweedFS in S3 mode → use `S3PayloadStore` with
    `endpoint_url="http://seaweedfs:8333"`. No new adapter
    needed.
  - SeaweedFS native HTTP API → dedicated adapter. Worth
    considering only if the S3-mode integration falls short.
  - Plus the `EventRecord.payload_ref` typed binding work that
    was deferred from round 1.
- **Phase 4** — the largest remaining piece. Three independent
  subareas (URN extension, KEDA scaler, NATS supercluster), each
  its own round.

## Side observations

- Adding a dev dep means CI needs to install `pip install -e ".[dev]"`
  to pick up moto. Worth verifying the CI run on the next PR.
- The S3 adapter's sync-boto3 + thread-bridge pattern is now the
  canonical shape for cloud-storage adapters in NoETL. Round 3
  should explicitly follow it without revisiting the aioboto3
  rabbit hole.
