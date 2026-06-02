# Round-5 PR #637 opened: save_state coalescing
- Timestamp: 2026-05-29T22:55:29Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,pr-637

## Summary
Mirrors round-3 contextvar pattern: handle_event binds a save_state coalescing buffer; intermediate calls stash (state, conn); one flush at handle_event exit. New batch.completed.context field save_state_coalesced_count surfaces elided UPDATEs. save_state_ms_calls counter unchanged (semantic counter). Ordering invariant change: post-round-5 the projection flush is LAST operation in handle_event — textbook event-sourcing order. 1 existing test updated to reflect new ordering with explanation; 2 new tests added. Full tests/unit/dsl/engine/ (95) passes. PR noetl/noetl#637, sub-issue #636, umbrella noetl/ai-meta#29. Expected save_state_ms p90 91ms -> ~45ms.

## Actions
-

## Repos
-

## Related
-
