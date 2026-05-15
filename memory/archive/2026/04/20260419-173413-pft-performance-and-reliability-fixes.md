# pft performance and reliability fixes
- Timestamp: 2026-04-19T17:34:13Z
- Author: Kadyapam
- Tags: noetl,perf,pft,postgres

## Summary
Applied performance and reliability fixes to repos/noetl for test_pft_flow regression. Bumped claim_batch_size 100->200 to reduce orchestration overhead. Switched from shared-table TRUNCATE to facility-scoped DELETE in setup_facility_work to enable future parallel dispatch without table-level locking. Patched server event handlers to prevent out-of-order lifecycle events from downgrading command-table status from terminal states. Added unit test for template rendering fast-path optimization. Pushed to repos/noetl master.

## Actions
-

## Repos
-

## Related
-
