# Handover — Cursor-driven loop e2e validation

Owner until handover: Claude (`claude/eager-cohen-93d864` worktree).
Next owner: **Codex**.  Acceptance criteria at the bottom.  When
Codex marks the task complete (or blocks), the user will re-hand the
task back to Claude, who will resume using only git history +
`memory/` entries + this document.

## What we're trying to achieve

Deliver a working `loop.cursor` primitive for NoETL that replaces the
collection-materialized `step.loop` with a pull-model worker pool:

- The engine dispatches `N = max_in_flight` persistent worker commands
  up front (no per-iteration CAS bookkeeping).
- Each worker opens a driver handle (Postgres first; drivers for
  MySQL / Snowflake / ClickHouse / Redis / S3 prefix are future work)
  and loops `claim → render iter.<iterator> → run task chain → repeat`
  until the driver's claim returns zero rows.
- `loop.done` fires when all N workers have exited.

Full background: `repos/docs/docs/features/noetl_cursor_loop_design.md`
+ `noetl_cursor_loop_implementation.md`.

The success target is the PFT flow test
(`repos/noetl/tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml`):
**10 facilities × 1000 patients × 5 data types → 10/10 green** with
all barriers firing and `validate_all_results` reporting no shortfalls.

## Current state

| Thing | Where | Notes |
|---|---|---|
| noetl feature branch | `feat/storage-rw-alignment-phase-1` @ `c81e9910` | Merged to ai-meta `main` via submodule pointer |
| docs | `main` @ `8da084b` | Design + implementation-status companion |
| ai-meta branch | `main` (this repo) | Merged from `claude/eager-cohen-93d864` |
| Infrastructure (Phases 1–5) | Done | See implementation-status doc for commit ids |
| PFT migration (Phase 6) | Done | 35→24 steps; 5 cursor loops per data type |
| End-to-end validation (Phase 7) | **In progress** — the row-preservation fix (`c81e9910`) unblocks multi-facility runs; last live run `610209020581774041` hit facility 1 at 4999/5000 before this handover |

## Environment contract

Everything below assumes a local podman-based kind cluster named
`noetl`, postgres in namespace `postgres`, noetl in namespace `noetl`,
and an ops submodule at `repos/ops` with
`automation/development/noetl.yaml` for build+deploy.  The
`paginated-api` test server + all `pft_test_*` tables are already
provisioned from prior sessions.

Sanity check before touching anything:

```bash
kubectl get nodes
kubectl -n noetl get pods
kubectl -n postgres get pods
```

If the cluster is down (podman machine stopped, container exited), restart
it:

```bash
podman machine list                   # should show noetl-dev running
podman machine start noetl-dev        # only if not running
podman ps -a | grep noetl-control-plane
podman start noetl-control-plane      # if Exited
```

Wait until `kubectl get nodes` returns `Ready` before continuing.

## Deploy workflow (this is the sharp-edged part)

Build + redeploy via the ops playbook:

```bash
cd repos/ops
noetl run automation/development/noetl.yaml \
  --runtime local \
  --set action=redeploy \
  --set noetl_repo_dir=../noetl
```

**Gotcha that bites every single redeploy on this stack:** the ops
playbook builds the image and tries `kind load`, but kubelet resolves
`local/noetl:<tag>` as `docker.io/local/noetl:<tag>` and can't find the
image because kind only tagged it `localhost/local/noetl:<tag>` and
`docker.io/library/local/noetl:<tag>`.  The rollout times out with
`ErrImagePull` or `ErrImageNeverPull`.  The fix is a manual retag on
the kind node:

```bash
CURR_TAG=$(kubectl -n noetl get deploy/noetl-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||')
podman exec noetl-control-plane ctr -n k8s.io images tag \
  localhost/local/noetl:$CURR_TAG docker.io/library/local/noetl:$CURR_TAG
podman exec noetl-control-plane ctr -n k8s.io images tag \
  localhost/local/noetl:$CURR_TAG docker.io/local/noetl:$CURR_TAG
kubectl -n noetl delete pods -l app=noetl-server --wait=false
kubectl -n noetl delete pods -l app=noetl-worker --wait=false
kubectl -n noetl rollout status deploy/noetl-server --timeout=180s
kubectl -n noetl rollout status deploy/noetl-worker --timeout=180s
```

