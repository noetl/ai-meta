# state-refactor-pushed-and-rerun-request
- Timestamp: 2026-04-18T16:49:02Z
- Author: Kadyapam
- Tags: noetl,performance,state,cache,execution-status,rerun

## Summary
NoETL pushed at d2e2b279 and ai-meta at ad76b5a. State refactor stores compact step refs/context row_count only, avoids mirroring full step results and emitted_loop_epochs in execution.state, and resolves rows on demand via TaskResultProxy/TempStore shared cache. Triggered new cycle: prior execution 607458339856843442 ended FAILED per /api/executions while noetl execute status may still report RUNNING.

## Actions
-

## Repos
-

## Related
-
