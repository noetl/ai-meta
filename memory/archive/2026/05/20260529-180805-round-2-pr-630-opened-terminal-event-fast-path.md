# Round-2 PR #630 opened: terminal-event fast path
- Timestamp: 2026-05-29T18:08:05Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,pr-630

## Summary
Replaces save_state with new save_state_terminal_lightweight in the state.completed early-return branch of _handle_event_inner (events.py:378-388). Lightweight variant only UPDATEs last_event_id + updated_at — no to_dict, no json.dumps, no state JSONB rewrite. Targets the ~1227ms wasted-work tail surfaced by Round-1 instrumentation (#629). Two new unit tests; full tests/unit/dsl/engine/ (87) passes. PR: noetl/noetl#630. Sub-issue: noetl/noetl#631. Umbrella: noetl/ai-meta#29.

## Actions
-

## Repos
-

## Related
-