Run these retag lines **every time** after the ops playbook build step
finishes, regardless of whether the playbook reports success or the
"timed out waiting for the condition" error.

Then port-forward the API:

```bash
pkill -f "kubectl.*port-forward.*8082:8082" 2>/dev/null
kubectl -n noetl port-forward svc/noetl 8082:8082 > /tmp/pf.log 2>&1 &
sleep 3
curl -sf http://localhost:8082/api/health   # must return {"status":"ok"}
```

## Registering and running the PFT playbook

Register the current playbook version (bumps version number on each
re-register):

```bash
cd repos/noetl
python -c "
import json
with open('tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml') as f:
    content = f.read()
print(json.dumps({'content': content, 'resource_type': 'Playbook'}))
" > /tmp/register.json
curl -sS -X POST http://localhost:8082/api/catalog/register \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/register.json
```

Response includes the registered `version` — capture it.

(Optional) register the sub-playbook if it hasn't been:

```bash
python -c "
import json
with open('tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml') as f:
    content = f.read()
print(json.dumps({'content': content, 'resource_type': 'Playbook'}))
" > /tmp/register_mds.json
curl -sS -X POST http://localhost:8082/api/catalog/register \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/register_mds.json
```

Before every run, wipe test tables and reset facility state:

```bash
kubectl -n postgres exec deploy/postgres -- psql -U demo -d demo_noetl -c "
DELETE FROM public.pft_test_patient_work_queue;
DELETE FROM public.pft_test_patient_ids_work;
DELETE FROM public.pft_test_facility_data_type_done;
DELETE FROM public.pft_test_patient_assessments;
DELETE FROM public.pft_test_patient_conditions;
DELETE FROM public.pft_test_patient_medications;
DELETE FROM public.pft_test_patient_vital_signs;
DELETE FROM public.pft_test_patient_demographics;
DELETE FROM public.pft_test_mds_assessment_details;
DELETE FROM public.pft_test_mds_assessment_ids_work;
DELETE FROM public.pft_test_validation_log;
UPDATE public.pft_test_facilities SET active = TRUE;
"
```

Kick off (substitute the version captured above):

```bash
curl -sS -X POST http://localhost:8082/api/execute \
  -H "Content-Type: application/json" \
  -d '{"path": "tests/fixtures/playbooks/pft_flow_test/test_pft_flow", "version": <VERSION>}'
```

Response returns `execution_id`.  Capture it for the checks below.

## Observability — what to watch during a run

### Queue progress (primary green signal)

```bash
kubectl -n postgres exec deploy/postgres -- psql -U demo -d demo_noetl -At -c "
SELECT facility_mapping_id, data_type, status, COUNT(*)
FROM public.pft_test_patient_work_queue
WHERE execution_id = '<EXEC_ID>'
GROUP BY 1,2,3 ORDER BY 1,2,3;"
```

Expected pattern for a completed facility: `fN | <data_type> | done | 1000`
for each of the 5 data types.

### Barriers (fan-in signal)

```bash
kubectl -n postgres exec deploy/postgres -- psql -U demo -d demo_noetl -At -c "
SELECT facility_mapping_id, COUNT(*)
FROM public.pft_test_facility_data_type_done
WHERE execution_id = '<EXEC_ID>'
GROUP BY 1 ORDER BY 1;"
```

Each completed facility should appear with count `5`.

### Facility state machine

```bash
kubectl -n postgres exec deploy/postgres -- psql -U demo -d demo_noetl -At -c "
SELECT facility_mapping_id, active, updated_at
FROM public.pft_test_facilities
ORDER BY facility_mapping_id;"
```

