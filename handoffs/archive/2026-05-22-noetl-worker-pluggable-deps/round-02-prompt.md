---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 2
from: claude
to: codex
created: 2026-05-22T12:15:00Z
status: open
expects_result_at: round-02-result.md
wait_phrase: "validate ligand deps"
---

# Validate hot-pluggable deps end-to-end in kind-noetl

> **Predecessor:** `round-01-result.md` — Phase 1 (NoETL executor `deps` feature,
> v2.89.0) and Phase 2 (updated `ligand-prep.yml` PR #36) are both merged and
> pointed to from ai-meta `main`.

## Background

Two PRs shipped the pluggable-deps mechanism:

1. **noetl v2.89.0** (`repos/noetl` @ `aeac750`) — adds `_resolve_deps()` to the
   Python tool executor. A playbook step can now declare:
   ```yaml
   tool:
     kind: python
     deps:
       packages:
         glut-probe-design:
           - "rdkit>=2024.03.1"
           - "meeko>=0.5.0"
           - "pandas>=2.2.3"
     code: |
       result = {"status": "ok"}
   ```
   On first run the executor creates a venv under
   `NOETL_TENANT_ENVS_DIR/<tenant-key>` (default `/opt/noetl/tenant-envs/`)
   and pip-installs the packages. Subsequent runs reuse the cache.

2. **glut-probe-design PR #36** (`repos/glut-probe-design` @ `7f67df1`) —
   `playbooks/noetl/ligand-prep.yml` uses `deps.packages` in
   `ensure_ligand_dependencies` and `deps.venv_path` in `prepare_baseline`,
   `enumerate_library`, `convert_library`. The shell steps that referenced
   the host `project_repo` path are replaced with embedded Python.

The local kind-noetl cluster runs at `http://localhost:8082`. NoETL must be
started with `noetl server start` from `repos/noetl` before any commands below.
Worker pods run the image built by `noetl build` / `noetl k8s deploy`.

**Critical unknown:** the worker pods need `/opt/noetl/tenant-envs/` to be a
writable, persistent directory (or at least writable across the steps of a single
execution). If it is a read-only or ephemeral tmpfs, pip install will fail.
Verify this before running compute steps.

## Phases

### Phase A — pre-flight checks (read-only, unattended)

1. From `repos/noetl`, confirm the current worker image tag includes v2.89.0:
   ```bash
   noetl --server-url http://localhost:8082 catalog list --kind WorkerImage 2>/dev/null || \
     kubectl --context kind-noetl get pods -n noetl -o wide 2>/dev/null | head -5
   ```
   Record the image tag in the result. If the cluster is not running, stop and
   report `blocked: kind-noetl not running`.

2. Check whether `/opt/noetl/tenant-envs/` is writable inside a worker pod:
   ```bash
   kubectl --context kind-noetl exec -n noetl \
     $(kubectl --context kind-noetl get pods -n noetl -l app=noetl-worker \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
     -- sh -c 'mkdir -p /opt/noetl/tenant-envs/probe && echo writable || echo read-only' \
     2>/dev/null || echo "no worker pod found"
   ```
   Record the result. If read-only, stop Phase B and report in `Manual escalation
   needed` — the host needs a writable volume mount at that path.

3. Pull latest submodules in `repos/glut-probe-design` and confirm the playbook
   is at PR #36 state:
   ```bash
   git -C repos/glut-probe-design log --oneline -1
   # expected: 7f67df1 Merge pull request #36 ...
   ```

4. From `repos/glut-probe-design`, validate the playbook YAML with the NoETL
   validator:
   ```bash
   cd repos/noetl && python scripts/validate_playbooks.py \
     ../glut-probe-design/playbooks/noetl
   ```
   Report all warnings and errors verbatim.

### Phase B — end-to-end validation in kind-noetl

> ***Run only after explicit human go-ahead. Wait phrase: `validate ligand deps`.***

5. Register the updated playbooks:
   ```bash
   noetl --server-url http://localhost:8082 register playbook \
     -f repos/glut-probe-design/playbooks/noetl/tenant-smoke.yml
   noetl --server-url http://localhost:8082 register playbook \
     -f repos/glut-probe-design/playbooks/noetl/ligand-prep.yml
   ```

6. Run tenant smoke to confirm the cluster is healthy:
   ```bash
   noetl --server-url http://localhost:8082 run \
     tenants/glut-probe-design/projects/glut-probe-design/smoke \
     --runtime distributed
   noetl --server-url http://localhost:8082 status <execution_id> --json
   ```
   Report final status. Stop if smoke fails.

7. Run `ensure_ligand_dependencies` in isolation (deps-only dry run):
   ```bash
   tmp=$(mktemp /tmp/glut-noetl-input.XXXXXX)
   cat repos/glut-probe-design/catalog/data-catalog.json \
     | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'catalog_json': json.dumps(d), 'prepare_baseline': 'false', 'enumerate_library': 'false', 'convert_library': 'false', 'upload_to_gcs': 'false', 'cleanup_local_artifacts': 'false'}))" \
     > "$tmp"
   noetl --server-url http://localhost:8082 exec \
     tenants/glut-probe-design/projects/glut-probe-design/data/ligands/prep \
     --runtime distributed \
     --input "$tmp"
   noetl --server-url http://localhost:8082 status <execution_id> --json
   ```
   Record: did `ensure_ligand_dependencies` complete? Was the venv created at
   `/opt/noetl/tenant-envs/glut-probe-design/`? Report the exact step status and
   any error strings verbatim.

8. If step 7 succeeded, run with `prepare_baseline=true` only:
   ```bash
   tmp=$(mktemp /tmp/glut-noetl-input.XXXXXX)
   cat repos/glut-probe-design/catalog/data-catalog.json \
     | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'catalog_json': json.dumps(d), 'prepare_baseline': 'true', 'enumerate_library': 'false', 'convert_library': 'false', 'upload_to_gcs': 'false', 'cleanup_local_artifacts': 'false'}))" \
     > "$tmp"
   noetl --server-url http://localhost:8082 exec \
     tenants/glut-probe-design/projects/glut-probe-design/data/ligands/prep \
     --runtime distributed \
     --input "$tmp"
   noetl --server-url http://localhost:8082 status <execution_id> --json
   ```
   Record: did `prepare_baseline` produce `mancou_ch3.sdf` and `mancou_ch3.pdbqt`
   in the worker workspace? Report exact step status and any error strings verbatim.

9. If step 8 succeeded, add a GLUT memory entry documenting the first successful
   distributed ligand-prep run:
   ```bash
   cd repos/glut-probe-design
   ./scripts/memory_add.sh \
     "First distributed ligand-prep with pluggable deps" \
     "ensure_ligand_dependencies installed rdkit/meeko/pandas into /opt/noetl/tenant-envs/glut-probe-design via deps.packages (noetl v2.89.0). prepare_baseline produced mancou_ch3.sdf and mancou_ch3.pdbqt in the worker workspace. Execution <id>." \
     "noetl,ligands,rdkit,meeko,deps"
   git -C repos/glut-probe-design add memory/ && \
     git -C repos/glut-probe-design commit -m "memory(add): first distributed ligand-prep with pluggable deps"
   ```

## FINAL REPORT

Write the result at `round-02-result.md` with frontmatter:

```yaml
---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 2
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-02-prompt.md
status: complete | partial | blocked
---
```

Then the report body:

```markdown
## Phase A — pre-flight checks
- Worker image tag: <value>
- /opt/noetl/tenant-envs/ writable: yes | no | unknown
- Playbook validator output: <verbatim>

## Phase B — end-to-end validation
- Step 6 smoke: <status>
- Step 7 deps-only dry run: <status>, venv created: yes | no
- Step 8 prepare_baseline: <status>, artifacts present: yes | no

## Issues observed
- <verbatim error strings, exit codes, stack frames>

## Manual escalation needed
- <exact commands a human must run>
```

## Hard rules for this thread

- Never push to `origin/main` on any repo unless explicitly stated.
- Never force-push.
- Never merge PRs yourself.
- Do not store secrets in any committed file.
- If the worker pod filesystem is read-only at `/opt/noetl/tenant-envs/`,
  stop Phase B and report — do not try alternative paths.
- Respect `AGENTS.md` and `agents/rules/` in both repos.
