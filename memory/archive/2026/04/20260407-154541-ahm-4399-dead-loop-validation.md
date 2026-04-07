# AHM-4399 Dead Loop Validation
- Timestamp: 2026-04-07T15:45:41Z
- Author: Kadyapam
- Tags: pft, bug-fix, engine, nats, AHM-4399

## Summary
Validated dead-loop detection. Fixed a bug where distributed NATS KV state cache did not retain failed_count and break_count, resetting the stall detection on every loop boundary. Pushed the NATS synchronization patch to engine.py in noetl.

## Actions
-

## Repos
-

## Related
-
