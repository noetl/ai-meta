---
thread: 2026-05-22-phase5-payload-store-azure
round: 1
from: claude
to: claude
created: 2026-05-22T22:55:00Z
status: open
expects_result_at: round-01-result.md
---

# Phase 5 round 4: Azure Blob adapter + SeaweedFS docs

> **Predecessor:** Phase 5 round 3 completed in
> `handoffs/archive/2026-05-22-phase5-payload-store-gcs/`
> (noetl v2.95.0). Established `GCSPayloadStore` via the
> canonical sync-SDK + `asyncio.to_thread` pattern with
> `unittest.mock` tests (no in-process emulator).

This round adds the **Azure Blob Storage adapter** following the
same canonical pattern and documents the **SeaweedFS** path
(which lands as a doc-only subsection because SeaweedFS in S3
mode is already covered by `S3PayloadStore` + `endpoint_url`).

The `EventRecord.payload_ref` typed binding (mentioned in
round 3's notes for next round) is **deferred to a future
round 5**. That work touches the event-store envelope, postgres
insert path, frames endpoint, and replay service — meaty enough
to keep separate from the adapter rollout.

## What this round delivers

1. `noetl/core/payload_store/azure.py` — `AzureBlobPayloadStore`
   async adapter via the sync `azure-storage-blob` SDK +
   `asyncio.to_thread`.
2. `noetl/core/payload_store/__init__.py` — re-export
   `AzureBlobPayloadStore`.
3. `tests/core/payload_store/test_azure.py` — Azure-specific unit
   tests using `unittest.mock` (no Azurite emulator). Cover
   constructor injection, container/blob call shape, dedup via
   `BlobClient.exists()`, missing-blob → `PayloadNotFound`,
   metadata round-trip on `upload_blob`, URI scheme, missing-
   container propagation.
4. `pyproject.toml` — add `azure-storage-blob>=12.20.0` to runtime
   deps (alongside the existing `azure-identity` /
   `azure-keyvault-secrets`).
5. Wiki page update — extend
   `noetl/core/payload_store.md` with new
   `## AzureBlobPayloadStore` and `## SeaweedFS` sections, plus
   status / "Where this fits" diagram updates.
6. **Skip extending the compliance fixture** to Azure for the
   same reason as GCS (Azurite is a process-based emulator;
   round 3's deferral applies here too). Documented as the
   follow-up.

## Background

### Verified existing surface

- `noetl/core/payload_store/__init__.py` on `main` exports
  `PayloadStore`, `PayloadReference`, `PayloadNotFound`,
  `content_hash`, `FilesystemPayloadStore`, `S3PayloadStore`,
  `GCSPayloadStore` after round 3.
- `noetl/core/payload_store/gcs.py` is the closest template:
  injected client, ASCII metadata validation, dedup via
  `exists()`, sync workers bridged via `asyncio.to_thread`,
  Protocol-compliant delete via `exists + delete`.
- `azure-identity>=1.23.0` and `azure-keyvault-secrets>=4.8.0`
  are already in `pyproject.toml` runtime deps. Adding
  `azure-storage-blob` puts it alongside its siblings. The
  Azure auth chain (DefaultAzureCredential) is already
  available via `azure-identity`.
- SeaweedFS in S3 mode is already covered by `S3PayloadStore`
  with `endpoint_url="http://seaweedfs:8333"`. The S3 adapter
  wiki section already mentions this. Round 4 just adds a
  dedicated `## SeaweedFS` subsection that points at that path
  explicitly.

### Why no compliance-fixture extension this round

Azurite (the official Azure storage emulator) is a process-based
mock — Node.js binary or container image, not a Python
decorator. Same situation as `fake-gcs-server` for GCS. Round 3
already established that in-process emulators are deferred to a
dedicated test-infra round; this round inherits that decision.

Azure gets dedicated `unittest.mock` unit tests like GCS did.

### Azure Blob adapter design

`azure-storage-blob` is **sync only by default** (it also ships
an `aio` submodule, but using it would mirror the round-2
aioboto3-vs-moto trap and force aio-aware testing infrastructure
we don't have). The adapter follows the same sync + `asyncio.to_thread`
pattern. Operations map to the Azure SDK as:

| Protocol method | Azure SDK call(s) |
|---|---|
| `store(payload, ...)` | `BlobClient.exists()` (dedup) + `BlobClient.upload_blob(payload, content_settings=ContentSettings(content_type=...), metadata=...)` |
| `fetch(ref)` | `BlobClient.download_blob().readall()` — raises `azure.core.exceptions.ResourceNotFoundError` on missing |
| `exists(ref)` | `BlobClient.exists()` |
| `delete(ref)` | `BlobClient.exists()` + `BlobClient.delete_blob()` — `delete_blob` raises `ResourceNotFoundError` on missing → use exists check for Protocol-compliant True/False |

Constructor parallels `GCSPayloadStore`:

```python
class AzureBlobPayloadStore(PayloadStore):
    def __init__(
        self,
        container: str,
        *,
        prefix: str = "",
        account_url: Optional[str] = None,
        credential: Optional[Any] = None,
        connection_string: Optional[str] = None,
        client: Optional[Any] = None,
        default_content_type: str = "application/octet-stream",
    ): ...
```

- `client` — pre-configured `BlobServiceClient`. When `None`,
  build one from `connection_string` (preferred for local /
  Azurite work) or `account_url` + `credential`.
- `credential` — accepts a `TokenCredential` (typically
  `DefaultAzureCredential`) or an account-key string.
- `account_url` — e.g. `https://<account>.blob.core.windows.net`.
- `connection_string` — full Azure storage connection string.
  Used to seed `BlobServiceClient.from_connection_string(...)`
  if provided.

The container is the moral equivalent of an S3 bucket / GCS
bucket. Cache `self.container_client = self.client.get_container_client(container)`
for per-instance reuse, then create per-blob clients on demand
via `self.container_client.get_blob_client(key)`.

### Azure Blob metadata semantics

Azure Blob custom metadata is a dict of string → string carried
as `x-ms-meta-*` headers. The Azure SDK accepts a `metadata=`
kwarg on `upload_blob`. **Constraint:** metadata header names
must be valid C# identifiers (ASCII letters, digits, underscore;
must start with a letter or underscore), and values should be
ASCII for portability. The adapter validates at the boundary
with the same wording / shape as the S3 + GCS adapters.

### Content type semantics

Azure expects content type via `ContentSettings(content_type=...)`
passed to `upload_blob`. Import:

```python
from azure.storage.blob import ContentSettings
```

The adapter constructs a `ContentSettings(content_type=effective_content_type)`
and passes it through.

### SeaweedFS — doc-only

SeaweedFS exposes an S3-compatible API on its filer / S3 gateway
port (default 8333). The existing `S3PayloadStore` covers this
case via `endpoint_url="http://<host>:8333"` plus an arbitrary
non-empty access/secret pair. Round 4 just adds a `## SeaweedFS`
section to the wiki page that:

- Notes the canonical recipe (use `S3PayloadStore` with
  `endpoint_url`).
- Calls out the credentials caveat (SeaweedFS validates but
  doesn't enforce IAM by default — set access/secret on the
  gateway side and pass them through standard boto3 env vars
  or an injected client).
- Mentions the SeaweedFS-native HTTP API as a potential future
  adapter only if the S3-mode path falls short of something we
  need. Not implemented in this round.

No new adapter code.

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-verify `payload_store/{__init__.py,s3.py,gcs.py,filesystem.py}`
   on `origin/main`. Flag any drift since the round 3 merge.
2. Confirm `azure-storage-blob` package will pip-install cleanly
   (run `.venv/bin/python -m pip install --dry-run azure-storage-blob`
   or just `.venv/bin/python -m pip install azure-storage-blob` and
   verify version). Capture the installed version for the
   pyproject.toml constraint.
3. Decide on the `_validate_metadata` shape — same ASCII-only
   constraint as S3 + GCS plus the Azure C#-identifier-style key
   rule. Per-adapter independence stays the right call.

### Phase B — implementation

4. **Azure adapter** — `noetl/core/payload_store/azure.py`:
   - Module docstring referencing the S3 + GCS adapters'
     design notes verbatim where they apply (atomicity intrinsic
     to Azure PUT, content-addressing dedup, metadata via blob
     custom metadata, async-surface / sync-backend rationale).
   - Top-level imports guarded with `try/except ImportError` so
     a missing `azure-storage-blob` raises a clear `RuntimeError`
     from the constructor (same shape as `gcs.py` /  `s3.py`).
   - `AzureBlobPayloadStore` constructor accepting the fields
     above. Build `BlobServiceClient` via
     `from_connection_string` when `connection_string` is set,
     otherwise via `BlobServiceClient(account_url, credential=credential)`.
     Cache `self.container_client = self.client.get_container_client(container)`.
   - `_key_for(sha)` — identical sharded layout
     `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`.
   - `_uri_for(key)` returns
     `azure://<account>/<container>/<key>` if account name is
     derivable from `account_url`, else
     `azure://<container>/<key>`. Aim: keep the URI shape
     parseable. Cross-check the existing Azure-using code in
     `noetl/tools/` (if any) for an established URI convention
     and follow it; otherwise establish `azure://<account>/<container>/<key>`.
   - `_validate_metadata` — same ASCII + C#-identifier check.
     `re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)` for the key
     rule. Raise `ValueError` on violation.
   - `_is_not_found(exc)` — checks for
     `azure.core.exceptions.ResourceNotFoundError`.
   - Sync workers `_head_sync`, `_store_sync`, `_fetch_sync`,
     `_delete_sync` calling the appropriate
     `container_client.get_blob_client(key).<method>()`,
     returning Protocol-shaped values.
   - Async `store` / `fetch` / `exists` / `delete` bridge
     through `asyncio.to_thread`.

5. **Re-exports** — `noetl/core/payload_store/__init__.py`:
   - Import `AzureBlobPayloadStore`, add to `__all__`.

6. **Dependency** — `pyproject.toml`:
   - Add `azure-storage-blob>=12.20.0` (or whichever current
     version Phase A confirmed) to the runtime deps array,
     alongside `azure-identity` and `azure-keyvault-secrets`.
   - Run `uv lock` / `uv sync` if those are the project's
     pattern, OR `.venv/bin/python -m pip install -e .` to
     refresh the dev env. Capture the lockfile change if one
     exists.

### Phase C — tests

7. New file `tests/core/payload_store/test_azure.py`:
   - Use `unittest.mock.MagicMock` to stub the
     `BlobServiceClient → ContainerClient → BlobClient` chain.
   - Test cases:
     - `test_constructor_uses_injected_client` — confirm
       constructor doesn't construct a `BlobServiceClient`
       when `client=` is supplied; container client is queried
       once with the right name.
     - `test_constructor_rejects_empty_container` —
       `ValueError("container name")`.
     - `test_store_uploads_via_blob_with_metadata` — assert
       `upload_blob` is called with `data=`, the correct
       `ContentSettings(content_type=...)`, and the metadata dict.
       Use a custom matcher / capture for the ContentSettings
       argument since it's an object.
     - `test_store_dedups_when_blob_exists` — mock
       `BlobClient.exists()` to return True; assert
       `upload_blob` is NOT called.
     - `test_fetch_raises_payload_not_found_on_azure_404` —
       mock `BlobClient.download_blob` to raise
       `azure.core.exceptions.ResourceNotFoundError`; assert
       `PayloadNotFound` is raised.
     - `test_fetch_returns_blob_bytes` — mock chain
       `download_blob().readall()` returns the payload.
     - `test_exists_passes_through_blob_exists` —
       parametrize True/False from `BlobClient.exists()`.
     - `test_delete_returns_false_on_missing_blob` —
       `BlobClient.exists()` returns False; `delete()` returns
       False without calling `delete_blob()`.
     - `test_delete_returns_true_on_existing_blob` —
       `BlobClient.exists()` returns True; assert `delete_blob()`
       is called and `delete()` returns True.
     - `test_key_layout_matches_filesystem_sharding` — same
       sharded key shape as filesystem + S3 + GCS.
     - `test_prefix_normalization` — leading/trailing slashes
       on `prefix` are stripped.
     - `test_uri_is_azure_scheme` — `PayloadReference.uri`
       starts with `azure://` (exact host shape depends on the
       Phase B design decision but the scheme is fixed).
     - `test_metadata_validation_rejects_non_ascii` — same as
       S3 / GCS adapters.
     - `test_metadata_key_rejects_invalid_identifier` — keys
       must be valid C# identifiers; assert
       `ValueError` on keys like `"my-key"` or `"1bad"`.
     - `test_missing_container_propagates_error` — mock
       `BlobClient.upload_blob` to raise
       `azure.core.exceptions.ResourceNotFoundError` indicating
       container missing; assert it propagates (not silently
       caught).

8. Run:
   ```
   .venv/bin/python -m pytest tests/core/payload_store/ -q
   .venv/bin/python -m pytest tests/core/payload_store/
         tests/core/test_projector_metrics.py
         tests/core/test_replay_state_projector.py
         tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
   ```
   All green.

### Phase D — wiki update

9. Update `repos/noetl-wiki/noetl/core/payload_store.md`:
   - Status section: list `AzureBlobPayloadStore` alongside
     `S3PayloadStore` and `GCSPayloadStore`. Phase line says
     "Rounds 1–4 complete (filesystem + S3 + GCS + Azure);
     `payload_ref` typed binding remains for round 5".
   - Add `## AzureBlobPayloadStore` section between
     `## GCSPayloadStore` and `## Compliance suite`. Cover:
     construction (account_url / credential / connection_string /
     injected client), key layout
     (`azure://<account>/<container>/<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`
     or the chosen URI shape), dedup via `BlobClient.exists()`,
     delete via `exists + delete_blob` for Protocol-compliant
     True/False, metadata via blob custom metadata with C#-
     identifier-style key constraint, sync-SDK + thread bridging
     rationale, Azurite-emulator note (deferred to a future
     test-infra round).
   - Add `## SeaweedFS` section between `## AzureBlobPayloadStore`
     and `## Compliance suite`. Cover: SeaweedFS S3-mode via
     `S3PayloadStore(endpoint_url=...)`, credentials caveat,
     SeaweedFS-native HTTP API mentioned as future work.
   - Update the "Compliance suite" section to note that Azure
     also isn't yet in the parametrized fixture (Azurite is a
     process-based emulator like fake-gcs-server).
   - Update "Where this fits" diagram to list S3 + GCS + Azure
     as cloud adapters.

10. Commit + push wiki.

### Phase E — verify locally

11. Pytest covers the surface. No emulator / kind / real-Azure
    needed.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 5 azure`.***

12. Push branch `kadyapam/phase5-payload-store-azure`, open
    noetl PR titled
    `feat(payload-store): add Azure Blob adapter + SeaweedFS docs`.
13. Wait for CI / human review.
14. Merge with `--admin --merge --delete-branch`.
15. Bump ai-meta pointers (noetl + noetl-wiki).

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 5 azure`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D wiki
  edit ships paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No `payload_ref` typed binding in this round.** Round 5
  covers that.
- **No SeaweedFS-native adapter in this round.** S3-mode docs
  only.
- **No Azurite-based fixture extension.** If the human wants
  Azurite + a process-based test fixture later, that's a
  separate test-infra round.
