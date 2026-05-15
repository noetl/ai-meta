# PFT 10/10 GREEN — cursor-loop + MDS max_in_flight fix
- Timestamp: 2026-04-22T08:02:08Z
- Author: Kadyapam
- Tags: cursor-loop,pft,mds,deadlock,acceptance-passed,noetl

## Summary
Exec 610311969194639454 completed workflow.completed at 2026-04-21T19:22:42 PDT after ~42 min. All 10 facilities processed end-to-end: 50 rows in pft_test_facility_data_type_done, 10 rows in validation_log with every *_done column = 1000, 50 rows distinct-patient check all = 1000, all facilities flipped active=f, no step.failed / command.failed / workflow.failed events. Root cause of the Codex stall was a worker-pool deadlock: tool.kind: playbook with return_step polls for sub-playbook completion inside _execute_playbook, which holds the parent worker slot for the full sub-playbook duration. With max_in_flight=100 MDS batches and 3 workers × 16 in-flight = 48 slots, steady-state had ~500 active commands — parent polls saturated all slots, children couldn't claim → deadlock. Fix (commit 0bfbba6b on feat/storage-rw-alignment-phase-1): drop max_in_flight to 5 so steady-state ~= 5 parents × 5 children = 25 active, well under capacity. Combined with Codex's work (ctx.facility_mapping_id threading, query rewrites to noetl.command projection, NextSpec.on_no_match, stage-gate replacing wait_for_all_barriers polling, recovery publish-gate BIGINT fix) and Claude's cursor infra + row-preservation fix, the full PFT flow now passes acceptance. Total timeline ~4 min/facility; scales linearly.

## Actions
-

## Repos
-

## Related
-
