# Round-4 PR #635 opened: batch cascade event INSERTs
- Timestamp: 2026-05-29T22:31:04Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,pr-635

## Summary
Targets round-3 dominant column persist_event_compat_ms (p90=272ms, max=581ms, 2x calls/event for cg=0). New LifecycleMixin._persist_cascade_events: 1 query allocates N snowflake IDs via generate_series, 1 cached init-event lookup per init kind, 1 executemany INSERT, 1 cursor sequence for outbox. Three cascade sites in events.py patched (inline-task success, main success, failure). Conn=None falls through to per-event _persist_event_compat preserving test contract — 89 existing tests pass unmodified. 4 new tests cover empty/single/no-conn-loop/batched paths. Full tests/unit/dsl/engine/ (93) passes. PR noetl/noetl#635, sub-issue #634, umbrella noetl/ai-meta#29. Expected p90 drop 272ms -> ~135ms.

## Actions
-

## Repos
-

## Related
-
