# NoETL EHDB Control-Plane Descriptor

## Tracking

- Issue: `noetl/noetl#676` — Add EHDB control-plane embedding descriptor
- PR: `noetl/noetl#677` — `feat: add EHDB control-plane descriptor`
- NoETL merged SHA:
  `6254c44aff6982ca6b127dfa7610b5dc68283e1a`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added `noetl.core.ehdb_control_plane`.
- Added `ControlPlaneEhdbEmbedding`, a side-effect-free descriptor for
  gateway/API/server EHDB control-plane embedding.
- Added `ehdb_control_plane_from_env`.
- Disabled EHDB config returns `None`.
- Worker/playbook/system local-reference configs return `None` because
  they are data-plane paths handled by the adapter/helper contract.
- Gateway/API/server `control_plane` configs return a descriptor carrying
  role, `control_plane` capability, and exportable runtime env.
- README documents the planning-only descriptor.

## Boundary

- This is descriptor/modeling only.
- It does not connect to EHDB, import Rust EHDB, open local logs,
  execute helpers, add gateway routes, add storage behavior, or start
  persistent per-tenant services.
- It gives gateway/API/server an explicit embedded control-plane object
  without granting data-plane access.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py` — 41 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 90 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py noetl/core/ehdb_control_plane.py`
- `git diff --check README.md noetl/core/ehdb_control_plane.py tests/core/test_ehdb_control_plane.py`
- GitHub Actions `forbid-client-term`
