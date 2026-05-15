# PFT cursor run blocked on MDS child command pending backlog
- Timestamp: 2026-04-21T23:15:08Z
- Author: Codex
- Tags: noetl,pft,cursor-loop,subplaybook,pending-commands,recovery

## Summary
Picked up the cursor-loop handover from ai-meta `main` at `d9b9a89`, synced submodules to `repos/noetl` `c81e9910` and `repos/docs` `8da084b`, read the handover + `20260421-*` memory entries + cursor loop design/status docs, then redeployed with the ops playbook and the required podman kind-node retag. Applied two local noetl fixes before the acceptance run:

- `tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml`: replaced downstream `load_next_facility.context.rows[0].facility_mapping_id | int` SQL references with `ctx.facility_mapping_id | int`. Reason: prior handover run `610209020581774041` had all five facility-1 cursor loops emit `loop.done`, but every `mark_*_done` SQL failed because `{{ load_next_facility.context... }}` reached Postgres unrendered from loop.done-triggered mark commands. The command render context had `ctx.facility_mapping_id=1` but no `load_next_facility`.
- `noetl/server/api/core/recovery.py`: changed publish-recovery query to compare `meta->>'command_id' = %s::text`. Reason: server logs showed repeated `operator does not exist: text = bigint` recovery errors.

Validation before deploy: `python -m py_compile noetl/server/api/core/recovery.py` and YAML parse of `test_pft_flow.yaml` both passed. Deployed image tag `local/noetl:2026-04-21-15-51`; retagged inside podman kind node to `docker.io/library/local/noetl:2026-04-21-15-51` and `docker.io/local/noetl:2026-04-21-15-51`; server and worker rollouts succeeded.

Registered PFT playbook as version `13` and MDS worker as version `4`. Reset PFT tables and confirmed `10|10` facilities active before kickoff. Started one run:

- execution id: `610233937423500095`
- no manual SQL/table/pod/image intervention after kickoff

Progress:

- Facility 1 reached full green: all five data types `1000/1000`, barrier count `1|5`, validation log row with all five columns = `1000`, facility 1 marked inactive.
- Facility 2 reached data green: all five data types `1000/1000`; all five cursor loops emitted `loop.done`; barrier count reached `2|5`.
- No `command.failed`, `step.failed`, `workflow.failed`, or `execution.failed` events were observed for the parent execution.

Blocker:

The run stalled in MDS sub-playbook processing after facility 2. Parent-side MDS state showed duplicate MDS dispatch and then no movement:

- Parent `run_mds_batch_workers` commands: `COMPLETED|20`, `RUNNING|48`, `PENDING|52`.
- Child commands for `parent_execution_id=610233937423500095`: `COMPLETED|80`, `PENDING|33`, unchanged after a real 60-second wait.
- Child events: `workflow.initialized|63`, `playbook.initialized|63`, `workflow.completed|20`; no child failed events.
- Server logs show the recovery fix is active (`[PUBLISH-RECOVERY] Command unclaimed after 30.0s; re-publishing ...`) and no longer crashing with `text = bigint`, but the 33 child commands remained pending.

Acceptance status: **blocked / not accepted**. The cursor loop portion reached facility 2 data green, but the full 10-facility run did not complete and got stuck in MDS child command publication/claim progress. Next session should start by inspecting the sub-playbook command publication/claim path for child executions spawned by `run_mds_batch_workers`, plus why multiple `prepare_mds_work` / `run_mds_batch_workers` batches were created after facility 2 barrier completion.

