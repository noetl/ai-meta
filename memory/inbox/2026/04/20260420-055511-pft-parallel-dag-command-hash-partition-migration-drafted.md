# PFT parallel DAG + command hash-partition migration drafted
- Timestamp: 2026-04-20T05:55:11Z
- Author: Kadyapam
- Tags: noetl,pft,playbook,parallel-dag,partitioning,perf,phase-1

## Summary
Restructured test_pft_flow to fan out 5 data types per facility in parallel via setup_facility_work mode:inclusive arcs to all load_patients_for_<X> heads. Each data-type chain ends at mark_<X>_done (5 hardcoded steps) which atomically INSERTs into pft_test_facility_data_type_done and SELECTs done_count; only the 5th INSERT (done_count=5) advances to prepare_mds_work. Tried single-step-with-arc-set first (v91) but arc-level set: ctx.completed_data_type didn't propagate into the target step's command rendering — barrier rows never appeared. 5 hardcoded steps avoids the engine quirk. Also fixed a latent bug exposed by parallel DAG: load_patients_for_X remaining_count counted only status='pending', missing in-flight 'claimed' rows, so mark_X_done fired prematurely. Changed to status IN ('pending','claimed'). Postgres planning overhead diagnosed as a major performance ceiling: dropped 8 empty noetl.event partitions (event_pre_2026, _2026_q1..q4, _2027_h1, _h2, _2026_gke), all data was landing in event_default — 122ms planning -> 6ms (20x). Drafted migrate_command_to_hash_partitioned.sql to convert noetl.command to 16 HASH partitions on execution_id, including idempotency guard, online table-rename + INSERT SELECT pattern, and updated schema_ddl.sql to use the partitioned layout for fresh deploys. PRIMARY KEY changes from (command_id) to (execution_id, command_id) per Postgres partitioned-UNIQUE rule. Same hash scheme planned for noetl.event in a follow-up.

## Actions
-

## Repos
-

## Related
-
