# NoETL v2.10.27 multi-server prod validation and loop warning follow-up
- Timestamp: 2026-03-23T09:36:06Z
- Author: Kadyapam
- Tags: noetl,prod,validation,multi-server,loop-warnings

## Summary
Validated NoETL v2.10.27 in bhs-analytics-prod with 2 server pods and 2 worker pods. Successful executions 588802849253883979 and 588804845457375566 confirmed stale cross-pod execution cache invalidation works from persisted events. Opened noetl/noetl#303 to track residual out-of-range claimed-index loop warnings during successful fetch_medications runs.

## Actions
-

## Repos
-

## Related
-
