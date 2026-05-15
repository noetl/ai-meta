# barrier-4 stall root cause: reference-only envelopes + strict arc eval
- Timestamp: 2026-04-20T09:56:08Z
- Author: Kadyapam
- Tags: noetl,engine,arc-evaluation,postgres,pft,test_pft_flow

## Summary
Stalled v94 test diagnosed — load_patients_for_demographics call.done returned a reference-only envelope; mark_step_completed's silent except swallowed any resolve failure, so output.data.rows raised under StrictUndefined. _evaluate_condition caught the exception and returned False for both exclusive arcs, making the engine declare is_dead_end_no_match and emit workflow.completed prematurely. Two fixes landed: postgres keeps SELECTs with <16 rows inline (no TempStore indirection for scalar queries); engine now surfaces arc-eval 'raised' status and skips dead-end completion when any arc raised. Commits: noetl d6391a6a, 7f31664d; ai-meta e081cc5.

## Actions
-

## Repos
-

## Related
-
