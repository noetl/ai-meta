---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 1
from: claude
to: codex
created: 2026-05-22T10:00:00Z
status: open
expects_result_at: round-01-result.md
---

# Add hot-pluggable `deps` to NoETL Python tool executor

## Context

GLUT Probe Design (`repos/glut-probe-design`) runs scientific compute steps
(`rdkit`, `meeko`, `pandas`) via the NoETL distributed worker. The core
NoETL worker image does not contain these packages and the image cannot be
rebuilt per tenant without a platform-level mechanism.

PR #35 (merged) added a `ensure_ligand_dependencies` gate step in
`playbooks/noetl/ligand-prep.yml` that fails early with a clear message when
the packages are missing. That gives a good diagnostic, but the compute steps
(`prepare_baseline`, `enumerate_library`, `convert_library`) still cannot run
in distributed mode.

Two related problems:
1. No way to declare tenant-specific Python packages at the playbook/step
   level and have them installed (or injected from a pre-built env) before
   code executes.
2. `enumerate_library` and `convert_library` steps are `kind: shell` and
   reference `{{ workload.project_repo }}` (a host path), which fails inside
   worker pods that do not mount the host checkout.

## Background

**Key files to read before starting:**

- `repos/noetl/noetl/tools/python/executor.py` — Python tool executor.
  The `libs` dict (lines 369–432) already validates and prepends import
  statements but **never installs** packages. The `deps` feature goes here.
- `repos/noetl/pyproject.toml` — core NoETL dependencies; do NOT add
  `rdkit`/`meeko`/`pandas` here.
- `repos/glut-probe-design/playbooks/noetl/ligand-prep.yml` — the playbook
  to update once the executor supports `deps`.
- `repos/glut-probe-design/scripts/enumerate_library.py` — the enumeration
  logic currently called via shell; read it so you can embed it.
- `repos/glut-probe-design/scripts/smiles_to_pdbqt.py` — the PDBQT
  conversion logic currently called via shell; read it so you can embed it.

**Existing `libs` dict (for context — do not remove):**
```yaml
tool:
  kind: python
  libs:
    pd: pandas
    storage:
      from: google.cloud
      import: storage
  code: |
    ...
```
The `libs` dict prepends `import X as Y` statements and validates that the
top-level module is already importable. `deps` is the orthogonal mechanism
that **installs or injects** packages before that validation happens.

## Phases

### Phase 1 — Implement `deps` in the Python executor (no-remote-writes)

**Location:** `repos/noetl/noetl/tools/python/executor.py`

Add a `_resolve_deps(deps_config, context)` function that runs **before** the
`libs` validation and `exec()` call, inside `execute_python_task_async`.

The `deps` config is a dict on the tool config alongside `code`/`libs`:

```yaml
tool:
  kind: python
  deps:
    # Install packages into a per-tenant cached venv.
    # Key: tenant-scoped venv name (used as cache directory suffix).
    # Value: list of PEP 508 requirement specifiers.
    packages:
      glut-probe-design:
        - "rdkit>=2024.03.1"
        - "meeko>=0.5.0"
        - "pandas>=2.2.3"

    # Directly inject one or more directories into sys.path.
    # Use when a pre-built env is mounted/extracted into the worker.
    sys_path:
      - "/opt/noetl/tenant-envs/glut-probe-design/site-packages"

    # Reuse an existing venv without reinstalling.
    # Injects <venv_path>/lib/pythonX.Y/site-packages into sys.path.
    venv_path: "/opt/noetl/tenant-envs/glut-probe-design"
  code: |
    ...
```

All three sub-keys are optional and may be combined.

**`_resolve_deps` implementation rules:**

1. `sys_path` entries — insert each path at `sys.path[0]` if not already
   present. No network calls. Silently skip paths that don't exist on the
   filesystem (log a warning).

2. `venv_path` — locate `<venv_path>/lib/pythonX.Y/site-packages` via
   `glob.glob`. Insert at `sys.path[0]` if not already present. Raise
   `RuntimeError` if the venv directory doesn't exist.

3. `packages` — dict keyed by a tenant name (arbitrary string used as a
   cache key). For each key:
   a. Determine the venv path:
      `NOETL_TENANT_ENVS_DIR` env var (default `/opt/noetl/tenant-envs`) +
      `/<tenant-key>`.
   b. If the venv does not exist, create it with `venv.create(venv_path,
      with_pip=True)` and install the listed packages via `subprocess.run(
      [sys.executable, "-m", "pip", "install", "--quiet", *packages],
      check=True)` **inside** the venv's Python interpreter (not the worker's
      `sys.executable`; use `<venv>/bin/python` or `<venv>/Scripts/python`).
   c. If the venv already exists but any package in the list is not importable
      from it, re-run pip install (idempotent; pip skips already-satisfied
      specs).
   d. Inject the venv's `site-packages` into `sys.path[0]`.
   e. Wrap install errors in a clear `RuntimeError` that names the tenant key
      and the missing packages — do not swallow them.

4. The function must be **synchronous** (it is called inside `run_in_executor`
   or directly before the async exec path). Use `asyncio.get_event_loop()` or
   a direct `subprocess.run` — no async subprocess here.

