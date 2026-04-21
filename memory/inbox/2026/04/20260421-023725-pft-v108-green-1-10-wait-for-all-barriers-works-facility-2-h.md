# PFT v108 green=1/10 — wait_for_all_barriers works; facility 2 hits fetch-loop stuck claims
- Timestamp: 2026-04-21T02:37:25Z
- Author: Kadyapam
- Tags: noetl,pft,test_pft_flow,partial-green,wait-for-all-barriers,fetch-loop-race

## Summary
First fully green facility! wait_for_all_barriers fan-in step (routes all mark_X_done unconditionally, polls barrier count via pg_sleep+SELECT multi-statement) successfully got facility 1 through the complete pipeline (5 barriers → prepare_mds_work → MDS batches → validate → log → mark_facility_processed → load_next_facility). Facility 2 then stalled at 9966/10000 done_q (34 patients stuck in 'claimed' across assessments/conditions/medications/vital_signs). Root cause: fetch_X task_sequence loop has iterations that never complete — loop engine still dispatching but some batches hang indefinitely, leaving fetch_X loop incomplete, load_patients_for_X stops firing so the 5-min reclaim doesn't trigger. This is the same pre-existing fetch-race bug observed in v105/v107, just postponed to facility 2 by the claim_batch_size=1000 + wait_for_all_barriers workarounds. Next attack surface is the fetch_X loop engine — not a playbook fix. Commits on noetl: 7fe039b4 (multi-statement wait_for_all_barriers), bff9091d (wait_for_all_barriers step), e74adc13 (claim_batch_size=1000), b697053f (done_count CTE fix), 66aefe22 (nest rows in context), f862434f, acfcc70c, 086a4cdf, 3621a74f, 26cdb1c5, 7f31664d, d6391a6a, 8dc17f6c.

## Actions
-

## Repos
-

## Related
-
