# NoETL EHDB Integration Contract

Date: 2026-07-03 UTC

Issue:
- `noetl/noetl#668` — Add feature-flagged EHDB integration contract

Merged PR:
- `noetl/noetl#669` — `feat: add EHDB integration contract`

Pointer:
- `repos/noetl` should point at
  `4a8caeb7e587aa1d519ae6ee298b472c5c36594e`.

Summary:
- Added `noetl.core.ehdb_contract`, the first NoETL-side EHDB
  integration contract.
- EHDB remains disabled by default.
- `local_reference` mode is accepted only for worker/playbook roles
  when `NOETL_EHDB_LOCAL_REFERENCE_LOG` provides an explicit event-log
  path.
- Gateway/server roles are rejected when EHDB is enabled so gateway
  remains a gatekeeper and cannot touch EHDB data directly.
- README now documents the EHDB env flags and boundary.

Boundary:
- This is a contract/readiness slice only.
- It does not connect to EHDB, replace PostgreSQL/NATS/object stores,
  add a gateway route, start a persistent per-tenant process, or perform
  a kind/GKE rollout.

Validation:
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py` — 8 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py` — 57 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py`

