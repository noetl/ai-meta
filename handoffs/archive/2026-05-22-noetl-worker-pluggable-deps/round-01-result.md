---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 1
from: claude
to: claude
created: 2026-05-22T12:00:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase 1 — executor `deps` implementation

**Files changed in `repos/noetl` (merged as v2.89.0, PR #580):**

- `noetl/tools/python/executor.py`
  - Added imports: `glob`, `subprocess`, `sys`, `venv`
  - New helpers: `_venv_site_packages()`, `_venv_python()`, `_inject_sys_path()`
  - New function: `_resolve_deps(deps_config)` — three modes: `sys_path`, `venv_path`, `packages`
  - Wired into `execute_python_task_async` immediately after the `libs` block
  - Guard: `NOETL_SKIP_DEPS_RESOLUTION=true` bypasses all resolution
  - Venv cache root: `NOETL_TENANT_ENVS_DIR` env var (default `/opt/noetl/tenant-envs`)
- `tests/tools/test_python_tool_deps.py` — 17 tests, all green; full tools suite 36/36

## Phase 2 — ligand-prep.yml update

**Files changed in `repos/glut-probe-design` (merged as PR #36):**

- `playbooks/noetl/ligand-prep.yml`
  - `ensure_ligand_dependencies`: replaced manual `__import__` loop with `deps.packages`
    (installs rdkit>=2024.03.1, meeko>=0.5.0, pandas>=2.2.3 into the tenant venv on first run)
  - `prepare_baseline`: added `deps.venv_path: /opt/noetl/tenant-envs/glut-probe-design`
  - `enumerate_library`: converted `kind: shell` → `kind: python` with full library logic
    embedded inline; no longer references `{{ workload.project_repo }}` or any host path
  - `convert_library`: converted `kind: shell` → `kind: python` with embedded single-threaded
    PDBQT conversion loop; no longer references host paths

**Known limitation:** `convert_library` runs single-threaded inside `exec()` because
`multiprocessing.Pool` requires picklable module-level functions. For 400–600 compounds
this is ~5 min. Parallelism can be restored via a `kind: container` step or a
future worker-pool executor extension.

## Issues observed

- Circular import in tests: `noetl.tools.python.__init__` → `executor` →
  `noetl.worker.auth_resolver` → `nats_worker` → `noetl.tools.python`. Fixed by
  pre-importing `noetl.worker.auth_resolver` at test module top (same pattern as
  `tests/tools/test_agent_executor.py`).

## Manual escalation needed

- **End-to-end validation not yet run.** The `deps.packages` mechanism requires the
  NoETL worker pod to have a writable `/opt/noetl/tenant-envs/` directory and network
  access to PyPI (or a mirror) on first run. This has not been verified in a live
  kind-noetl cluster. See round-02-prompt.md for the validation task.
