# v2 spec Phase 5 round 4 — Azure Blob payload-store adapter + SeaweedFS docs landed
- Timestamp: 2026-05-22T23:17:35Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,payload-store,azure-blob,azure-storage-blob,seaweedfs,unittest-mock,phase5,release

## Summary

Phase 5 round 4 complete. NoETL gains an Azure Blob Storage adapter
mirroring the Protocol contract proven by S3 and GCS. SeaweedFS
ships as a doc-only path through `S3PayloadStore` with
`endpoint_url`. The three-port shape now has the full cloud-adapter
matrix: filesystem (reference) + S3 + GCS + Azure + SeaweedFS-via-S3.

The remaining Phase 5 work is the `EventRecord.payload_ref` typed
binding (round 5), which touches the event-store envelope and
multiple call sites.

PR #591 merged. **124 tests** green in the focused regression
sweep (72 payload-store + 52 across Phase 1 / 3 / 6 regression
guards).

## What landed

- `noetl/core/payload_store/azure.py` — `AzureBlobPayloadStore`
  async adapter:
  - Sync `azure-storage-blob` 12.29.0 + `asyncio.to_thread`
    bridging (same canonical pattern as `S3PayloadStore` and
    `GCSPayloadStore`).
  - Constructor requires **one of** `client` /
    `connection_string` / `account_url` and raises `ValueError`
    otherwise. Builds `BlobServiceClient` via
    `from_connection_string` or `account_url + credential`;
    caches `container_client` for per-call reuse.
  - Key layout `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>` matches
    every other adapter.
  - URI shape `azure://<account>/<container>/<key>` when the
    account name is derivable from `BlobServiceClient`, else
    `azure://<container>/<key>`. Scheme fixed.
  - Dedup via `BlobClient.exists()` before `upload_blob`.
  - Content type via `ContentSettings(content_type=...)` on the
    `upload_blob` call; metadata via the `metadata=` kwarg.
  - Metadata validation enforces a **C#-identifier key rule**
    (Azure's documented constraint:
    `[A-Za-z_][A-Za-z0-9_]*`) plus ASCII values; raises
    `ValueError` with distinct messages per constraint.
  - Protocol-compliant delete (`True` if removed, `False` if
    absent) via `exists` + `delete_blob` (since `delete_blob`
    raises `ResourceNotFoundError` on missing keys).

- `tests/core/payload_store/test_azure.py` — 21 Azure-specific
  tests via `unittest.mock.MagicMock` stubbing the
  `BlobServiceClient → ContainerClient → BlobClient` chain.
  Cover constructor injection / auth-source enforcement, upload
  call shape with `ContentSettings`, dedup, exists pass-through,
  delete True/False semantics, key layout / prefix
  normalization, `azure://` URI scheme (including fallback),
  metadata validation (both ASCII and C#-identifier rules),
  `ResourceNotFoundError → PayloadNotFound` translation, and
  missing-container propagation.

- `noetl/core/payload_store/__init__.py` — re-export
  `AzureBlobPayloadStore`.

- `pyproject.toml` — added `azure-storage-blob>=12.20.0` to
  runtime deps alongside `azure-identity` /
  `azure-keyvault-secrets`.

- `uv.lock` — regenerated; pulls `azure-storage-blob 12.29.0`
  plus an `azure-core 1.35 → 1.41` bump.

- Wiki: `noetl/core/payload_store` page extended with full
  `## AzureBlobPayloadStore` and `## SeaweedFS` sections plus
  status / "Where this fits" diagram / compliance-suite update.

## SeaweedFS — doc-only path

SeaweedFS exposes an S3-compatible API on its filer / S3
gateway (default port `8333`). NoETL covers it via the existing
`S3PayloadStore` with `endpoint_url="http://seaweedfs:8333"`
plus a non-empty access/secret pair (matched against the
gateway's `-s3.config`). No dedicated adapter is needed unless
the SeaweedFS-native HTTP API exposes something the S3 mode
can't (e.g. per-file replication-factor controls).

## Why no compliance-fixture extension this round

Same situation as GCS in round 3: Azurite (the official Azure
storage emulator) is a process-based binary, not a Python
decorator. Both GCS and Azure can join the parametrized
compliance run once a process-emulator harness is built —
deferred to a dedicated test-infra round.

## Pointers

- noetl: `217203c5 → ce25607d` (PR #591 merge `ce25607d`)
- noetl-wiki: `f064e57 → e201549`
- ai-meta: `fbc5f39` (pointer bump + handoff archive) + this entry
- Handoff archive:
  `handoffs/archive/2026-05-22-phase5-payload-store-azure/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Apache Arrow IPC Tier 1.5 | done |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter event/projection/payload | rounds 1–4 done; payload_ref typed binding remains for round 5 |
| 6 — stage planner for fanout/reduce | done |

## Notes for next round

- **Phase 5 round 5** — `EventRecord.payload_ref` typed binding.
  Switch `noetl/core/event_store/ports.py`'s
  `payload_ref: Optional[dict[str, Any]]` to a
  `PayloadReference`-shaped record. Touches:
  - `noetl/core/event_store/postgres.py` insert path (the
    `payload_ref` json column population).
  - `noetl/server/api/frames/endpoint.py` (currently extracts
    `(result or {}).get("reference")` and stores it loose).
  - `noetl/server/api/replay/service.py` `_payload_ref` helper
    plus `payload_refs` list builder.
  - Any DSL engine executor sites that currently write
    `"payload_ref": None` literals.
  Decision to make: keep the field as a Pydantic-validated dict
  (no custom column type in the postgres schema yet) but enforce
  the shape at the envelope-construction boundary. Future round
  could add a column-level migration if the discoverability win
  is worth the schema-migration cost.

- **Compliance-fixture extension for GCS + Azure** — once the
  process-emulator harness is built (Azurite + fake-gcs-server
  most naturally co-installed in a test-infra fixture), both
  cloud legs join the parametrized compliance suite. Same
  shared harness covers both backends.

- **Phase 4** — three independent sub-areas (URN extension,
  KEDA scaler, NATS supercluster), each its own round. Largest
  pending piece on the v2 spec.

## Lessons / side observations

- The sync-SDK + `asyncio.to_thread` pattern proven across S3,
  GCS, and Azure adapters is now the load-bearing canonical
  shape for NoETL cloud adapters. The round-2 aioboto3/moto
  trap did not recur because each handoff prompt has explicitly
  locked the pattern in from Phase A.
- Azure's metadata-key constraint (must be a valid C#
  identifier) is stricter than S3 or GCS. The per-adapter
  `_validate_metadata` decision pays off here — the rule is
  genuinely backend-specific, not just stylistic divergence.
- `uv lock` pulled an `azure-core 1.35 → 1.41` bump because
  `azure-storage-blob` required a newer floor than the existing
  `azure-identity` / `azure-keyvault-secrets` indirect pin. No
  test failures; documented for future reference if downstream
  azure-* incompatibilities ever surface.
- The cloud-adapter rollout is now complete in 3 rounds
  (S3 → GCS → Azure) spanning a single afternoon. The handoff
  convention's tight per-round scoping (one adapter per round,
  no payload_ref creep) was key to keeping each PR small and
  reviewable.
