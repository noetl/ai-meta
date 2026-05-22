---
thread: 2026-05-22-phase5-payload-store-azure
round: 1
from: claude
to: claude
created: 2026-05-22T23:25:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Result — Phase 5 round 4: Azure Blob adapter + SeaweedFS docs — round 1

Phases A through D + PR open completed. Phase F (merge) blocked on
the prompt's wait phrase `merge phase 5 azure`.

## Phase A — design + drift check (no remote writes)

- Verified `payload_store/{__init__.py,ports.py,filesystem.py,
  s3.py,gcs.py}` on `origin/main` are unchanged since the round 3
  merge — no drift.
- Installed `azure-storage-blob` via `uv pip install --python
  .venv/bin/python azure-storage-blob`. Resolved version: `12.29.0`.
  Pulled `azure-core` from `1.35.0` → `1.41.0` (already a transitive
  dep). pyproject constraint set to `azure-storage-blob>=12.20.0`
  for a sane floor.
- Confirmed the imports: `from azure.storage.blob import
  BlobServiceClient, ContentSettings`,
  `from azure.core.exceptions import ResourceNotFoundError`.
- Confirmed `BlobServiceClient.account_name` resolves to a usable
  string on an instance — used in the `_uri_for` URI shape.
- Searched for any existing Azure Blob URI convention in
  `noetl/tools/`: only `noetl/tools/python/executor.py` references
  Azure (sets `AZURE_STORAGE_CONNECTION_STRING` for the
  `azure`/`azure_storage` service flag). No URI shape established
  there, so this round establishes
  `azure://<account>/<container>/<key>` as the canonical form,
  with `azure://<container>/<key>` as the fallback when the
  account name isn't derivable from the client.
