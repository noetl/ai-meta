# GKE Runtime Reaper + PFT v2 Amber

Date: 2026-05-15

## Summary

NoETL, the PFT paginated test API, and the runtime reaper (`repos/doctor`)
were deployed to GKE project `noetl-demo-19700101`, cluster
`gke_noetl-demo-19700101_us-central1_noetl-cluster`.

The GKE PFT v2 run is **AMBER, not complete**. It proved the full
facility-1 path, including MDS detail fetching and validation, then
advanced into facility 2. The remaining task is to keep monitoring the
same execution to completion or make an explicit decision to cancel and
rerun with a smaller/targeted workload.

## Deployed Images

- NoETL: `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:pft-reaper-20260515-181717`
- PFT test server: `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/test-server:pft-reaper-20260515-181717`
- Runtime reaper doctor MCP: `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl-doctor:pft-reaper-detect-healthy-20260515-190740`

## GKE Execution

- PFT v2 execution id: `627490002867323540`
- Started: `2026-05-15T18:30:37Z`
- Last known status: running, facility 2 in progress.
- Facility 1 completed and validated:
  - assessments: `1000/1000`
  - conditions: `1000/1000`
  - medications: `1000/1000`
  - vital signs: `1000/1000`
  - demographics: `1000/1000`
  - assessment queue: `1000/1000`
  - MDS expected/details done: `22630/22630`
- Last facility-2 snapshot:
  - assessments: `1000 done`
  - conditions: `983 done`, `17 claimed`
  - medications, vital signs, demographics: pending at that snapshot.

## What Was Fixed During GKE Validation

`repos/doctor/playbooks/provision_doctor_mcp.yaml`

- Fixed generated Kubernetes YAML for optional `NOETL_DOCTOR_PG_DSN`.
- The playbook now applies a stable manifest and patches/removes the
  optional secret-backed env var separately, avoiding indentation drift in
  the shell-generated manifest.

`repos/doctor/playbooks/detect_stuck_executions.yaml`

- Fixed runtime reaper false positives for long-running healthy commands.
- Before the fix, `noetl-doctor detect` flagged long-running
  `fetch_mds_details:task_sequence` commands as stale when their owning
  workers were healthy and heartbeating.
- After the fix, `CLAIMED`/`RUNNING` commands are only reported stale when
  the owning worker row is missing, unhealthy, missing heartbeat, or has a
  stale heartbeat. Healthy long-running work now reports `severity: ok`.
- Local validation after the fix:
  - `cargo test --quiet`: `10` unit + `4` integration tests passed.
  - `cargo clippy --all-targets -- -D warnings`: clean.
- Rebuilt and redeployed doctor image:
  `noetl-doctor:pft-reaper-detect-healthy-20260515-190740`.

## Runtime Observations

- NATS briefly rescheduled during facility-1 MDS:
  - server logs showed
    `ConnectionRefusedError: [Errno 111] Connect call failed ('34.118.228.11', 4222)`.
  - `nats-0` pod events showed a GKE reschedule with
    `Multi-Attach error ... Volume is already exclusively attached`, then
    successful attach and recovery.
  - The PFT execution survived and continued; facility 1 later validated.
- NoETL API status occasionally failed under database pool pressure:
  - `the pool 'noetl_server' has already 50 requests waiting`
  - `couldn't get a connection after 30.00 sec`
  Direct Cloud SQL probes through an in-cluster `postgres:17` pod were more
  reliable for monitoring.
- Facility 1 default workload is large on GKE. Facility 1 alone took about
  `54m` and produced `22630` MDS detail rows. A full 10-facility run is
  expected to take hours unless the fixture/playbook workload is reduced.
- Doctor detect snapshots:
  - Initial during healthy long-running MDS: false-positive `severity:
    anomaly` before the detector fix.
  - After detector fix and redeploy: `severity: ok`.
  - A later transient pending command at `62s` cleared after one recovery
    interval; the follow-up detect returned `severity: ok`.

## Important Local State

The following submodules are dirty and should be handled with separate
branches/PRs; do not revert them accidentally:

- `repos/doctor`: modified `playbooks/provision_doctor_mcp.yaml` and
  `playbooks/detect_stuck_executions.yaml` from the GKE validation fixes.
- `repos/e2e`: PFT v2 fixture/test API changes from earlier validation.
- `repos/noetl`: command claim/recovery related local edits from earlier
  workstream.
- `repos/ops`: deployment value changes from earlier local/GKE workstream.
- `repos/docs`: runtime reaper documentation changes from earlier doc refresh.

## Recommended Next Steps

1. GKE execution `627490002867323540` was later cancelled during tutorial
   validation because it was saturating the NoETL API/database pool.
2. Prefer in-cluster SQL probes over the NoETL status API while the server
   pool is saturated.
3. Open a branch/PR in `repos/doctor` for the two playbook fixes:
   - stable optional DSN env patching in `provision_doctor_mcp.yaml`
   - healthy-worker exclusion in `detect_stuck_executions.yaml`
4. After the doctor PR merges, bump the `repos/doctor` submodule pointer in
   `ai-meta`.
5. Consider a follow-up NoETL/GKE ops task for API DB pool pressure and
   NATS scheduling resilience observed during high-volume MDS.

## Follow-up Tutorial Validation

Later on 2026-05-15, the internet-to-Postgres-to-GCS tutorial flow was
validated on the same GKE cluster.

- Workload Identity playbook execution `627592523359191239` completed and
  wrote:
  `gs://noetl-demo-output/noetl/tutorial/demo-workload-identity/github_repo_627592523359191239.csv`
- HMAC playbook execution `627592528442687692` completed and wrote:
  `gs://noetl-demo-19700101/noetl/tutorial/demo-hmac/github_repo_627592528442687692.csv`
- Command-table verification for both executions showed all rows
  `COMPLETED` with `error = null`.
