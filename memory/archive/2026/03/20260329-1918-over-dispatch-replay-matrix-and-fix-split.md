# Over-dispatch/replay tracking updated with tooling matrix repro

- Date: 2026-03-29 (America/Los_Angeles)
- Repos: `repos/noetl`, `ai-meta`
- Tracking issue updated: https://github.com/noetl/noetl/issues/345

## What was done

- Added live repro details to `noetl/noetl#345` for over-dispatch/replay using new fixture:
  - Playbook: `tests/fixtures/playbooks/load_test/tooling_non_blocking/tooling_non_blocking.yaml`
  - Execution: `593446259529089845`
  - Observed:
    - `run_http_probe`: issued=5, terminal=5
    - `run_postgres_probe`: issued=5, terminal=5
    - `run_duckdb_probe`: issued=12, terminal=8
  - Failure reason captured in workflow terminal events:
    - `run_duckdb_probe: expected issued_count=5, got 12`

- Kept runtime fix separate in engine for missing-index repair replay behavior:
  - `noetl/core/dsl/v2/engine.py`
  - Introduced age gating via `NOETL_TASKSEQ_LOOP_MISSING_MIN_AGE_SECONDS` (default `5`)
  - `_find_missing_loop_iteration_indices(...)` now joins `command.started` and requires minimum age on issued/started rows before reissue.

- Added targeted unit tests:
  - `tests/unit/dsl/v2/test_loop_parallel_dispatch.py`
    - `test_find_missing_loop_iteration_indices_applies_age_gating`
    - `test_find_missing_loop_iteration_indices_clamps_negative_age`

- Added/updated tooling non-blocking fixture coverage:
  - Core probes (default enabled): `http`, `postgres`, `duckdb`
  - Optional probes (workload flags): `snowflake`, `nats kv`, `nats object store`
  - Single analyzer step validates issued/terminal counts and parallel overlap from execution events.

- Registered fixture revisions in local cluster and executed multiple runs against `http://722-2.local:8082`.

## Validation

- Unit tests:
  - `./.venv/bin/pytest -q tests/unit/dsl/v2/test_loop_parallel_dispatch.py -k "find_missing_loop_iteration_indices_applies_age_gating or find_missing_loop_iteration_indices_clamps_negative_age"`
  - Result: `2 passed`

- DSL parse validation:
  - Loaded updated playbooks through `noetl.core.dsl.v2.models.Playbook` without parse errors.

- Runtime matrix execution:
  - Reproduced over-dispatch in currently deployed image (expected before redeploying engine fix).

## Next

1. Build/deploy image with updated `engine.py` age-gating fix.
2. Rerun `tooling_non_blocking` and confirm mandatory steps pass with:
   - `issued_count == 5`
   - `terminal_count == 5`
   - `max_parallel >= 2`
3. Enable optional probes and capture extended tooling report.
