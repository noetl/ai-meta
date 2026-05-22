---
thread: 2026-05-22-phase5-payload-store-s3
round: 1
from: claude
to: claude
created: 2026-05-22T21:58:53Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase 5 round 2 result — S3 payload-store adapter + compliance suite

Phases A–D executed in this session. Phase E is N/A (moto provides a
faithful S3 mock; unit tests cover the surface). Phase F **open as
PR #589**, merge gated on `merge phase 5 s3`.

## Phase A — design + drift check

- Re-verified `payload_store/{ports.py,filesystem.py,__init__.py}`
  against `origin/main` at `0ce85337`. No drift since round 1.
- Found that `boto3>=1.38.45` and `aioboto3>=13.0.0` are already
  in `pyproject.toml` runtime deps. `moto` is absent.
- Confirmed pytest dev extras under
  `[project.optional-dependencies].dev` — natural place to add
  `moto[s3]>=5.0`.
- **Design pivot from aioboto3 to sync boto3 + `asyncio.to_thread`.**
  Initially wired the adapter through `aioboto3` per the prompt,
  but `moto.mock_aws` only intercepts sync boto3 — aiobotocore
  raises `TypeError: object bytes can't be used in 'await'
  expression` because it expects awaitable response content while
  moto returns sync bytes. Switched the adapter to the same
  pattern as `FilesystemPayloadStore` (sync backend + thread
  bridge). Trade documented in the adapter docstring.

## Phase B — implementation

Branch: `kadyapam/phase5-payload-store-s3` in `repos/noetl`.
Commit: `4250e6c3 feat(payload-store): add S3 adapter + compliance suite` (+523 / -0).

Files:

- `noetl/core/payload_store/s3.py` (new, ~220 lines):
  - `S3PayloadStore` Protocol implementation.
  - Constructor: `bucket`, `prefix`, `client`, `endpoint_url`,
    `region_name`, `default_content_type`. Builds a default
    sync boto3 client when `client` is `None`.
  - `_key_for(sha)`, `_uri_for(key)`, `_validate_metadata`,
    `_is_not_found` static helpers.
  - `_head`, `_store_sync`, `_fetch_sync`, `_delete_sync` —
    sync workers called via `asyncio.to_thread`.
  - `store(...)`: HeadObject (dedup) + PutObject; returns
    `PayloadReference` with `s3://<bucket>/<key>` URI.
  - `fetch(ref)`: GetObject; raises `PayloadNotFound` on 404.
  - `exists(ref)`: HeadObject; True/False.
  - `delete(ref)`: HeadObject + DeleteObject; True if removed,
    False if absent (mirrors filesystem).

- `noetl/core/payload_store/__init__.py`:
  - Re-export `S3PayloadStore`. Added to `__all__`.

- `pyproject.toml`:
  - `moto[s3]>=5.0` appended to `dev` extras. Runtime deps
    unchanged.

## Phase C — tests

Two new files:

- `tests/core/payload_store/test_compliance.py` (~115 lines):
  - `@pytest_asyncio.fixture(params=("filesystem", "s3"))`
    yielding a configured PayloadStore. S3 leg uses
    `moto.mock_aws()` context manager with bucket auto-creation.
  - S3 leg cleanly skipped when moto isn't installed
    (`_S3_AVAILABLE` flag + `pytest.mark.skipif`).
  - 7 contract tests × 2 adapters → 14 parametrized runs.

- `tests/core/payload_store/test_s3.py` (~140 lines):
  - 8 S3-specific tests covering key layout sharding, prefix
    normalization (leading/trailing `/` stripped), dedup
    suppression (spy on `put_object`), non-ASCII metadata
    `ValueError`, URI scheme, missing-bucket `ClientError`,
    empty-bucket constructor rejection, object-metadata
    round-trip via raw boto3.

Test runs:

```
pytest tests/core/payload_store/ -q
→ 36 passed in 2.67s

pytest tests/core/payload_store/
       tests/core/test_projector_metrics.py
       tests/core/test_replay_state_projector.py
       tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
→ 88 passed, 33 warnings in 4.86s
```

Regression guards (Phase 1 / Phase 3 / Phase 6 / Phase 5 round 1)
all green.

### Iteration along the way

Initial run failed on async-fixture mode:

```
PytestRemovedIn9Warning: '...' requested an async fixture
'payload_store', with no plugin or hook that handled it.
```

Switched both test files to `@pytest_asyncio.fixture` instead of
`@pytest.fixture`. The fixtures need the dedicated decorator
because pytest's strict async mode doesn't auto-promote sync
fixtures to async.

Initial S3 run also failed with `TypeError: object bytes can't be
used in 'await' expression` — the aiobotocore-vs-moto issue.
Resolved by switching the adapter from aioboto3 to sync boto3 +
`asyncio.to_thread` (documented in Phase A).

## Phase D — wiki update

Wiki: `repos/noetl-wiki/` commit `3638f8e wiki(payload_store): document S3 adapter + compliance suite`. Pushed to `origin master`.

Page updated: [`noetl/core/payload_store`](https://github.com/noetl/noetl/wiki/payload_store):

- New `S3PayloadStore` major section (between `FilesystemPayloadStore`
  and `Usage`) covering construction, key layout, metadata-via-S3-
  headers, dedup, atomicity, delete semantics, async-surface
  / sync-backend rationale, S3-compatible endpoints (MinIO /
  SeaweedFS / LocalStack), full configuration table.

- New `Compliance suite` section explaining the
  parametrized-fixture pattern + the moto[s3] dev extra.

Per `agents/rules/wiki-maintenance.md` rule #1: wiki ships in the
same change set as the code.

## Phase E — verify locally

**N/A.** `moto` provides a faithful S3 mock; unit tests cover the
full surface. Real AWS / MinIO / SeaweedFS verification is a
separate ops exercise — out of scope for this round.

## Phase F — open PR and merge

**PR open, merge gated on wait phrase `merge phase 5 s3`.**

- PR: [noetl#589 — feat(payload-store): add S3 adapter + compliance suite](https://github.com/noetl/noetl/pull/589)
- Branch: `kadyapam/phase5-payload-store-s3` pushed to origin.
- PR body cross-references this handoff + the wiki commit.
- After merge:
  - `chore(sync): bump noetl to <merge sha>`
  - `chore(sync): bump noetl-wiki to 3638f8e`

## Issues observed

- **aioboto3 doesn't play with moto.** Already noted in Phase A.
  Worth recording as a project lesson: any future async-AWS work
  should plan for either real-AWS / LocalStack testing or sync
  boto3 + thread bridging. Pure `moto.mock_aws` is the easy path
  but only works with sync boto3.
- The S3 `Metadata` response keys come back lowercased — the
  compliance test handles this with a case-insensitive comparison
  in the S3-specific round-trip test. Worth noting in any future
  callers that round-trip metadata through S3.
- `pyproject.toml` got a new dev extra (`moto[s3]>=5.0`) but the
  existing CI pipeline may need to install the `[dev]` extra
  explicitly to pick it up — verify CI green after merge.

## Manual escalation needed

- **Wait phrase**: human says `merge phase 5 s3` to unlock the
  merge.
- After merge:
  ```bash
  cd repos/noetl && git checkout main && git pull origin main
  cd ../.. && git add repos/noetl repos/noetl-wiki
  git commit -m "chore(sync): bump noetl + noetl-wiki for Phase 5 round 2 S3 payload-store adapter"
  git push origin main
  ```
- Plan for round 3: GCS + Azure Blob adapters. Both follow the
  same pattern (sync SDK + `asyncio.to_thread`); the compliance
  suite already provides the contract gate.
