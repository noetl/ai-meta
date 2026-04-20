# PFT injected SYNTAX_ERROR fixture removed; facility 1 1000/1000 green
- Timestamp: 2026-04-20T04:02:03Z
- Author: Kadyapam
- Tags: noetl,pft,playbook,debug-fixture-removed,phase-1,validation,memory-tuning

## Summary
Investigated 999/1000 demographics shortfall on facility 1 in PFT execution 608894741354119371. Found deliberate SQL syntax error injection at test_pft_flow.yaml line 1161-1162 in fetch_demographics save step targeting patient_id == 15. Save step's policy ('do: continue' on error) swallowed the error and mark_done ran anyway, leaving queue done without data row. Removed the injection (noetl 39c426a4). Bumped noetl-worker resource limits 512Mi -> 2Gi (cpu 500m -> 1000m) to align with Helm values; deployed override was below Helm. Fresh execution 608915806969135579 on phase-1 image localhost/local/noetl:2026-04-19-19-33: 70k+ events in ~30 min, 0 command/batch/playbook/workflow .failed events, facility 1 fully validated 1000/1000 on assessments + conditions + medications + vital_signs + demographics. mark_facility_processed ran (active_facs went 10 -> 9). Test continuing through facilities 2-10. The injection was committed as a debug probe for silent-failure detection but left the playbook permanently red against its own go/no-go criterion. If silent-failure detection is needed, do it via a dedicated fixture (e.g. test_silent_failure.yaml).

## Actions
-

## Repos
-

## Related
-
