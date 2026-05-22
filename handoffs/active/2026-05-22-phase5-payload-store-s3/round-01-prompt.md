---
thread: 2026-05-22-phase5-payload-store-s3
round: 1
from: claude
to: claude
created: 2026-05-22T21:50:05Z
status: open
expects_result_at: round-01-result.md
---

# Phase 5 round 2: S3 payload-store adapter + compliance suite

> **Predecessor:** Phase 5 round 1 completed in
> `handoffs/archive/2026-05-22-phase5-payload-store-port/`
> (noetl v2.93.0). Established `PayloadStore` Protocol +
> `FilesystemPayloadStore` reference.

This round adds the **S3 / S3-compatible adapter** plus an
**adapter-agnostic compliance test suite** so the filesystem
reference and S3 adapter are exercised against the same behavior
contract. The compliance suite is the long-term mechanism for
keeping future adapters (GCS, Azure Blob, SeaweedFS) honest.

## What this round delivers

1. `noetl/core/payload_store/s3.py` — `S3PayloadStore` async adapter
   using `aioboto3` (already a top-level dep).
2. `noetl/core/payload_store/__init__.py` — re-export
   `S3PayloadStore`.
3. `pyproject.toml` — add `moto[s3]>=5.0` to the `dev` extras (no
   change to runtime deps).
4. `tests/core/payload_store/test_compliance.py` — adapter-agnostic
   test suite running against both `FilesystemPayloadStore` and
   `S3PayloadStore` via pytest parametrization. Mock S3 via
   `moto.mock_aws`.
5. `tests/core/payload_store/test_s3.py` — S3-specific tests
   (key layout, custom metadata via S3 object metadata headers,
   bucket-prefix handling, behavior on missing bucket).
