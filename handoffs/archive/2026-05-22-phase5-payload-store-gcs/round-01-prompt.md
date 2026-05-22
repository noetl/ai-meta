---
thread: 2026-05-22-phase5-payload-store-gcs
round: 1
from: claude
to: claude
created: 2026-05-22T22:08:33Z
status: open
expects_result_at: round-01-result.md
---

# Phase 5 round 3: GCS payload-store adapter

> **Predecessor:** Phase 5 round 2 completed in
> `handoffs/archive/2026-05-22-phase5-payload-store-s3/`
> (noetl v2.94.0). Established the sync-SDK + `asyncio.to_thread`
> pattern; added the `S3PayloadStore` + parametrized compliance
> suite + 8 S3-specific tests.

This round adds the **Google Cloud Storage adapter** following
the canonical sync-SDK pattern. Azure Blob and SeaweedFS land
in round 4 (different deps + emulator infrastructure).

## What this round delivers

1. `noetl/core/payload_store/gcs.py` — `GCSPayloadStore` async
   adapter via sync `google-cloud-storage` + `asyncio.to_thread`.
2. `noetl/core/payload_store/__init__.py` — re-export
   `GCSPayloadStore`.
3. `tests/core/payload_store/test_gcs.py` — GCS-specific unit
   tests using `unittest.mock` (no emulator). Cover call shape,
   key layout, dedup-via-exists, missing-blob → `PayloadNotFound`,
   metadata round-trip through mocked Blob, URI scheme, missing-
   bucket propagation.
4. **Skip extending the compliance fixture to GCS** in this
   round (no fake-gcs-server-as-library; emulator infra is a
   round 4 / future concern). Documented as a follow-up.
