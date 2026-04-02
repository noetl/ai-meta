# NoETL PR271 finalize/dead-end completion fix
- Timestamp: 2026-03-18T02:56:32Z
- Author: Kadyapam
- Tags: noetl,execution,stuck,terminal-events,pr-271

## Summary
Tracked noetl/noetl PR 271. Fix addresses stuck RUNNING executions with missing terminal lifecycle by moving finalize_abandoned_execution into ControlFlowEngine and emitting terminal completion when next arcs do not match and no pending commands remain. Added regression tests in tests/unit/dsl/v2/test_task_sequence_loop_completion.py and validated with uv run pytest for that module.

## Actions
-

## Repos
-

## Related
-