6. Wiki page update — extend
   [`noetl/core/payload_store`](https://github.com/noetl/noetl/wiki/payload_store)
   with the new "S3 adapter" subsection.

## Out of scope for this round

- **GCS / Azure Blob / SeaweedFS adapters.** Each is its own
  round.
- **No migration of existing callers.** TempStore stays unchanged.
- **No event-envelope binding.** `EventRecord.payload_ref` still
  an opaque dict.
- **No SeaweedFS-flavored test variant.** SeaweedFS-on-S3-mode
  works through the same adapter, but a dedicated round will
  validate the integration.

## Background

### Existing surface (verified)

- [`noetl/core/payload_store/ports.py`](https://github.com/noetl/noetl/blob/main/noetl/core/payload_store/ports.py)
  — `PayloadStore` Protocol, `PayloadReference`,
  `PayloadNotFound`, `content_hash`.
- [`noetl/core/payload_store/filesystem.py`](https://github.com/noetl/noetl/blob/main/noetl/core/payload_store/filesystem.py)
  — reference adapter; behavior the S3 adapter must match.
- `boto3>=1.38.45` and `aioboto3>=13.0.0` already in
  `pyproject.toml` runtime deps.
- `moto` is **not** installed today (verified via `python -c "import moto"` ImportError).

### S3 design notes

- **Key layout:** `<prefix>/<sha[0:2]>/<sha[2:4]>/<sha>`. Matches
  the filesystem reference's sharded layout. `prefix` defaults to
  empty (object key is just the sha-sharded path).
- **Atomicity:** S3 PUT is atomic by nature (no temp + rename
  needed). Content-addressing dedup is achieved by `head_object`
  first; on 200, skip the upload.
- **Metadata:** Use S3 object metadata (`Metadata={...}` kwarg on
  PutObject; returned in HeadObject `Metadata` field). No
  separate sidecar object. Keys / values must be ASCII strings —
  validate at the adapter boundary.
- **Content type:** S3's `ContentType` header maps directly to
  `PayloadReference.content_type`.
- **Delete semantics:** S3 `DeleteObject` is idempotent (returns
  success for already-absent keys). To return Protocol-compliant
  `bool` (True if removed, False if absent), the adapter must
  `HeadObject` first.
- **Endpoint override:** Constructor takes optional
  `endpoint_url` so the same adapter works against MinIO /
  SeaweedFS / LocalStack.

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-verify the existing `payload_store` files match the
   prompt's "Existing surface". Flag any drift.
2. Decide the constructor signature for `S3PayloadStore`.
   Recommendation:
   ```python
   class S3PayloadStore(PayloadStore):
       def __init__(
           self,
           bucket: str,
           *,
           prefix: str = "",
           session: aioboto3.Session | None = None,
           endpoint_url: str | None = None,
           default_content_type: str = "application/octet-stream",
       ): ...
   ```
   The `session` parameter lets callers inject a pre-configured
   `aioboto3.Session` for auth; missing means a default session
   is constructed.
3. Decide the parametrization fixture shape for the compliance
   suite. Recommendation: a `payload_store` fixture that yields
   instances of each implementation, indirect-parametrized via
   `pytest.param(...)` with adapter names as ids. Use
   `pytest.fixture(params=...)` so each test runs N times, once
   per adapter.

### Phase B — implementation

4. **S3 adapter** — `noetl/core/payload_store/s3.py`:
   - `S3PayloadStore` implementing the Protocol.
   - `_key_for(sha)` builds the S3 object key with the same
     2-level / 2-char sharded shape as the filesystem reference.
   - `store(payload, ...)`:
     - Compute `content_hash`.
     - Validate metadata: all keys + values must be ASCII strings
       (raise `ValueError` otherwise).
     - `head_object(Bucket=..., Key=...)` — if 200, skip the put
       (dedup). Note: ETag is the MD5 by default; we trust the
       sha256 in the key for content-addressing.
     - Otherwise `put_object(..., Body=payload, ContentType=...,
       Metadata=...)`.
     - Return `PayloadReference` with
       `uri=f"s3://{bucket}/{key}"`.
   - `fetch(ref)`:
     - `get_object(Bucket=..., Key=...)`.
     - Read the `Body` stream.
     - On `ClientError` with `404` / `NoSuchKey`, raise
       `PayloadNotFound`.
   - `exists(ref)`:
     - `head_object`; True on 200, False on 404. Anything else
       re-raises.
   - `delete(ref)`:
     - `head_object` first to determine presence. If absent,
       return False.
     - `delete_object` to remove.
     - Return True.
   - All boto3 calls go through `aioboto3.Session.client("s3", ...)`
     context manager (proper resource cleanup).

5. **Re-exports** — `noetl/core/payload_store/__init__.py`:
   - Add `S3PayloadStore` to the imports + `__all__`.

6. **Dev dependency** — `pyproject.toml`:
   - Append `"moto[s3]>=5.0"` to `[project.optional-dependencies].dev`.
   - Install via `uv pip install -e ".[dev]"` (or whatever the
     project uses) so the test file can import `moto`.

### Phase C — tests

7. **Compliance suite** —
   `tests/core/payload_store/test_compliance.py`:
   - `@pytest.fixture(params=["filesystem", "s3"])` providing a
     `PayloadStore` instance.
   - For `filesystem` parameter: yield `FilesystemPayloadStore(tmp_path)`.
   - For `s3` parameter: yield a `S3PayloadStore` configured
     against a `moto.mock_aws()`-managed S3. The bucket is
     created via `boto3.client("s3", ...).create_bucket(...)`
     inside the mock context.
   - Tests (each parametrized across both adapters):
     - `test_store_and_fetch_round_trip`
     - `test_content_addressing_is_deterministic`
     - `test_fetch_missing_raises_payload_not_found`
     - `test_exists_reflects_state`
     - `test_delete_returns_false_when_missing`
     - `test_content_type_default`
     - `test_metadata_round_trip` (asserts metadata is preserved
       across `store -> fetch -> exists`; what "preserved" means
       differs between adapters — for fs it's the sidecar, for s3
       it's the response's `Metadata` field. Test asserts the
       `PayloadReference.metadata` returned by `store(...)` is
       returned by the adapter).

8. **S3-specific tests** —
   `tests/core/payload_store/test_s3.py`:
   - `test_key_layout_matches_filesystem_sharding` — key for sha
     `abcdef...` lands at `ab/cd/abcdef...`.
   - `test_prefix_is_respected` — adapter with `prefix="payloads/"`
     produces key `payloads/ab/cd/abcdef...`.
   - `test_dedup_skips_put_when_object_exists` — patch
     `put_object` to count calls; second `store` for same payload
     doesn't invoke it again.
   - `test_metadata_validation_rejects_non_ascii` — `store(...,
     metadata={"key": "vä lue"})` raises `ValueError`.
   - `test_uri_is_s3_scheme` — returned `PayloadReference.uri`
     starts with `s3://<bucket>/<prefix>`.
   - `test_missing_bucket_raises` — `S3PayloadStore` against a
     non-existent bucket; `store(...)` propagates the boto3
     `ClientError` (not silently no-op).

9. Run:
   ```
   pytest tests/core/payload_store/ -q
   pytest tests/core/payload_store/
          tests/core/test_projector_metrics.py
          tests/core/test_replay_state_projector.py
          tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
   ```
   All green.

### Phase D — wiki update

10. Update `repos/noetl-wiki/noetl/core/payload_store.md`:
    - Add a new "S3 adapter" subsection after "FilesystemPayloadStore".
    - Document constructor signature, key layout, custom metadata
      via S3 headers, MinIO / SeaweedFS / LocalStack via
      `endpoint_url`, dedup semantics, delete behavior.
    - Mention the compliance suite — same Protocol exercised
      against both adapters.

11. Commit + push wiki.

### Phase E — verify locally

12. Pytest covers the surface (moto provides a faithful S3
    mock). No kind / Postgres / real-AWS calls needed.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 5 s3`.***

13. Push branch `kadyapam/phase5-payload-store-s3`, open noetl PR
    titled `feat(payload-store): add S3 adapter + compliance suite`.
14. Wait for CI / human review.
15. Merge with `--admin --merge --delete-branch`.
16. Bump ai-meta pointers (noetl + noetl-wiki).

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 5 s3`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D wiki edit
  ships paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No migration of existing callers**, no GCS / Azure Blob /
  SeaweedFS adapters, no event-envelope binding in this round.