After a successful run, all 10 rows must show `active = f`.

### Validation log (final check data source)

```bash
kubectl -n postgres exec deploy/postgres -- psql -U demo -d demo_noetl -c "
SELECT facility_mapping_id, assessments_done, conditions_done,
       medications_done, vital_signs_done, demographics_done
FROM public.pft_test_validation_log
WHERE execution_id = '<EXEC_ID>'
ORDER BY facility_mapping_id;"
```

Must contain exactly 10 rows, one per facility, with every `*_done`
column = 1000.

### Workflow terminal event

```bash
kubectl -n postgres exec deploy/postgres -- psql -U demo -d noetl -c "
SELECT event_type, created_at FROM noetl.event
WHERE execution_id = <EXEC_ID>
  AND event_type IN ('workflow.completed', 'workflow.failed', 'execution.failed')
ORDER BY created_at DESC;"
```

Success = `workflow.completed`.  Any failed event means dig into
server logs and recent `step.failed` / `command.failed` events.

### Cursor-loop diagnostic logs already in the image

These log at INFO level and survive container restarts:

```bash
kubectl -n noetl logs deploy/noetl-server --tail=2000 2>&1 | grep -E "CURSOR-LOOP|DIAG-"
kubectl -n noetl logs deploy/noetl-worker --tail=2000 2>&1 | grep "CURSOR-WORKER"
```

`DIAG-*` log families present in the current image (all in
`c81e9910`):

- `DIAG-SET` — call.done response_data keys before mark_step_completed
- `DIAG-POST-MARK` — state.step_results keys after mark_step_completed
- `DIAG-LOADED` — step_results keys after state load (per event handler)
- `DIAG-DISPATCH` — step_results keys when cursor dispatch builds render_context
- `DIAG-MSC` — load_next_facility specific mark_step_completed trace
- `DIAG-EXIT` — step.exit hydration trace

These were added to chase the row-stripping issue.  They are
harmless but noisy; if you're chasing a different issue and want
them gone, they live in:

- `repos/noetl/noetl/core/dsl/engine/executor/events.py`
- `repos/noetl/noetl/core/dsl/engine/executor/state.py`
- `repos/noetl/noetl/core/dsl/engine/executor/transitions.py`
- `repos/noetl/noetl/worker/cursor_worker.py`

Feel free to strip them before handing back if the run goes clean
(they were diagnostic scaffolding, not core code).

## Acceptance criteria (for Codex)

A run is accepted when **all** of these are true:

1. Fresh deploy with retag trick applied.  Pods all `Running 1/1`.
2. Playbook registered at a known version.  Test tables cleared,
   facilities all `active = TRUE` before kickoff.
3. A single `POST /api/execute` kicks off the flow; no manual
   intervention needed during the run (no reaper re-kicks, no
   cancels).
4. `workflow.completed` event fires for the execution.
5. Validation log has **exactly 10 rows**, one per facility, with all
   five `*_done` columns equal to 1000.
6. `pft_test_facilities` shows all 10 rows with `active = f`.
7. `pft_test_facility_data_type_done` shows 50 rows total (10
   facilities × 5 data types).
8. No facility short-circuited: cross-check by counting distinct
   `pcc_patient_id` per facility in each data table:

   ```sql
   SELECT 'assessments' AS dt, facility_mapping_id, COUNT(DISTINCT pcc_patient_id) AS n
   FROM public.pft_test_patient_assessments GROUP BY 2
   UNION ALL SELECT 'conditions', facility_mapping_id,
     COUNT(DISTINCT pcc_patient_id) FROM public.pft_test_patient_conditions GROUP BY 2
   UNION ALL SELECT 'medications', facility_mapping_id,
     COUNT(DISTINCT pcc_patient_id) FROM public.pft_test_patient_medications GROUP BY 2
   UNION ALL SELECT 'vital_signs', facility_mapping_id,
     COUNT(DISTINCT pcc_patient_id) FROM public.pft_test_patient_vital_signs GROUP BY 2
   UNION ALL SELECT 'demographics', facility_mapping_id,
     COUNT(DISTINCT pcc_patient_id) FROM public.pft_test_patient_demographics GROUP BY 2
   ORDER BY 2, 1;
   ```

   Must return **50 rows** (5 dt × 10 facilities), every `n` = 1000.