5. Add a guard: if `NOETL_SKIP_DEPS_RESOLUTION=true` env var is set, skip
   the entire `_resolve_deps` call (for test environments that pre-inject
   packages another way).

6. Log at `logger.info` when packages are installed for the first time, and
   at `logger.debug` when an existing cached venv is reused.

Call `_resolve_deps` in `execute_python_task_async` **immediately after**
the `libs_config` block (after line 432 in the current file). The `deps`
config is at `task_config.get('deps')`.

**Tests:**

Add or extend tests in `repos/noetl/tests/` (existing pattern:
`test_worker_actions_from_examples.py` or a new
`test_python_tool_deps.py`):
- `sys_path` injection injects paths that exist, warns on missing paths.
- `venv_path` injection finds the site-packages dir correctly.
- `packages` flow: if packages are already importable from the injected venv,
  no pip is called.
- `NOETL_SKIP_DEPS_RESOLUTION=true` bypasses all logic.
- Missing venv with bad packages raises `RuntimeError` with a useful message.

Use `unittest.mock` to stub `subprocess.run` and `venv.create` — do not
actually install packages in CI.

### Phase 2 — Update `ligand-prep.yml` to use `deps`

**Location:** `repos/glut-probe-design/playbooks/noetl/ligand-prep.yml`

After Phase 1 is merged and the pointer is bumped, update the playbook:

1. **`ensure_ligand_dependencies` step** — replace the manual `__import__`
   loop with `deps.packages` on the step's tool config. The step body becomes:

   ```yaml
   - step: ensure_ligand_dependencies
     desc: Install or verify GLUT ligand-prep dependencies in the tenant venv
     tool:
       kind: python
       deps:
         packages:
           glut-probe-design:
             - "rdkit>=2024.03.1"
             - "meeko>=0.5.0"
             - "pandas>=2.2.3"
       code: |
         result = {
             "status": "ok",
             "checked": ["rdkit", "meeko", "pandas"],
         }
   ```

   On first run this installs the packages and caches the venv. On subsequent
   runs it reuses the venv. If install fails the step errors and downstream
   compute is blocked — same behaviour as before.

2. **`prepare_baseline` step** — add `deps.venv_path` pointing to the same
   tenant venv so the embedded rdkit/meeko code can import them without
   reinstalling:

   ```yaml
   deps:
     venv_path: "/opt/noetl/tenant-envs/glut-probe-design"
   ```

3. **`enumerate_library` step** — convert from `kind: shell` (which references
   the host `project_repo`) to `kind: python` with the logic from
   `repos/glut-probe-design/scripts/enumerate_library.py` embedded inline
   (same pattern as `prepare_baseline`). Add `deps.venv_path` for rdkit/pandas.
   The step must write its output to `{{ project_workspace }}/data/ligands/library/`
   so that `convert_library` and `write_metadata_index` can find it.

4. **`convert_library` step** — convert from `kind: shell` to `kind: python`
   with the logic from `repos/glut-probe-design/scripts/smiles_to_pdbqt.py`
   embedded inline. Add `deps.venv_path`.

> ***Run only after explicit human go-ahead. Wait phrase: `ship ligand deps`.***
>
> Once Phase 1 tests pass locally, open PRs in this order:
> 1. PR in `repos/noetl` for the executor change + tests.
> 2. After that PR merges, bump the `repos/noetl` submodule pointer in
>    `ai-meta` with `chore(sync): bump noetl to <sha>`.
> 3. PR in `repos/glut-probe-design` for the updated `ligand-prep.yml`.
> 4. After that PR merges, bump the `repos/glut-probe-design` submodule
>    pointer in `ai-meta`.

## Acceptance criteria

- `_resolve_deps` is unit-tested with mocked subprocess/venv; all tests green.
- `ligand-prep.yml` dry run (no-compute flags: `prepare_baseline=false
  enumerate_library=false convert_library=false`) still completes in a local
  kind-noetl without rdkit installed.
- `ligand-prep.yml` with `prepare_baseline=true` completes in a local
  kind-noetl after `ensure_ligand_dependencies` installs the tenant venv.
- `enumerate_library` and `convert_library` steps no longer reference
  `{{ workload.project_repo }}` or any host-mounted path.
- No `rdkit`, `meeko`, or `pandas` appear in `repos/noetl/pyproject.toml`.

## FINAL REPORT

Write the result at `round-01-result.md` with frontmatter:

```yaml
---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then the report body:

```markdown
## Phase 1 — executor `deps` implementation
- Files changed, key function signatures, test names and results

## Phase 2 — ligand-prep.yml update
- Status (blocked on Phase 1 PR merge / complete / partial)

## Issues observed
- Exact error strings, exit codes, stack frame top lines if any

## Manual escalation needed
- Everything that requires human action (PR merges, go-ahead phrase)
```

## Hard rules for this thread

- Never push to `origin/main` on any repo unless this prompt explicitly says so.
- Never force-push.
- Never merge PRs yourself.
- Do not add `rdkit`, `meeko`, or any tenant-specific scientific package to
  `repos/noetl/pyproject.toml`.
- Respect `AGENTS.md` and `agents/rules/` in both repos.
- Do not store secrets, credentials, or molecular data in any committed file.
- If a step's preconditions aren't met, stop and report — don't improvise.