- Decision: keep `_validate_metadata` independent per the prompt
  recommendation. Azure imposes a C#-identifier rule on metadata
  keys (S3 + GCS don't), so the constraint is genuinely
  per-backend, not just stylistic divergence.

## Phase B — implementation

- Wrote `noetl/core/payload_store/azure.py`:
  - `AzureBlobPayloadStore` constructor accepts
    `container, *, prefix="", account_url=None, credential=None,
    connection_string=None, client=None,
    default_content_type="application/octet-stream"`.
  - Constructor enforces that **one of** `client`,
    `connection_string`, or `account_url` is provided — raises
    `ValueError` otherwise (covered by
    `test_constructor_requires_auth_source`).
  - When `client is None`, builds via
    `BlobServiceClient.from_connection_string(...)` if
    `connection_string` is set, otherwise
    `BlobServiceClient(account_url=..., credential=...)`.
  - Caches
    `self.container_client = self.client.get_container_client(container)`
    once at construction; sync workers query
    `self.container_client.get_blob_client(key)` per call.
  - `_key_for(sha)` returns `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`.
  - `_uri_for(key)` returns
    `azure://<account>/<container>/<key>` when
    `getattr(client, "account_name", None)` is truthy, else
    `azure://<container>/<key>`.
  - `_validate_metadata` enforces a C#-identifier key rule
    (`re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)`) and ASCII
    values; raises `ValueError` with a distinct message per
    constraint so callers can tell which rule fired.
  - `_is_not_found(exc)` matches `ResourceNotFoundError` with a
    duck-typed `status_code == 404` fallback.
  - `_head_sync` / `_store_sync` / `_fetch_sync` / `_delete_sync`
    sync workers; async `store`/`fetch`/`exists`/`delete` bridge
    through `asyncio.to_thread`.
  - `_store_sync` calls `blob.upload_blob(payload,
    content_settings=ContentSettings(content_type=...),
    metadata=metadata or None)`. The `metadata or None` keeps
    the kwarg clean when no metadata is passed (Azure SDK
    accepts both an empty dict and `None`).
  - `_fetch_sync` translates Azure `ResourceNotFoundError` into
    `PayloadNotFound`.
  - `_delete_sync` uses the canonical `exists` + `delete_blob`
    pattern.
- Updated `noetl/core/payload_store/__init__.py` to re-export
  `AzureBlobPayloadStore`.
- Updated `pyproject.toml` runtime deps to add
  `azure-storage-blob>=12.20.0`.
- Refreshed `uv.lock` via `uv lock` — pulled
  `azure-storage-blob 12.29.0` plus the `azure-core 1.35 → 1.41`
  bump.
- Smoke import passes:
  `from noetl.core.payload_store import AzureBlobPayloadStore` →
  class resolves.

## Phase C — tests

- Wrote `tests/core/payload_store/test_azure.py` — 21 tests via
  `unittest.mock.MagicMock` stubbing the
  `BlobServiceClient.get_container_client(...) → ContainerClient;
  ContainerClient.get_blob_client(...) → BlobClient` chain.
  Coverage:
  - `test_constructor_uses_injected_client` — confirms no
    `BlobServiceClient()` call when an explicit client is passed.
  - `test_constructor_rejects_empty_container` — `ValueError`
    with `match="container name"`.
  - `test_constructor_requires_auth_source` — `ValueError` with
    `match="connection_string"` when none of
    `client`/`connection_string`/`account_url` is supplied.
  - `test_store_uploads_via_blob_with_metadata` — confirms
    `get_blob_client(<expected_key>)`, asserts the
    `upload_blob` call's positional payload + the
    `ContentSettings(content_type=...)` instance + the metadata
    dict; verifies the returned `PayloadReference` fields.
  - `test_store_dedups_when_blob_exists` — `BlobClient.exists()`
    returns `True`; `upload_blob` is not called.
  - `test_fetch_raises_payload_not_found_on_azure_404` —
    `download_blob` raises `ResourceNotFoundError`, surface
    becomes `PayloadNotFound`.
  - `test_fetch_returns_blob_bytes` — happy-path round-trip via
    a `StorageStreamDownloader` mock with `readall()`.
  - `test_exists_passes_through_blob_exists[True/False]` —
    parametrized.
  - `test_delete_returns_false_on_missing_blob` — `delete_blob`
    not called.
  - `test_delete_returns_true_on_existing_blob` — `delete_blob`
    called exactly once.
  - `test_key_layout_matches_filesystem_sharding` — same
    `<sha[:2]>/<sha[2:4]>/<sha>` shape.
  - `test_prefix_normalization` — `/payloads/` → `payloads`
    (leading + trailing slash stripped).
  - `test_uri_is_azure_scheme` —
    `azure://<account>/<container>/`.
  - `test_uri_falls_back_when_account_name_missing` — when
    `client.account_name is None` the URI is
    `azure://<container>/<key>`.
  - `test_metadata_validation_rejects_non_ascii_value` —
    `ValueError` with `match="ASCII"`.
  - `test_metadata_key_rejects_invalid_identifier[bad_key]` —
    parametrized across `"my-key"`, `"1bad"`, `"bad.key"`,
    `"with space"`; each raises `ValueError` with
    `match="C# identifier"`.
  - `test_missing_container_propagates_error` —
    `upload_blob` raising `ResourceNotFoundError("container does
    not exist")` propagates instead of being caught.

- Local pytest results:

  ```
  $ pytest tests/core/payload_store/test_azure.py -q
  21 passed in 0.87s

  $ pytest tests/core/payload_store/ -q
  72 passed

  $ pytest tests/core/payload_store/
           tests/core/test_projector_metrics.py
           tests/core/test_replay_state_projector.py
           tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
  124 passed, 33 warnings in 5.34s
  ```

  (The 33 warnings are the same pre-existing Pydantic v2
  deprecation notices from `test_projector_metrics.py` carried
  over from round 3 — not introduced by this round.)

## Phase D — wiki update

- Updated `repos/noetl-wiki/noetl/core/payload_store.md`:
  - Status section now lists `AzureBlobPayloadStore` alongside
    `S3PayloadStore` + `GCSPayloadStore`; phase line reads
    "Rounds 1–4 complete (port + filesystem + S3 + GCS + Azure)".
    SeaweedFS noted as covered by `S3PayloadStore` in S3 mode.
  - New `## AzureBlobPayloadStore` section between
    `## GCSPayloadStore` and `## SeaweedFS`. Covers
    construction (account_url/credential/connection_string/
    injected client + the one-of-three auth requirement), key
    layout, URI shape, metadata semantics (C#-identifier key
    rule + ASCII value rule), content type semantics, dedup,
    atomicity, Protocol-compliant delete, sync-SDK + thread
    bridging rationale, full configuration table.
  - New `## SeaweedFS` section between
    `## AzureBlobPayloadStore` and `## Compliance suite`. Cover:
    canonical recipe (use `S3PayloadStore` with `endpoint_url`),
    credentials caveat (validate against the gateway's
    configured pair; dev-mode SeaweedFS without IAM accepts any
    non-empty pair), native HTTP API mentioned as future work.
  - "Compliance suite" section updated to note both GCS and
    Azure are deferred from the parametrized fixture pending a
    process-emulator harness (Azurite + fake-gcs-server are
    both process-based binaries).
  - "Where this fits" diagram updated to list S3 + GCS + Azure
    cloud adapters, with SeaweedFS → S3 mode noted.
- Wiki commit:
  `wiki(payload_store): document Azure Blob adapter + SeaweedFS via S3 mode`
  (`noetl.wiki@e201549`). Pushed to `origin/master`.

## Phase E — verify locally

- Pytest is the only required gate this round. Already green;
  see Phase C numbers.

## Phase F — open PR and merge

- Branch `kadyapam/phase5-payload-store-azure` pushed.
- PR opened: **noetl#591** "feat(payload-store): add Azure Blob
  adapter + SeaweedFS docs" —
  https://github.com/noetl/noetl/pull/591
- Body lists summary, design notes, SeaweedFS doc-only nature,
  compliance-suite note, test plan, paired wiki commit pointer,
  and round-5 follow-ups (payload_ref binding + emulator
  fixture).

**Merge step blocked: awaiting `merge phase 5 azure`.** No
`gh pr merge` run.

## Issues observed

- None. The aioboto3-vs-moto trap from round 2 did not recur:
  the prompt locked in sync-SDK + `asyncio.to_thread` up front,
  and we deliberately avoided the `azure.storage.blob.aio`
  surface despite it being available.
- Azure's metadata-key constraint (must be a valid C#
  identifier) is stricter than S3 and GCS. Caught early via the
  prompt's design section; encoded in `_validate_metadata` with
  a distinct error message so callers can tell which rule fired.
- `uv lock` pulled an unexpected but consequence-free
  `azure-core 1.35 → 1.41` bump because `azure-storage-blob`
  required a newer floor than the existing
  `azure-identity` / `azure-keyvault-secrets` indirect pin. No
  test failures observed; no source-code adjustments required.

## Manual escalation needed

To complete Phase F, the human (or a subsequent agent acting
on their go-ahead) must:

1. Confirm CI passes on noetl#591.
2. Say the wait phrase `merge phase 5 azure`.
3. Then the executor runs:

   ```
   gh pr merge 591 --admin --merge --delete-branch
   git -C repos/noetl fetch origin
   git -C repos/noetl checkout main && git -C repos/noetl pull origin main
   git -C repos/noetl-wiki pull origin master    # already at e201549
   git -C /Volumes/X10/projects/noetl/ai-meta add repos/noetl repos/noetl-wiki
   git -C /Volumes/X10/projects/noetl/ai-meta commit -m "chore(sync): bump noetl + noetl-wiki for phase5 Azure Blob adapter"
   git -C /Volumes/X10/projects/noetl/ai-meta push origin main
   ```
4. Archive the handoff thread under `handoffs/archive/`.
5. Drop a `memory_add.sh` entry summarizing the round.
