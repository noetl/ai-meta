# NoETL EHDB Helper Execution Wrapper

## Tracking

- Issue: `noetl/noetl#680` — Add bounded EHDB helper execution wrapper
- PR: `noetl/noetl#681` — `feat: execute EHDB local helper summaries`
- NoETL merged SHA:
  `8851356445a5e10b954d95a77d35c10b804ee380`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added `ehdb_local_reference_summary_invocation_from_env` for the
  concrete `ehdb-local-reference summary --log <path>` command.
- Added `execute_ehdb_helper_json`, a bounded subprocess runner that
  uses no shell, captures stdout/stderr, enforces a timeout, rejects
  non-zero exit codes, and decodes a JSON object.
- Added `execute_ehdb_local_reference_summary_from_env` for the
  configured summary helper path.
- Added tests using temporary helper scripts for successful JSON,
  disabled config, gateway rejection, non-zero exit, timeout, and
  non-object JSON.
- README now documents the helper execution boundary.

## Boundary

- This is worker/playbook local helper execution only.
- It does not import Rust EHDB, open storage directly from
  gateway/API/server roles, add routes, replace PostgreSQL/NATS/object
  stores, or start persistent per-tenant processes.
- It preserves the NoETL execution model: gateway/API/server remain
  control-plane-only for EHDB, while worker/playbook local-reference
  contexts can execute bounded helper commands.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_ehdb_surface.py` — 53 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_ehdb_surface.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 102 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py noetl/core/ehdb_control_plane.py noetl/core/ehdb_surface.py`
- `git diff --check README.md noetl/core/ehdb_adapter.py tests/core/test_ehdb_adapter.py`
- local `forbid-client-term` added-line check
- GitHub Actions `forbid-client-term` passed