5. Wiki page update — extend
   [`noetl/core/payload_store`](https://github.com/noetl/noetl/wiki/payload_store)
   with the new "GCS adapter" subsection.

## Background

### Verified existing surface

- [`noetl/core/payload_store/__init__.py`](https://github.com/noetl/noetl/blob/main/noetl/core/payload_store/__init__.py)
  on `main` (sha `e4e13945` / v2.94.0) — `PayloadStore`
  Protocol, `PayloadReference`, `PayloadNotFound`,
  `content_hash`, `FilesystemPayloadStore`, `S3PayloadStore`.
- [`noetl/core/payload_store/s3.py`](https://github.com/noetl/noetl/blob/main/noetl/core/payload_store/s3.py)
  — template for the new adapter. Constructor +
  `_key_for(sha)` + `_validate_metadata` + sync workers
  bridged via `asyncio.to_thread`.
- `google-cloud-storage>=2.18.0` already in
  `pyproject.toml` runtime deps. No new top-level dep needed.
- [`noetl/tools/gcs/executor.py`](https://github.com/noetl/noetl/blob/main/noetl/tools/gcs/executor.py)
  and [`noetl/core/storage/backends.py`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/backends.py)
  — existing GCS usage. Adapter doesn't depend on these but they
  can inform credential-handling patterns.

### Why no compliance-suite extension in this round

`moto` provides an in-process S3 mock that the existing
compliance fixture uses cleanly. There's **no equivalent
in-process GCS library** today — `fake-gcs-server` is a
process-based emulator (Docker image / standalone binary), not
a Python library you can decorate a test with.

Options considered and deferred:
- **`gcp-storage-emulator`** (Python package wrapping the
  emulator binary) — viable but adds CI infrastructure: needs
  port allocation, async startup, and Docker on the host. Not
  worth the friction for round 3.
- **Mock the entire `google.cloud.storage.Client` surface** —
  doable, but the resulting "compliance" run is mostly
  exercising the mock, not the adapter. Skip.
- **Real GCS** — too much friction for unit tests.

The canonical compliance gate stays at filesystem + S3 for now.
GCS gets dedicated unit tests with `unittest.mock`. Round 4
revisits this if Azurite (the Azure storage emulator) ends up
co-installable; the same infra would work for both GCS and
Azure if it does.

### GCS adapter design

`google-cloud-storage` is **sync only** (no native async client),
so the adapter follows the same sync + `asyncio.to_thread`
pattern as `S3PayloadStore`. Operations map to the GCS SDK as:

| Protocol method | GCS SDK call(s) |
|---|---|
| `store(payload, ...)` | `bucket.blob(key).exists()` (dedup) + `bucket.blob(key).upload_from_string(payload, content_type=..., metadata=...)` |
| `fetch(ref)` | `bucket.blob(key).download_as_bytes()` — raises `google.api_core.exceptions.NotFound` on missing |
| `exists(ref)` | `bucket.blob(key).exists()` |
| `delete(ref)` | `bucket.blob(key).delete()` — raises `NotFound` on missing → catch and return False |

Constructor parallels `S3PayloadStore`:

```python
class GCSPayloadStore(PayloadStore):
    def __init__(
        self,
        bucket: str,
        *,
        prefix: str = "",
        client: Optional[Any] = None,
        project: Optional[str] = None,
        credentials: Optional[Any] = None,
        default_content_type: str = "application/octet-stream",
    ): ...
```

- `client` — pre-configured `google.cloud.storage.Client`.
  When `None`, build one from `project` + `credentials`.
- `credentials` — accepts a
  `google.oauth2.service_account.Credentials` instance or a
  service-account JSON path string. Maintained for parity with
  the existing GCS tool (which uses the same shape).

### GCS metadata semantics

GCS object metadata is a dict of string → string carried as
custom metadata on the blob. Same constraint as S3: keys and
values should be ASCII for portability. The adapter validates
at the boundary (same `_validate_metadata` shape as
`S3PayloadStore`).

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-verify `payload_store/{__init__.py,s3.py,filesystem.py}`
   on `origin/main`. Flag any drift since the round 2 merge.
2. Decide whether to alias the metadata-validation helper to
   share it between `S3PayloadStore` and `GCSPayloadStore`.
   Recommendation: **don't** share yet. The constraint logic is
   the same now but may diverge per backend (e.g., GCS allows
   slightly different byte sequences in some chars). Keep
   independent for the round, factor later if it stabilizes.
3. Confirm `google-cloud-storage` is importable in the venv. If
   not, install via the same `uv pip install` path used for
   `moto`.

### Phase B — implementation

4. **GCS adapter** — `noetl/core/payload_store/gcs.py`:
   - Module docstring referencing S3 adapter's design notes
     verbatim where they apply (atomicity intrinsic to GCS
     PUT, content-addressing dedup, metadata via blob.metadata,
     async-surface / sync-backend rationale).
   - `GCSPayloadStore` constructor accepting the fields above.
     Build `storage.Client(project=..., credentials=...)` when
     `client is None`. Cache a per-instance `bucket` reference
     (`self.client.bucket(bucket_name)`).
   - `_key_for(sha)` — identical layout
     `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`.
   - `_uri_for(key)` returns `gs://<bucket>/<key>`.
   - `_validate_metadata` — same shape as S3 adapter (ASCII
     check, returns normalized dict).
   - `_is_not_found(exc)` — checks for
     `google.api_core.exceptions.NotFound`.
   - Sync workers `_head_sync`, `_store_sync`, `_fetch_sync`,
     `_delete_sync` calling the appropriate `blob.<method>()`,
     returning Protocol-shaped values.
   - Async `store` / `fetch` / `exists` / `delete` bridge
     through `asyncio.to_thread`.

5. **Re-exports** — `noetl/core/payload_store/__init__.py`:
   - Import `GCSPayloadStore`, add to `__all__`.

### Phase C — tests

6. New file `tests/core/payload_store/test_gcs.py`:
   - Use `unittest.mock.MagicMock` to stub the
     `google.cloud.storage.Client` chain (`Client.bucket(...)
     → Bucket; Bucket.blob(...) → Blob; Blob.exists() / .upload_from_string()
     / .download_as_bytes() / .delete() / .metadata`).
   - Test cases:
     - `test_constructor_uses_injected_client` — confirm
       constructor doesn't construct a Client when `client=`
       is supplied.
     - `test_store_uploads_via_blob_with_metadata` — assert
       `upload_from_string` is called with the expected
       `data=`, `content_type=`, then `blob.metadata` is set,
       then `patch()` is called. (Confirm exact GCS SDK call
       shape.)
     - `test_store_dedups_when_blob_exists` — mock
       `blob.exists()` to return True; assert
       `upload_from_string` is NOT called.
     - `test_fetch_raises_payload_not_found_on_gcs_404` —
       mock `blob.download_as_bytes` to raise
       `google.api_core.exceptions.NotFound`; assert
       `PayloadNotFound` is raised.
     - `test_exists_passes_through_blob_exists` —
       parametrize True/False from `blob.exists()`.
     - `test_delete_returns_false_on_missing_blob` —
       `blob.exists()` returns False; `delete()` returns False
       without calling `blob.delete()`.
     - `test_delete_returns_true_on_existing_blob` —
       `blob.exists()` returns True; assert `blob.delete()`
       is called and `delete()` returns True.
     - `test_key_layout_matches_filesystem_sharding` — same
       sharded key shape as filesystem + S3 (`<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`).
     - `test_prefix_normalization` — leading/trailing slashes
       on `prefix` are stripped.
     - `test_uri_is_gs_scheme` — `PayloadReference.uri`
       starts with `gs://<bucket>/`.
     - `test_metadata_validation_rejects_non_ascii` — same as
       S3 adapter.
     - `test_missing_bucket_propagates_error` — mock
       `blob.upload_from_string` to raise
       `google.api_core.exceptions.NotFound` indicating
       bucket missing; assert it propagates (not silently
       caught).

7. Run:
   ```
   pytest tests/core/payload_store/ -q
   pytest tests/core/payload_store/
          tests/core/test_projector_metrics.py
          tests/core/test_replay_state_projector.py
          tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
   ```
   All green.

### Phase D — wiki update

8. Update `repos/noetl-wiki/noetl/core/payload_store.md`:
   - Add `## GCSPayloadStore` section between `## S3PayloadStore`
     and `## Compliance suite`.
   - Cover: construction (project / credentials / injected
     client), key layout (`gs://<bucket>/<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`),
     dedup via `blob.exists()`, delete via `exists + delete` for
     Protocol-compliant True/False, metadata via blob custom
     metadata, sync-SDK + thread bridging rationale.
   - Update the "Compliance suite" section to note that GCS
     isn't yet in the parametrized fixture pending emulator
     infrastructure.

9. Commit + push wiki.

### Phase E — verify locally

10. Pytest covers the surface. No emulator / kind / real-GCS
    needed.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 5 gcs`.***

11. Push branch `kadyapam/phase5-payload-store-gcs`, open
    noetl PR titled `feat(payload-store): add GCS adapter`.
12. Wait for CI / human review.
13. Merge with `--admin --merge --delete-branch`.
14. Bump ai-meta pointers (noetl + noetl-wiki).

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 5 gcs`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D wiki
  edit ships paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No Azure Blob / SeaweedFS / `payload_ref` binding in this
  round.** Round 4 covers those.
- **No emulator-based GCS tests.** If the human wants to add
  `gcp-storage-emulator` later, that's a separate round with a
  proper fixture design.
