# NoETL command reaper self-healing handoff

Date: 2026-05-14

Context:
- During PFT v2 validation on GKE, execution `626611573817082718` became stuck in `fetch_mds_details`.
- GUI/API/DB port-forwards had dropped, but after restoring them the execution was still non-terminal.
- Fixture tables showed facility `1` work was complete:
  - `pft_test_patient_work_queue`: `1000/1000` done for assessments, conditions, medications, vital signs, demographics.
  - `pft_test_mds_assessment_ids_work`: `22630/22630` done.
  - `pft_test_mds_assessment_details`: `22630` rows inserted.
- NoETL command state still had non-terminal MDS cursor worker commands:
  - `626615919199912327` stuck `RUNNING`.
  - `626615919199912335`, `626615919199912337`, `626615919199912339` stuck `CLAIMED`.
- Server/worker logs around `2026-05-14T14:02Z` showed command claim/network failures and active-claim duplicate ACK behavior. Kubernetes events showed node churn/system pod startup around the same period.

Diagnosis:
- This is a NoETL runtime self-healing gap, not just a PFT playbook issue.
- The claim endpoint has stale-claim policy (`noetl/claim_policy.py`, `noetl/server/api/core/commands.py`) and can reclaim a command when a worker calls `/commands/{event_id}/claim`.
- But after the command reaper was removed in `repos/noetl` commit `435e3aa6d2ffac04ee0b81cc5b3ee9dd6a3e6cbb` (`feat(execution): introduce execution table and remove reaper`), there may be no active background process to republish orphaned/stranded command notifications.
- Worker code still assumes this recovery exists: `noetl/worker/nats_worker.py` says duplicate active-claim notifications are ACKed because "the command reaper handles recovery".
- Tests still reference `noetl.server.command_reaper`, but `noetl/server/command_reaper.py` is absent in the checkout while `__pycache__` remains.

Recommended direction:
- Build a robust self-healing command reaper in `repos/noetl` using `noetl.command` as the primary source of truth.
- It should periodically find stale non-terminal commands (`PENDING`, `CLAIMED`, `RUNNING`) whose execution is not terminal and republish their original command notification to NATS.
- It should cooperate with the existing claim endpoint and claim policy rather than directly forcing completion.
- It should run under a `RuntimeLease`, like server control loops (`runtime_sweeper`, `auto_resume`), so only one server instance performs recovery.
- It should handle both:
  - orphaned active commands where worker heartbeat is stale/offline or healthy-worker hard timeout is exceeded;
  - stranded pending commands persisted in DB but never successfully delivered to NATS.
- Add a companion operational runtime reaper surface in the new `repos/doctor` submodule (`git@github.com:noetl/doctor.git`, currently pinned at `17967589f2b1463ec532028441df5d6862121d73`).
- `repos/doctor` should hold standalone NoETL runtime reaper playbooks and Dockerfiles for self-healing MCP servers/jobs. These should be callable by monitoring systems and should use the NoETL Rust CLI in local runtime mode to connect to NoETL services, validate stuck runtime symptoms, and run repair playbooks/tools.
- Division of responsibility:
  - `repos/noetl`: in-process runtime self-healing for command/event delivery correctness, especially orphaned command reclaim/republish.
  - `repos/doctor`: out-of-process runtime reaper diagnostics and repair jobs/MCP servers that monitoring can invoke for NoETL runtime state.

Validation target:
- Add regression tests for stale `fetch_mds_details:task_sequence` command rows stuck in `CLAIMED`/`RUNNING`, with stale worker heartbeat, and verify the reaper republishes them.
- Add a live PFT v2 rerun after the runtime fix: cancel/clean current PFT execution, register/run `fixtures/playbooks/pft_flow_test/test_pft_flow_v2`, and confirm it advances past MDS into the next facility.

Related files:
- `repos/noetl/noetl/claim_policy.py`
- `repos/noetl/noetl/server/api/core/commands.py`
- `repos/noetl/noetl/worker/nats_worker.py`
- `repos/noetl/noetl/server/app.py`
- `repos/noetl/tests/test_command_reaper.py`
- Historical source reference: `git -C repos/noetl show d937c10dc5438658519605f50dba8383083834ac:noetl/server/command_reaper.py`
- Current PFT v2 fixture work: `repos/e2e/fixtures/playbooks/pft_flow_test/test_pft_flow_v2.yaml`
- New runtime reaper repo: `repos/doctor`
