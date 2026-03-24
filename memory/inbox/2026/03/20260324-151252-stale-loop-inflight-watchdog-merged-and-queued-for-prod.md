# stale loop inflight watchdog merged and queued for prod
- Timestamp: 2026-03-24T15:12:52Z
- Author: Kadyapam
- Tags: noetl,loop-watchdog,adt,prod,execution-status

## Summary
Merged noetl/noetl#323 after tracing execution 589375687589363999 pausing in fetch_adt_records:task_sequence after call.done. The fix broadens loop watchdog recovery for stale ghost in-flight saturation, baked as v2.10.37, with prod deploy PR cybrnx/gcp-gitops-cybx#29 open.

## Actions
-

## Repos
-

## Related
-
