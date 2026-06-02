# Round-4 verification: cascade batched INSERTs delivered -58% p90 / -80% max on persist_event_compat
- Timestamp: 2026-05-29T22:46:47Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,round-4-verified

## Summary
Round-4 image cascade-20260529223610 (helm rev 184) deployed. n=60 batch.completed events. cg=0 results: persist_event_compat_ms p90 272->113 (-58%), max 581->117 (-80%). Bonus: save_state_ms p90 197->91 (-54%) — secondary effect from reduced DB contention. engine_total_ms p90 459->214 (-53%). pms p90 475->229 (-52%). The 2.0 calls/event semantic counter unchanged. Round-5 target queued: save_state coalescing inside one handle_event (mirrors round-4 shape). #29 stays open. Pointer bumps to 25258a0d (release 2.103.3).

## Actions
-

## Repos
-

## Related
-
