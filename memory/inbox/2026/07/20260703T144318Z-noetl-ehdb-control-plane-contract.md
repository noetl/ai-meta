# NoETL EHDB Control-Plane Contract

## Tracking

- Issue: `noetl/noetl#674` — Add EHDB embedded control-plane contract
- PR: `noetl/noetl#675` — `feat: add EHDB control-plane contract`
- NoETL merged SHA:
  `71a0a87fd3ffdca2e56e3dca14c0de078257f54d`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added explicit `NOETL_EHDB_MODE=control_plane`.
- Added `NOETL_EHDB_CAPABILITIES` and a NoETL-side capability contract
  mirroring the EHDB embedded role policy.
- Gateway/API/server roles are accepted only in `control_plane` mode
  with `control_plane` capability.
- Gateway/API/server local-reference or data-plane capability requests
  remain rejected.
- Worker/playbook/system local-reference configs keep explicit event-log
  requirements and data-plane capability modeling.
- Local-reference adapter/helper factories return `None` for
  control-plane mode.

## Boundary

- This is contract/modeling only.
- It does not connect to EHDB, import Rust EHDB, open local logs,
  execute helpers, add gateway routes, add storage behavior, or start
  persistent per-tenant services.
- It preserves the embedded-database direction without letting gateway
  or API roles touch EHDB data directly.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py` — 32 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 81 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py`
- `git diff --check README.md noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py`
- GitHub Actions `forbid-client-term`
