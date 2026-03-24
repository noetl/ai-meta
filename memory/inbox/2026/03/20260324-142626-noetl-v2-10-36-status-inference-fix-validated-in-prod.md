# NoETL v2.10.36 status inference fix validated in prod
- Timestamp: 2026-03-24T14:26:26Z
- Author: Kadyapam
- Tags: noetl,status,prod,validation,v2.10.36,github:321,github:28

## Summary
Merged noetl/noetl#321, baked v2.10.36, and deployed via cybrnx/gcp-gitops-cybx#28. Direct validation against ready server-noetl v2.10.36 pod server-noetl-7c557b97fd-6cxjk showed execution 589375687589363999 still RUNNING at fetch_adt_records:task_sequence with /status now returning completion_inferred=false, completed=false, failed=false, end_time=null. This confirms the fallback status API no longer falsely marks active executions as inferred-complete.

## Actions
-

## Repos
-

## Related
-
