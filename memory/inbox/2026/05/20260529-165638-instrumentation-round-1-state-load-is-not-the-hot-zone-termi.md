# instrumentation round-1: state_load is NOT the hot zone; terminal-event save_state is
- Timestamp: 2026-05-29T16:56:38Z
- Author: Kadyapam
- Tags: perf,batch,instrumentation,issue-29

## Summary
Per-phase timing #629 deployed (image batch-timing-20260529142451). n=84 batch.completed events sampled. state_load_ms p90=11ms (FLAT). engine_total_ms accounts for ~98% of processing_ms in the no-op-tail (1237/1261ms with cg=0). issue_commands_ms is the dominant cost when cg>0 (p90 298ms, max 934ms). Next mitigation: terminal-event fast path in _handle_event_inner lines 378-388 — skip save_state when state.completed=true on entry. Findings posted to noetl/ai-meta#29. The /api/postgres/execute endpoint is unauthenticated from inside the cluster — handy operator path for ad-hoc SQL when CLI sessions expire.

## Actions
-

## Repos
-

## Related
-
