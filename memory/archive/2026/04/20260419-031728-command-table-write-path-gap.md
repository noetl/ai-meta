# Command table write-path gap
- Timestamp: 2026-04-19T03:17:28Z
- Author: Kadyapam
- Tags: noetl,command-table,debug,api

## Summary
Validated that command-table projection stayed empty because execute/batch issuance paths bypassed dual-write and claim/batch lifecycle paths skipped projection updates. Fixed write + lifecycle updates in server API paths and verified live counts transitioned from PENDING-only to CLAIMED/STARTED/COMPLETED.

## Actions
-

## Repos
-

## Related
-
