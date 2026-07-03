# NoETL EHDB Local Reference Adapter

## Tracking

- Issue: `noetl/noetl#670` — Add EHDB local-reference adapter factory
- PR: `noetl/noetl#671` — `feat: add EHDB local reference adapter`
- NoETL merged SHA:
  `d22edb5e8a997d8634dd6b40be02953c9ba92923`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added `noetl.core.ehdb_adapter`, a side-effect-free local-reference
  adapter descriptor behind the EHDB integration contract.
- Disabled EHDB configuration returns `None`.
- Worker/playbook `local_reference` configuration returns a
  `LocalReferenceEhdbAdapter` carrying the explicit event-log path and
  exportable runtime env for future EHDB helper calls.
- Gateway/server roles remain rejected by the contract.
- README now documents the adapter boundary next to the EHDB contract
  flags.

## Boundary

- This is adapter wiring only.
- It does not connect to EHDB, open local logs, replace PostgreSQL/NATS/
  object stores, add gateway routes, add production storage behavior, or
  start persistent per-tenant services.
- It preserves the NoETL execution model: gateway remains gatekeeper;
  workers/playbooks remain the only future data-touch surfaces.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 63 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py`
- `git diff --check README.md noetl/core/ehdb_adapter.py tests/core/test_ehdb_adapter.py`
