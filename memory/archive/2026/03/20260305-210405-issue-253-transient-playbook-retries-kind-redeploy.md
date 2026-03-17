# Issue 253 transient playbook retries + kind redeploy
- Timestamp: 2026-03-05T21:04:05Z
- Author: Kadyapam
- Tags: noetl,worker,retry,ops,kind,issue-253

## Summary
Implemented transient HTTP retry logic (ReadError, RemoteProtocolError, ConnectError) in noetl worker sub-playbook execution path for spawn and status polling; added worker tests; committed in repos/noetl at 6fbf00ef; redeployed to local kind via repos/ops noetl playbook (runtime local, action=redeploy); cluster now running local/noetl:2026-03-05-12-58 with noetl-server 1/1 and noetl-worker 3/3 ready.

## Actions
- Updated `repos/noetl/noetl/worker/v2_worker_nats.py` to retry transient `httpx` network errors in `_execute_playbook` for both spawn and status polling paths.
- Added tests in `repos/noetl/tests/worker/test_v2_worker_playbook_tool.py` for transient retry behavior on spawn and polling.
- Built and redeployed NoETL locally via `repos/ops/automation/development/noetl.yaml` with runtime `local` and action `redeploy`.
- Updated GitHub issue tracking progress and completion checkpoints.

## Repos
- `noetl/noetl` commit `6fbf00ef`
- `noetl/ai-meta` commit `0c0b93f` (submodule pointer bump)

## Related
- Issue: `https://github.com/noetl/noetl/issues/253`
- Last update comment: `https://github.com/noetl/noetl/issues/253#issuecomment-4007781087`
