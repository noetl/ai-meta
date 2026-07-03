# NoETL EHDB Helper Invocation Plan

## Tracking

- Issue: `noetl/noetl#672` — Add EHDB local-reference helper invocation plan
- PR: `noetl/noetl#673` — `feat: add EHDB helper invocation plan`
- NoETL merged SHA:
  `aa35becaecb53d00e44aff08b692d2468c75aa94`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added `LocalReferenceEhdbInvocation`, an immutable invocation plan for
  future EHDB local-reference helper calls.
- Added `NOETL_EHDB_HELPER_BIN`, required only when building an enabled
  helper invocation plan.
- Added `ehdb_helper_invocation_from_env`, which returns `None` when
  EHDB is disabled and otherwise produces deterministic `argv` plus
  EHDB runtime env for worker/playbook local-reference configs.
- Added subprocess env merging without executing anything.
- README now documents the helper invocation planning boundary.

## Boundary

- This is invocation planning only.
- It does not execute a subprocess, import Rust EHDB, open local logs,
  connect to EHDB, replace PostgreSQL/NATS/object stores, add gateway
  routes, add production storage behavior, or start persistent
  per-tenant services.
- Gateway/server roles remain rejected by the existing contract.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py` — 21 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 70 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py`
- `git diff --check README.md noetl/core/ehdb_adapter.py tests/core/test_ehdb_adapter.py`