9. No `step.failed` or `command.failed` events for this execution.
10. No manual `UPDATE pft_test_*` / retag / pod restart during the
    run.  If Codex had to intervene, the run does not count.

## If the run fails

Typical failure modes and where to look:

- **`ErrImageNeverPull` / `ErrImagePull`**: forgot the retag.  Apply
  the retag block above and delete the failing pods.
- **Cursor workers drain with 0 processed / 0 failed**: claim SQL
  rendered without `facility_mapping_id` (template issue).  Check
  `DIAG-DISPATCH` — `lnf_ctx_keys` should include `rows`.  If it
  doesn't, the row-preservation fix regressed; inspect
  `repos/noetl/noetl/core/dsl/engine/executor/state.py:183-224`
  (`mark_step_completed`).
- **`loop.done` never fires despite 100 call.done events**: check NATS
  KV seed is present (`DIAG-*` logs) and step suffix is
  `:task_sequence`, not `:cursor_worker`.  See commits `440c21f0` and
  `f0ce4c31`.
- **Postgres refuses new connections (`too many clients`)**: driver
  pool regressed to per-worker instances.  See commit `47397c94` for
  the shared-pool fix.
- **Facilities 3–6 skipped in rapid burst**: ctx facility threading
  is broken — same family as the row-preservation bug.  Confirm the
  `mark_step_completed` merge-forward logic is intact at
  `state.py:209-224`.

For anything not on that list: run the full observability commands
above, capture the server+worker logs, add a memory entry under
`memory/inbox/<date>/<slug>.md` describing the symptom and any hunch,
then stop and hand back to Claude.

## Notes for Claude (next session)

When the user hands this task back to you, you will start a fresh
session with no chat memory of this work.  Your context will be:

- `git log --oneline` on ai-meta `main` and on
  `repos/noetl` branch `feat/storage-rw-alignment-phase-1`
- `memory/inbox/2026/04/` entries from `20260421-*` (several) and any
  newer ones Codex may have written
- This handover doc
- `repos/docs/docs/features/noetl_cursor_loop_design.md` and
  `noetl_cursor_loop_implementation.md`

Read those first, in that order.  They give you the "why", the "how",
the delivered scope, and the acceptance criteria.

**Before acting**, run the observability commands above to see the
current state:

- If `workflow.completed` exists for the last exec id Codex kicked
  off and acceptance criteria pass, the task is done — update the
  implementation-status doc to reflect the green run and move to the
  open questions at the bottom of it.
- If Codex blocked, their memory entry will explain where.  Pick up
  from there.
- The cluster may have drifted (pods restarted, port-forward gone).
  Re-run the cluster sanity check + port-forward block before any
  playbook action.

**Scope boundary when you return:** the cursor-loop primitive and PFT
green are the current task.  Do NOT start new features or broader
refactors unless the user explicitly opens that scope.  Items
explicitly out of scope for this handover:

- Investigating why `noetl.execution.state` UPDATE is a no-op (the
  underlying cause of every event handler doing a full replay).  This
  is a real latent bug but orthogonal to cursor loops.
- Migrating any other playbook to `loop.cursor`.
- Adding drivers beyond postgres.
- Refactoring the PFT playbook to stop reaching into
  `load_next_facility.context.rows[0]` through step-result internals.

If acceptance passes, mark the cursor-loop task complete in a memory
entry and propose the next milestone (e.g., MySQL driver, or the
`noetl.execution.state` write path investigation) to the user — do
not act on it yet.

## One-shot script (Codex-convenience)

