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
