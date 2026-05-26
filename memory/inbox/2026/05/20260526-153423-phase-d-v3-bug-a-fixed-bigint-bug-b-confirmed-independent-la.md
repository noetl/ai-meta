# Phase D v3 — Bug A fixed (bigint), Bug B confirmed independent (last-step result semantics)
- Timestamp: 2026-05-26T15:34:23Z
- Author: Kadyapam
- Tags: noetl,inline-execution,phase-d,bug,result-envelope,pr-612,pr-614

## Summary
Phase D re-run after PR #614 merged (helm rev 168, image inline-runner-v3-20260526074734 from v2.102.2, NOETL_INLINE_TRIVIAL_CHILDREN=enforce). Execution 635359538601788321: duration 1.337s. Bug A FIXED: child execution_id is now 18 digits (465179147430762901), fits PostgreSQL bigint. Events endpoint returns clean 404 'Execution not found' instead of 500 bigint overflow. Detector returns inline=True. Runner FIRES — parent's call.done meta.inline_mode=worker + meta.inlined_in_parent. Bug B CONFIRMED INDEPENDENT: parent's call.done result.context.data is still {status:ok}, NOT the vertex-ai-stub canned diagnosis. Worker logs show Python step DID execute: 'PYTHON.EXECUTE_PYTHON_TASK: Captured result variable, type=dict' and 'inline result (1799b)' for canned_chat_completion step. Then '[RESULT] Step end: inline result (15b)'. The runner's last_result = the LITERAL last step's result, but vertex-ai-stub ends with a noop 'end' step that returns {status:ok}. The dispatched path surfaces the last MEANINGFUL step's result. This is a runner-side defect in result envelope construction (inline_runner.py line 459 'data=last_result'). Worker reverted to dry_run on GKE. Two ways forward: (1) quick hack: skip noop end-step in last_result tracking; (2) proper fix: study dispatched-path result extraction semantics and mirror them. Child events stream returns 404 — separate concern, no Execution row created for inline child id. Will plan with user.

## Actions
-

## Repos
-

## Related
-