If you want a single script to run the full redeploy→run→watch loop:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# 1. Cluster sanity
kubectl get nodes || { echo "cluster not ready"; exit 1; }

# 2. Build + redeploy (ignore timeout exit code — expected)
( cd repos/ops && noetl run automation/development/noetl.yaml \
    --runtime local --set action=redeploy --set noetl_repo_dir=../noetl ) || true

# 3. Retag trick
CURR_TAG=$(kubectl -n noetl get deploy/noetl-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's|.*:||')
podman exec noetl-control-plane ctr -n k8s.io images tag \
  localhost/local/noetl:$CURR_TAG docker.io/library/local/noetl:$CURR_TAG
podman exec noetl-control-plane ctr -n k8s.io images tag \
  localhost/local/noetl:$CURR_TAG docker.io/local/noetl:$CURR_TAG
kubectl -n noetl delete pods -l app=noetl-server --wait=false
kubectl -n noetl delete pods -l app=noetl-worker --wait=false
kubectl -n noetl rollout status deploy/noetl-server --timeout=180s
kubectl -n noetl rollout status deploy/noetl-worker --timeout=180s

# 4. Port-forward
pkill -f "kubectl.*port-forward.*8082:8082" 2>/dev/null || true
sleep 2
kubectl -n noetl port-forward svc/noetl 8082:8082 > /tmp/pf.log 2>&1 &
sleep 3
curl -sf http://localhost:8082/api/health

# 5. Register
( cd repos/noetl && python -c "
import json
with open('tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml') as f:
    content = f.read()
print(json.dumps({'content': content, 'resource_type': 'Playbook'}))
" > /tmp/register.json )
VERSION=$(curl -sS -X POST http://localhost:8082/api/catalog/register \
  -H "Content-Type: application/json" --data-binary @/tmp/register.json \
  | python -c "import json,sys; print(json.load(sys.stdin)['version'])")
echo "Registered version=$VERSION"

# 6. Reset
kubectl -n postgres exec deploy/postgres -- psql -U demo -d demo_noetl -c "
DELETE FROM public.pft_test_patient_work_queue;
DELETE FROM public.pft_test_patient_ids_work;
DELETE FROM public.pft_test_facility_data_type_done;
DELETE FROM public.pft_test_patient_assessments;
DELETE FROM public.pft_test_patient_conditions;
DELETE FROM public.pft_test_patient_medications;
DELETE FROM public.pft_test_patient_vital_signs;
DELETE FROM public.pft_test_patient_demographics;
DELETE FROM public.pft_test_mds_assessment_details;
DELETE FROM public.pft_test_mds_assessment_ids_work;
DELETE FROM public.pft_test_validation_log;
UPDATE public.pft_test_facilities SET active = TRUE;"

# 7. Kick off
EXEC=$(curl -sS -X POST http://localhost:8082/api/execute \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"tests/fixtures/playbooks/pft_flow_test/test_pft_flow\", \"version\": $VERSION}" \
  | python -c "import json,sys; print(json.load(sys.stdin)['execution_id'])")
echo "Execution id=$EXEC"
echo "$EXEC" > /tmp/pft_exec_id
date

# 8. Wait for terminal event
until [ "$(kubectl -n postgres exec deploy/postgres -- psql -U demo -d noetl -At -c "
  SELECT COUNT(*) FROM noetl.event WHERE execution_id = $EXEC
    AND event_type IN ('workflow.completed','workflow.failed','execution.failed');" \
  2>/dev/null | tr -d '\r\n ')" -ge 1 ]; do sleep 30; done
date
kubectl -n postgres exec deploy/postgres -- psql -U demo -d noetl -At -c "
  SELECT event_type FROM noetl.event WHERE execution_id = $EXEC
    AND event_type IN ('workflow.completed','workflow.failed','execution.failed');"
```

Save the above as `repos/ops/automation/development/run_pft.sh` if
you want it committed — otherwise just paste into a shell.  Don't
commit a script without the user's sign-off.
