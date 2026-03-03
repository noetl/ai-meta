# noetl/noetl issue #244

- Date: 2026-03-03
- Repo: `noetl/noetl`
- Issue: https://github.com/noetl/noetl/issues/244
- Title: Distributed loop lease expiry causes duplicate child executions and parent failure

## Problem summary

In Python NoETL distributed execution, looped child dispatch with a large `render_context` can exceed the NATS consumer lease (`120s`). This leads to reclaim and duplicate child executions, followed by parent execution failure.

## Repro assets

- https://github.com/noetl/noetl/tree/test_lease_expiry/tests/fixtures/playbooks/batch_execution/kind_playbook_lease_expiry
- https://github.com/noetl/noetl/tree/test_lease_expiry/tests/fixtures/playbooks/batch_execution/kind_playbook_lease_expiry_worker

## Requested direction

- Keep lease valid while dispatch is still in-flight.
- Improve idempotency around child creation to prevent duplicate execution on reclaim.

## Implementation progress

- Work branch: `codex/issue-244-lease-expiry`
- Fix commit: `b8b699b6`
- PR candidate: https://github.com/noetl/noetl/pull/new/codex/issue-244-lease-expiry
- Issue progress comment:
  - https://github.com/noetl/noetl/issues/244#issuecomment-3993520440

### Patch summary

- Added policy module: `noetl/claim_policy.py`
- Updated `noetl/server/api/v2.py` claim behavior:
  - healthy worker + fresh heartbeat no longer reclaimed immediately after soft lease expiry
  - hard reclaim timeout added via `NOETL_COMMAND_CLAIM_HEALTHY_WORKER_HARD_TIMEOUT_SECONDS` (default `1800`)
- Added unit tests: `tests/api/test_claim_policy.py`
