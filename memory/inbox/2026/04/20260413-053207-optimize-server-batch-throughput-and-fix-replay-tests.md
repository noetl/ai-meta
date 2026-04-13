# Optimize server batch throughput and fix replay tests
- Timestamp: 2026-04-13T05:32:07Z
- Author: Kadyapam
- Tags: performance, batch, tests, worker, optimization

## Summary
Fixed replay/state-regression failures in store.py, tightened loop snapshot restore in rendering.py, relaxed continuation-time eager collection rendering in transitions.py, and updated tests. Optimized batch.py acceptors to serialize per execution, reducing lock contention. Shifted focus to per-loop-item worker pipeline optimization.

## Actions
-

## Repos
-

## Related
-
