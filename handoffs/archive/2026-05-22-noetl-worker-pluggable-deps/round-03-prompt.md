---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 3
from: claude
to: codex
created: 2026-05-22T17:00:00Z
status: open
expects_result_at: round-03-result.md
wait_phrase: "redeploy noetl"
---

# Redeploy v2.89.0 image to kind-noetl, then rerun Phase B

> **Predecessor:** `round-02-result.md` (status: partial)
> Phase B ran but failed at `prepare_baseline` because the live worker image
> is `localhost/local/noetl:2026-05-21-20-48` / **v2.88.1**, which predates
> the `_resolve_deps()` commit. The `deps.packages` field is silently ignored
> by the old executor, so no tenant venv is created and `meeko` is not found.

## Background

- `repos/noetl` is at `aeac7509` (v2.89.0) — this commit contains `_resolve_deps()`.
- `repos/noetl` describes as `v2.89.0-dirty` because three unrelated files are
  modified in the working tree (`ci/manifests/test-server/deployment.yaml`,
  `noetl/core/messaging/nats_client.py`, `tests/core/test_nats_command_subscriber.py`).
  None of these affect the Python executor. The build will include them; that is
  acceptable.
- `repos/glut-probe-design` is at `7f67df1` (PR #36) — `ligand-prep.yml` uses
  `deps.packages` in `ensure_ligand_dependencies` and `deps.venv_path` in the
  compute steps.
- kind-noetl is currently running and healthy (`localhost:8082/health` → `{"status":"ok"}`).
- `/opt/noetl/tenant-envs/` is writable inside worker pods (confirmed in round 2).
- A stale `/opt/noetl/tenant-envs/probe` directory exists from the writability
  test; it is harmless.
- The ops redeploy playbook lives at
  `repos/ops/automation/development/noetl.yaml` and accepts
  `action=redeploy noetl_repo_dir=../noetl`.

## Phases

### Phase A — pre-flight (no writes, unattended)

1. Confirm `repos/noetl` HEAD is `aeac7509`:
   ```bash
   git -C /Volumes/X10/projects/noetl/ai-meta/repos/noetl log --oneline -1
   # expected: aeac7509 chore(release): version 2.89.0 [skip ci]
   ```

2. Confirm `_resolve_deps` is present in the source tree:
   ```bash
   grep -c "_resolve_deps" \
     /Volumes/X10/projects/noetl/ai-meta/repos/noetl/noetl/tools/python/executor.py
   # expected: any number > 0
   ```

3. Confirm cluster is still healthy:
   ```bash
   curl -fsS http://localhost:8082/health
   # expected: {"status":"ok"}
   ```

4. Record the dirty files (for the report) — do not stash or discard them:
   ```bash
   git -C /Volumes/X10/projects/noetl/ai-meta/repos/noetl status --short
   ```

### Phase B — redeploy and validate

> ***Run only after explicit human go-ahead. Wait phrase: `redeploy noetl`.***

5. Run the ops redeploy playbook from `repos/ops`:
   ```bash
   cd /Volumes/X10/projects/noetl/ai-meta/repos/ops
   unset XDG_DATA_HOME
   noetl run automation/development/noetl.yaml \
     --runtime local \
     --set action=redeploy \
     --set noetl_repo_dir=../noetl
   ```
   Wait for the playbook to complete. Record exit code and any error output
   verbatim. If this fails, stop and report — do not try manual `noetl build`
   or `kubectl` rollout commands.

6. Verify the newly deployed image contains v2.89.0 and `_resolve_deps`:
   ```bash
   kubectl --context kind-noetl get deploy noetl-worker -n noetl \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

   kubectl --context kind-noetl exec -i -n noetl deploy/noetl-worker -- \
     sh -c 'grep "^version" /opt/noetl/pyproject.toml && \
            grep -c "_resolve_deps" /opt/noetl/noetl/tools/python/executor.py'
   # expected: version = "2.89.0" and count > 0
   ```
   If the version is still 2.88.1 or `_resolve_deps` count is 0, stop and
   report — do not proceed to step 7.

7. Re-register the ligand-prep playbook (new worker needs the latest YAML):
   ```bash
   noetl --server-url http://localhost:8082 register playbook \
     -f /Volumes/X10/projects/noetl/ai-meta/repos/glut-probe-design/playbooks/noetl/ligand-prep.yml
   ```

8. Run the deps-install dry run (`ensure_ligand_dependencies` with all compute
   flags off, to trigger venv creation):
   ```bash
   tmp=$(mktemp /tmp/glut-noetl-input.XXXXXX)
   python3 -c "
   import json, sys
   d = json.load(open('/Volumes/X10/projects/noetl/ai-meta/repos/glut-probe-design/catalog/data-catalog.json'))
   print(json.dumps({
       'catalog_json': json.dumps(d),
       'prepare_baseline': 'true',
       'enumerate_library': 'false',
       'convert_library': 'false',
       'upload_to_gcs': 'false',
       'cleanup_local_artifacts': 'false',
   }))
   " > "$tmp"
   noetl --server-url http://localhost:8082 exec \
     tenants/glut-probe-design/projects/glut-probe-design/data/ligands/prep \
     --runtime distributed \
     --input "$tmp"
   ```
   Poll until terminal:
   ```bash
   noetl --server-url http://localhost:8082 status <execution_id> --json
   ```
   Record: did `ensure_ligand_dependencies` complete? Was
   `/opt/noetl/tenant-envs/glut-probe-design/` created in the worker pod?
   Did `prepare_baseline` produce `mancou_ch3.sdf` and `mancou_ch3.pdbqt`?

   Check artifacts:
   ```bash
   kubectl --context kind-noetl exec -n noetl deploy/noetl-worker -- \
     sh -c 'ls /opt/noetl/tenant-envs/glut-probe-design/lib/python*/site-packages/rdkit/__init__.py 2>/dev/null && echo rdkit_ok || echo rdkit_missing'
   kubectl --context kind-noetl exec -n noetl deploy/noetl-worker -- \
     find /opt/noetl/data/tenants/glut-probe-design/projects/glut-probe-design/data/ligands/baseline \
       -name "mancou_ch3.*" 2>/dev/null
   ```

9. If step 8 succeeded, add a GLUT memory entry:
   ```bash
   cd /Volumes/X10/projects/noetl/ai-meta/repos/glut-probe-design
   ./scripts/memory_add.sh \
     "First successful distributed ligand-prep with pluggable deps" \
     "After redeploying kind-noetl with NoETL v2.89.0, ensure_ligand_dependencies installed rdkit/meeko/pandas into /opt/noetl/tenant-envs/glut-probe-design via deps.packages. prepare_baseline produced mancou_ch3.sdf and mancou_ch3.pdbqt in the worker workspace. Execution <id>." \
     "noetl,ligands,rdkit,meeko,deps"
   git add memory/ && git commit -m "memory(add): first distributed ligand-prep with pluggable deps"
   ```
   Do not push — leave that to the human.

## FINAL REPORT

Write at `round-03-result.md`:

```yaml
---
thread: 2026-05-22-noetl-worker-pluggable-deps
round: 3
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-03-prompt.md
status: complete | partial | blocked
---
```

```markdown
## Phase A — pre-flight
- HEAD: <sha>
- _resolve_deps present: yes | no
- cluster health: ok | down
- dirty files: <list>

## Phase B — redeploy and validate
- Step 5 ops redeploy: <exit code, duration>
- Step 6 image verification: version=<X>, _resolve_deps count=<N>
- Step 7 playbook re-register: ok | error
- Step 8 execution <id>: <step statuses>
  - ensure_ligand_dependencies: complete | failed
  - venv created at /opt/noetl/tenant-envs/glut-probe-design: yes | no
  - prepare_baseline: complete | failed
  - mancou_ch3.sdf present: yes | no
  - mancou_ch3.pdbqt present: yes | no

## Issues observed
- <verbatim error strings>

## Manual escalation needed
- <exact commands>
```

## Hard rules

- Never push to `origin/main` on any repo.
- Never force-push. Never merge PRs.
- If the ops redeploy playbook fails, stop — do not try manual kubectl image patches.
- Do not stash or discard the dirty files in `repos/noetl`.
- Respect `AGENTS.md` and `agents/rules/` in both repos.
