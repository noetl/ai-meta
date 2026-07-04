# NoETL EHDB Integration Surface Selector

## Tracking

- Issue: `noetl/noetl#678` — Add EHDB integration surface selector
- PR: `noetl/noetl#679` — `feat: add EHDB surface selector`
- NoETL merged SHA:
  `a35316aa1e40d5a675213ffd7498c4870c1a212a`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added `noetl.core.ehdb_surface`.
- Added `EhdbIntegrationSurface`, a unified wrapper over either
  `ControlPlaneEhdbEmbedding` or `LocalReferenceEhdbAdapter`.
- Added `ehdb_surface_from_env`.
- Disabled EHDB config returns `None`.
- Gateway/API/server `control_plane` configs select the control-plane
  descriptor.
- Worker/playbook/system `local_reference` configs select the
  local-reference adapter.
- The selected surface exposes role, mode, capabilities, and runtime env.

## Boundary

- This is selection/modeling only.
- It does not connect to EHDB, import Rust EHDB, open local logs,
  execute helpers, add gateway routes, add storage behavior, or start
  persistent per-tenant services.
- It preserves the NoETL boundary: gateway/API/server select only the
  control-plane descriptor; data-plane configs select only worker-side
  surfaces accepted by the contract.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_ehdb_surface.py` — 46 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_ehdb_surface.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 95 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_surface.py` — 5 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py noetl/core/ehdb_control_plane.py noetl/core/ehdb_surface.py`
- `git diff --check README.md noetl/core/ehdb_surface.py tests/core/test_ehdb_surface.py`
- GitHub Actions `forbid-client-term`
