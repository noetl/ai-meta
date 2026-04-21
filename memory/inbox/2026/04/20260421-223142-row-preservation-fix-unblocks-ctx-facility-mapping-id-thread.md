# row-preservation fix unblocks ctx.facility_mapping_id threading; multi-facility cursor loops green
- Timestamp: 2026-04-21T22:31:42Z
- Author: Kadyapam
- Tags: cursor-loop,state,row-preservation,replay,noetl,pft

## Summary
Diagnosed and fixed the step_result row-stripping bug that blocked ctx.facility_mapping_id threading. Root cause: replay calls mark_step_completed TWICE per non-task-sequence step — once with call.done event.result (has context.rows for small result sets via _build_reference_only_result inline-rows) and once with step.exit event.result (scalars only, rows stripped). The second call overwrote step_results with a row-less snapshot. Downstream templates like {{ load_next_facility.context.rows[0].facility_mapping_id | int }} then silently rendered empty, and cursor claim SQL matched zero rows. Fix (state.py mark_step_completed, commit c81e9910): when the incoming result lacks rows/columns at top level or inside context but the prior step_result had them, merge forward. Preserves the inline-rows mechanism across the call.done -> step.exit pair. With this fix landed, the cursor-loop pipeline actually resolves load_next_facility.context.rows at worker time — proven by PFT run 610209020581774041 hitting facility 1 at 4999/5000 patients in ~4 min (previously stuck at 0/5000). Full 10-facility e2e run is in progress as of 2026-04-21 15:16 PDT.

## Actions
-

## Repos
-

## Related
-
