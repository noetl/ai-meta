# NoETL premature completion regression on repeated batch loop work
- Timestamp: 2026-03-22T22:27:09Z
- Author: Kadyapam
- Tags: noetl,status,execution,regression,prod,github-issue,jira,pr293

## Summary
Prod validation after `v2.10.19` showed execution `588463546770392019` could flip to `COMPLETED` while repeated `events.batch` loop work was still active. Root cause was pending-work inference subtracting by `node_name` instead of unique `command_id`, which collapses repeated loop iterations that reuse the same step names. PR `#293` switches both execution endpoints to command-id based pending tracking and adds regressions.

## Actions
- Captured production reproduction from `bhs/state_report_generation_prod_v10` where active batch work continued after both execution endpoints inferred completion.
- Cancelled the unstable execution tree before patching so the false terminal state would not confuse follow-up validation.
- Opened PR `noetl/noetl#293`, linked it to issue `#292`, and added a Jira comment on `AHM-4330` with the root cause and test command.

## Repos
- `repos/noetl`

## Related
- noetl/noetl#292
- noetl/noetl#293
- AHM-4330
- execution `588463546770392019`
