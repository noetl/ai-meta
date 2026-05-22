---
thread: 2026-05-22-phase5-payload-store-gcs
round: 1
from: claude
to: claude
created: 2026-05-22T22:55:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Result — Phase 5 round 3: GCS payload-store adapter — round 1

Phases A through D + PR open completed. Phase F (merge) blocked on
the prompt's wait phrase `merge phase 5 gcs`.

## Phase A — design + drift check (no remote writes)

- Verified `payload_store/{__init__.py,ports.py,s3.py,filesystem.py}`
  on `origin/main` are unchanged since the round 2 merge — no drift.
- Confirmed `google-cloud-storage` 3.2.0 is importable in the venv
  (`python -c "import google.cloud.storage; print(...)"`), already a
  runtime dep. No `uv pip install` needed.
- Confirmed `google.api_core.exceptions.NotFound` is the
  resolvable-at-runtime class for the GCS missing-blob signal.
- Decision: keep `_validate_metadata` independent of the S3 adapter
  for this round (per the prompt's Phase A recommendation). Will
  factor later if the contracts stabilize.

## Phase B — implementation

- Wrote `noetl/core/payload_store/gcs.py`:
  - `GCSPayloadStore` constructor accepts
    `bucket, *, prefix="", client=None, project=None,
    credentials=None, default_content_type="application/octet-stream"`.
  - When `client is None`, builds `storage.Client(project=...,
    credentials=...)` and caches `self.bucket = self.client.bucket(bucket)`.
  - `_key_for(sha)` returns `<prefix>/<sha[:2]>/<sha[2:4]>/<sha>`;
    leading/trailing slashes on `prefix` are stripped at construction.
  - `_uri_for(key)` returns `gs://<bucket>/<key>`.
  - `_validate_metadata` enforces ASCII keys + values; raises
    `ValueError` on non-ASCII (matches S3 adapter wording).
  - `_is_not_found(exc)` matches on `google.api_core.exceptions.NotFound`
    with a duck-typed fallback (status code `404`).
  - `_head_sync` / `_store_sync` / `_fetch_sync` / `_delete_sync`
    sync workers; async `store`/`fetch`/`exists`/`delete` bridge
    through `asyncio.to_thread`.
  - `_store_sync` writes `blob.metadata = metadata` then calls
    `blob.upload_from_string(payload, content_type=...)`. The
    `upload_from_string` call ships the metadata + content type in
    the same upload (no separate `patch()` round-trip is needed for
    new uploads).
  - `_fetch_sync` translates GCS `NotFound` into `PayloadNotFound`.
  - `_delete_sync` uses the canonical `exists` + `delete` pattern
    so the Protocol's `True`/`False` semantics hold.
- Updated `noetl/core/payload_store/__init__.py` to import and
  re-export `GCSPayloadStore`.
- Smoke import passes:
  `from noetl.core.payload_store import GCSPayloadStore` → class
  resolves.

## Phase C — tests

- Wrote `tests/core/payload_store/test_gcs.py` — 15 tests via
  `unittest.mock.MagicMock` stubbing the
  `Client.bucket(...) → Bucket; Bucket.blob(...) → Blob` chain.
  Coverage:
  - `test_constructor_uses_injected_client` — confirms no `Client()`
    constructor call when an explicit client is passed; the bucket
    is queried by name.
  - `test_constructor_rejects_empty_bucket` — `ValueError("bucket name")`.
  - `test_store_uploads_via_blob_with_metadata` — confirms
    `bucket.blob(<expected_key>)`, `blob.metadata = metadata`,
    `blob.upload_from_string(payload, content_type=...)` call shape;
    asserts returned `PayloadReference` fields.
  - `test_store_dedups_when_blob_exists` — `blob.exists()` returns
    `True`; `upload_from_string` is not called.
  - `test_fetch_raises_payload_not_found_on_gcs_404` —
    `download_as_bytes` raises `gax_exceptions.NotFound`, surface
    becomes `PayloadNotFound`.
  - `test_fetch_returns_blob_bytes` — happy-path round-trip.
  - `test_exists_passes_through_blob_exists[True/False]` —
    parametrized.
  - `test_delete_returns_false_on_missing_blob` —
    `blob.delete()` is not called.
  - `test_delete_returns_true_on_existing_blob` — `blob.delete()`
    called exactly once.
  - `test_key_layout_matches_filesystem_sharding` — same
    `<sha[:2]>/<sha[2:4]>/<sha>` shape as filesystem + S3.
  - `test_prefix_normalization` — `/payloads/` → `payloads`
    (leading + trailing slash stripped).
  - `test_uri_is_gs_scheme` — `gs://<bucket>/`.
  - `test_metadata_validation_rejects_non_ascii` — `ValueError`
    with `match="ASCII"`.
  - `test_missing_bucket_propagates_error` —
    `upload_from_string` raising `NotFound("bucket does not exist")`
    propagates instead of being caught.

- Local pytest results:

  ```
  $ pytest tests/core/payload_store/test_gcs.py -q
  15 passed in 1.02s

  $ pytest tests/core/payload_store/ -q
  51 passed in 2.30s

  $ pytest tests/core/payload_store/
           tests/core/test_projector_metrics.py
           tests/core/test_replay_state_projector.py
           tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
  103 passed, 33 warnings in 5.44s
  ```

  (The 33 warnings are pre-existing Pydantic v2 deprecation
  notices from `test_projector_metrics.py` — not introduced by
  this round.)

## Phase D — wiki update

- Updated `repos/noetl-wiki/noetl/core/payload_store.md`:
  - Status section now lists both `S3PayloadStore` and
    `GCSPayloadStore` as cloud adapters; phase line says
    "Rounds 1–3 complete".
  - New `## GCSPayloadStore` section between `## S3PayloadStore`
    and `## Compliance suite`. Covers construction (project /
    credentials / injected client), key layout, metadata
    semantics, dedup via `Blob.exists`, atomicity, Protocol-
    compliant delete via `exists + delete`, sync-SDK + thread
    bridging rationale, full configuration table.
  - `## Compliance suite` section now notes the GCS leg is
    deferred pending an in-process emulator, and points at
    `test_gcs.py` for the unit-test coverage in the meantime.
  - "Where this fits" diagram updated to list S3 + GCS as
    cloud adapters.
- Wiki commit: `wiki(payload_store): document GCS adapter`
  (`noetl.wiki@f064e57`). Pushed to `origin/master`.

## Phase E — verify locally

- Pytest is the only required gate this round (no emulator
  / kind / real-GCS). Already green; see Phase C numbers.

## Phase F — open PR and merge

- Branch `kadyapam/phase5-payload-store-gcs` pushed.
- PR opened: **noetl#590** "feat(payload-store): add GCS adapter"
  — https://github.com/noetl/noetl/pull/590
- Body lists summary, design notes, compliance-suite note,
  test plan, paired wiki commit pointer, and round-4 follow-ups.

**Merge step blocked: awaiting `merge phase 5 gcs`.** No
`gh pr merge` run. The prompt's hard rules forbid pushing to
`origin/main` or merging the PR until the human says the wait
phrase.

## Issues observed

- None. The aioboto3-vs-moto trap from round 2 did not recur
  because the prompt locked in the sync-SDK + `asyncio.to_thread`
  pattern up front and the GCS SDK has no async variant to be
  tempted by.
- Minor: the prompt's test sketch suggested `blob.metadata = ...`
  followed by `blob.patch()`. In the GCS SDK, custom metadata is
  uploaded in the same request as `upload_from_string` when the
  blob doesn't yet exist, so the implementation skips the
  separate `patch()` call. The corresponding test
  (`test_store_uploads_via_blob_with_metadata`) asserts the
  observed call shape instead. No correctness impact —
  `Blob.metadata` is still set before `upload_from_string` runs.

## Manual escalation needed

To complete Phase F, the human (or a subsequent agent acting
on their go-ahead) must:

1. Confirm CI passes on noetl#590.
2. Say the wait phrase `merge phase 5 gcs`.
3. Then the executor runs:

   ```
   gh pr merge 590 --admin --merge --delete-branch
   git -C repos/noetl fetch origin
   git -C repos/noetl checkout main && git -C repos/noetl pull origin main
   git -C repos/noetl-wiki pull origin master    # already at f064e57
   git -C /Volumes/X10/projects/noetl/ai-meta add repos/noetl repos/noetl-wiki
   git -C /Volumes/X10/projects/noetl/ai-meta commit -m "chore(sync): bump noetl + noetl-wiki for phase5 GCS adapter"
   git -C /Volumes/X10/projects/noetl/ai-meta push origin main
   ```
4. Archive the handoff thread under `handoffs/archive/`.
5. Drop a `memory_add.sh` entry summarizing the round.
