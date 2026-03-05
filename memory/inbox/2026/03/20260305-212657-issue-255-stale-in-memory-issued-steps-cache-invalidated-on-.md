# Issue 255 stale in-memory issued_steps cache invalidated on command commit failure
- Timestamp: 2026-03-05T21:26:57Z
- Author: Kadyapam
- Tags: noetl,cache,issued_steps,retry,resilience,issue-255,ops,kind

## Summary
Implemented fix in repos/noetl commit 2c7bf669: added StateStore.invalidate_state and wired cache invalidation when command issuance fails after engine.handle_event in both /api/events and async batch processing path; added tests in tests/api/test_v2_batch_async.py (5 passed). Redeployed to local kind via repos/ops playbook (runtime local, action=redeploy). Cluster now running local/noetl:2026-03-05-13-22 with noetl-server 1/1 and noetl-worker 3/3 ready.

## Actions
- Added `StateStore.invalidate_state(execution_id, reason)` in `repos/noetl/noetl/core/dsl/v2/engine.py`.
- Added best-effort state cache invalidation in `repos/noetl/noetl/server/api/v2.py` when command issuance fails after `engine.handle_event` in both `/api/events` and async batch processing paths.
- Added regression tests in `repos/noetl/tests/api/test_v2_batch_async.py` for single-event and batch invalidation on command issuance failure.
- Redeployed local kind cluster via `repos/ops/automation/development/noetl.yaml` with runtime `local` and action `redeploy`.

## Repos
- `noetl/noetl` commit `2c7bf669`
- `noetl/noetl` PR `https://github.com/noetl/noetl/pull/256`

## Related
- Issue: `https://github.com/noetl/noetl/issues/255`
