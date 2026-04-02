# noetl-pft-flow-mds-investigation-2026-04-02
- Timestamp: 2026-04-02T18:20:47Z
- Author: StanislavTuagrev
- Tags: noetl,engine,state-load,mds,pft-flow,sub-playbook,2026-04-02

## Summary
BHS pft_flow_test MDS investigation (2026-04-02). Key engine behavior confirmed: NOETL_INLINE_MAX_BYTES=65536. STATE-LOAD replays step-level set: blocks but NOT arc-level set: — arc-level ctx writes are lost on state reconstruction. Step-level input: at sibling-of-tool level (not inside tool:) creates restricted render scope in postgres steps — execution_id and other ctx vars become DebugUndefined (return literal template strings). For sub-playbooks (kind: playbook), input: values override workload defaults in the render context for that step, but downstream SQL steps must reference start.field_name (from the python start step result) not bare {{ field_name }} which resolves to workload default. query: results have top-level rows key; command: results use command_0.rows — normalize_batch must check for rows first. Open bug: run_mds_batch_workers only dispatches 1 batch worker despite build_mds_batch_plan computing 20; mds_ids=1000, last_page=1000, mds_details=50 for facility 2 — build_mds_batch_plan.batches accessible via simple-var opt should return list of 20 but loop only runs once. Needs further investigation next session.

## Actions
-

## Repos
-

## Related
-
