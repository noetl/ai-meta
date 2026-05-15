# Loop reconciliation queries optimized from 1410ms to 3ms
- Timestamp: 2026-04-14T04:52:09Z
- Author: Kadyapam
- Tags: database, engine, sql, index, performance

## Summary
Discovered that the engine was freezing due to O(N^2) JSON sequential scans in _count_loop_terminal_iterations and _find_missing_loop_iteration_indices when tracking progress. Added indexes (e.g., idx_event_loop_epoch_coalesce) to schema_ddl.sql and stripped COALESCE fallbacks in queries.py, dropping execution time to 3ms.

## Actions
-

## Repos
-

## Related
-
