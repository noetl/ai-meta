# Round-3 PR #633 opened: sub-phase timing instrumentation
- Timestamp: 2026-05-29T18:31:18Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,pr-633

## Summary
Splits engine_total_ms into 3 new accumulator pairs in batch.completed.context: save_state_ms (+calls), save_state_terminal_lightweight_ms (+calls), persist_event_compat_ms (+calls). Implementation uses contextvars.ContextVar so the timing_capture dict doesn't have to thread through 25 call sites — wrapped methods read from contextvar in finally:. No-op outside handle_event. Two new unit tests + full tests/unit/dsl/engine/ (89) passes. Sub-issue noetl/noetl#632. PR noetl/noetl#633. Umbrella noetl/ai-meta#29. After deploy + sample, dominant column picks round-4 target.

## Actions
-

## Repos
-

## Related
-
