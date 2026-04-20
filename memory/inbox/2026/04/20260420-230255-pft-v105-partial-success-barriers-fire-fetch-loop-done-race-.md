# PFT v105 partial success — barriers fire, fetch loop.done race remains
- Timestamp: 2026-04-20T23:02:55Z
- Author: Kadyapam
- Tags: noetl,pft,test_pft_flow,fetch-race,loop.done,incomplete,in-progress

## Summary
Playbook rewrite (Option B) worked — ctx.facility_mapping_id replaced by SQL subqueries against pft_test_facilities. v105 processed 4952/5000 for facility 1 and fired barrier=2 before workflow.completed. Root cause chain found and fixed: (1) CTE snapshot semantics — mark_X_done done_count couldn't see its own barrier_insert row in the same statement; added '+ (SELECT COUNT(*) FROM barrier_insert)'. (2) Server _build_reference_only_result was picking payload.result (trimmed) over payload.response (full rows) — fixed to prefer whichever has rows. (3) event_result_check DB constraint forbids top-level non-allowed keys — nested rows inside result.context instead. (4) engine dead-end check didn't track arc-raised on step.exit fallback — added probe. Outstanding: fetch_assessments loop.done race lost 48 iterations (fetch count 952 instead of 1000), blocking 3 of 5 mark_X_done barriers (assessments, conditions, vital_signs never hit 1000 data_count). This is the v2.14.7 loop.done race, predates my work. Commits today (noetl): 8dc17f6c, d6391a6a, 7f31664d, 26cdb1c5, f862434f, 086a4cdf, 3621a74f, acfcc70c, 66aefe22, b697053f, + debug reverts.

## Actions
-

## Repos
-

## Related
-
