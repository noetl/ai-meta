# PFT redeploy session — multiple engine fixes, test still not green
- Timestamp: 2026-04-20T14:29:46Z
- Author: Kadyapam
- Tags: noetl,engine,pft,test_pft_flow,replay,state,set-mutations,incomplete

## Summary
5-hour session attempting to get PFT flow test green after the barrier-4 stall diagnosis. Implemented and deployed 5 fixes across noetl (8dc17f6c true-completion check, d6391a6a inline small postgres rows, 7f31664d arc-raised safeguard, 26cdb1c5+f862434f+1344f1a6 preserve-rows in event.result + nested extraction + debug log, reverted 9abf5c9d replay filter). Discovered root cause: step-level set: expressions like {{ output.data.rows[0].facility_mapping_id }} are not replay-safe — event.result stores only compact envelope, rows are stripped, Jinja returns literal template string on replay, downstream | int coerces to 0, SQL breaks. Attempted preservation of rows in event.result but the serialized events still show no 'rows' key even though my test invocation of the function produces correct output — code path is not being exercised or something post-processes result_obj. NOT reproducing end-to-end green. Stalled execution tracker: v99 609243943930167738 ran 10 min no errors but stuck in mark/load loop (work queue all pending, never claimed). Two competing architectural issues: (1) state cache invalidation across multi-pod OR in-flight events forces replay, and (2) replay needs rich result payload but server strips rows via _build_reference_only_result. User should decide: either (a) make event.result preserve rows for small results (requires deeper investigation why my fix isn't saving rows to DB), or (b) rewrite playbook to avoid cross-step state propagation through set: — query facility_mapping_id directly in each SQL instead of passing via ctx.*.

## Actions
-

## Repos
-

## Related
-
