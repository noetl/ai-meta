# DSL Loop Replay Fix + Runtime Validation (PR #354)

Date: 2026-03-29
Scope: repos/noetl distributed runtime loop replay / tooling_non_blocking fixture

## What was fixed
- Opened PR: https://github.com/noetl/noetl/pull/354
- Branch: `kadyapam/loop-missing-bind-params`
- Commits:
  - `92b5de4c` fix(dsl): bind all loop-missing query params
  - `41021a8f` fix(dsl): stop false loop-orphan replay on started events

### Root cause
Loop orphan/missing detection queries relied on `meta.command_id` for `command.started` rows.
In runtime events, started command IDs are often stored in `result.context.command_id`.
This made started rows invisible and caused false tail-repair reissues (over-dispatch).

### Code changes
- `noetl/core/dsl/v2/engine.py`
  - `_find_missing_loop_iteration_indices`:
    - fixed SQL bind arity (terminal CTE params)
    - command_id extraction now uses coalesce across:
      - `meta->>'command_id'`
      - `result->'context'->>'command_id'`
      - `context->>'command_id'`
    - terminal detection now includes `call.done`
  - `_find_orphaned_loop_iteration_indices`:
    - same command_id extraction fix
    - terminal detection includes `call.done`
- `tests/unit/dsl/v2/test_loop_parallel_dispatch.py`
  - regression assertions for bind arity + query shape

## Validation
### Unit
- `uv run pytest -q tests/unit/dsl/v2/test_loop_parallel_dispatch.py`
- Result: 20 passed

### Distributed runtime (kind)
- Playbook: `tests/fixtures/playbooks/load_test/tooling_non_blocking`
- Execution: `593562221490209366`
- Status: `COMPLETED`

Mandatory probe metrics (from `analyze_matrix` and SQL checks):
- `run_http_probe`: issued=5, terminal=5, max_parallel=5
- `run_postgres_probe`: issued=5, terminal=5, max_parallel=5
- `run_duckdb_probe`: issued=5, terminal=5, max_parallel=6
- DuckDB per-index issued counts: loop indexes 0..4 each issued exactly once

This confirms replay over-dispatch symptom is fixed (previous failing run had duckdb issued=14 vs expected 5).

## Remaining follow-up (separate)
- Issue created: https://github.com/noetl/noetl/issues/355
- Topic: worker OOM/restart noise during duckdb-heavy probe in kind (operational tuning track)
- Rationale: execution correctness is restored, but OOM restarts still inflate started_count/window duration under stress.
