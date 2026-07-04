# NoETL EHDB Helper Discovery And Summary Smoke

## Tracking

- Issue: `noetl/noetl#682` — Add EHDB helper discovery and local summary smoke
- PR: `noetl/noetl#683` — `feat: discover EHDB helper for summary smoke`
- NoETL merged SHA:
  `363c3d4b0eb24b3b47c3b4e621ac72db26864328`
- `ai-meta` submodule to pin: `repos/noetl`

## Summary

- Added `discover_ehdb_helper_executable`.
- Discovery order:
  1. explicit `NOETL_EHDB_HELPER_BIN`
  2. `ehdb-local-reference` on `PATH`
  3. standard runtime/image paths:
     `/usr/local/bin/ehdb-local-reference` and
     `/opt/noetl/bin/ehdb-local-reference`
  4. ai-meta sibling EHDB build outputs:
     `../ehdb/target/{release,debug}/ehdb-local-reference`
- `ehdb_local_reference_summary_invocation_from_env` now uses discovery
  for the concrete `summary --log <path>` command.
- Added `scripts/smoke_ehdb_local_reference_summary.py` to run the
  summary helper and validate the returned JSON shape.
- README and `docker/noetl/README.md` now document the helper placement
  contract for runtime images and local ai-meta workspaces.

## Boundary

- This is helper discovery and local smoke only.
- It does not import Rust EHDB, add gateway routes, open storage from
  gateway/API/server roles, replace PostgreSQL/NATS/object stores, or
  start persistent per-tenant processes.
- Gateway/API/server local-reference execution remains rejected by the
  existing NoETL EHDB contract.

## Validation

- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_ehdb_surface.py tests/scripts/test_smoke_ehdb_local_reference_summary.py` — 60 tests
- `.venv/bin/python -m pytest tests/core/test_ehdb_contract.py tests/core/test_ehdb_adapter.py tests/core/test_ehdb_control_plane.py tests/core/test_ehdb_surface.py tests/core/test_runtime_topology.py tests/core/runtime/test_pool_routing.py tests/scripts/test_smoke_ehdb_local_reference_summary.py` — 109 tests
- `.venv/bin/python -m compileall -q noetl/core/ehdb_contract.py noetl/core/ehdb_adapter.py noetl/core/ehdb_control_plane.py noetl/core/ehdb_surface.py scripts/smoke_ehdb_local_reference_summary.py`
- `git diff --check README.md docker/noetl/README.md noetl/core/ehdb_adapter.py scripts/smoke_ehdb_local_reference_summary.py tests/core/test_ehdb_adapter.py tests/scripts/test_smoke_ehdb_local_reference_summary.py`
- local `forbid-client-term` added-line check
- `cargo build -p ehdb-reference --bin ehdb-local-reference` in sibling `repos/ehdb`
- `.venv/bin/python scripts/smoke_ehdb_local_reference_summary.py --helper-bin ../ehdb/target/debug/ehdb-local-reference --log <tmp-jsonl>`
- `.venv/bin/python scripts/smoke_ehdb_local_reference_summary.py --log <tmp-jsonl>` with sibling helper auto-discovery
- GitHub Actions `forbid-client-term` passed
