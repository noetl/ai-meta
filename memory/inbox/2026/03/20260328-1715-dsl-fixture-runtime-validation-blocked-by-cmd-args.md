# DSL fixture runtime validation blocked by server `cmd.args` regression

- Timestamp: 2026-03-28 (America/Los_Angeles)
- Context: Continued DSL fixture refactor validation after noetl/noetl PR #347 merge.

## What was validated

1. Local kind redeploy completed via ops playbook (image `local/noetl:2026-03-28-09-59`).
2. All fixture playbooks registered successfully:
   - Command: `./tests/fixtures/register_test_playbooks.sh localhost 8082`
   - Result: 139/139 loaded.
3. Fixture migration integrity checks:
   - No residual legacy keys in fixtures (`args`, `set_ctx`, `set_iter`, `{{ ... outcome ... }}` scans empty).
   - Local parser/plan validation: `noetl exec <fixture> -r local --dry-run` passed 139/139.

## Blocking issue in distributed runtime

- API execute calls fail immediately, including basic playbooks:
  - Example request path: `tests/fixtures/playbooks/hello_world`
  - Response: `{"detail":"'Command' object has no attribute 'args'"}`
- Server traceback (noetl/server/api/v2.py) shows command context build still reads `cmd.args`.
- Because command emission fails at `/api/execute`, full distributed regression execution cannot currently proceed.

## Repro

- `curl -sS -X POST http://localhost:8082/api/execute -H 'Content-Type: application/json' -d '{"path":"tests/fixtures/playbooks/hello_world","payload":{}}'`
- Returns: `{"detail":"'Command' object has no attribute 'args'"}`

## Next handoff

- Resolve server-side command context compatibility for DSL v2 rename (`args` -> `input`) in runtime path, then rerun:
  - `tests/fixtures/playbooks/regression_test/master_regression_test_parallel`
- Keep fixture YAML changes as-is; current evidence indicates migration itself is structurally valid.
