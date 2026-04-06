# Analysis of test_pft_flow stall and NATS errors
- Timestamp: 2026-04-06T07:04:29Z
- Author: Kadyapam
- Tags: pft, nats, bug, performance, dsl

## Summary
Identified three root causes: 1) Colons in worker_id/execution_id causing NATS JetStream.InvalidKeyError. 2) Known v2.14.7 race bug where loop.done fires prematurely. 3) Server statement timeouts due to inefficient pending command aggregation SQL.

## Actions
-

## Repos
-

## Related
-
