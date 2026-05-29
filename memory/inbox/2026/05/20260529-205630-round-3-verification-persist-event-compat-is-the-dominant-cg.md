# Round-3 verification: persist_event_compat is the dominant cg=0 cost
- Timestamp: 2026-05-29T20:56:30Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,round-3-verified

## Summary
Round-3 image subphase-20260529183255 (helm rev 183) running. Sub-phase breakdown on n=60 events: cg=0 persist_event_compat p90=272ms / max=581ms (59% of engine_total p90 459ms), save_state p90=197/max=342 (28%). Both fire 2x per handle_event (cascading completion events workflow.completed -> playbook.completed). terminal_lightweight_calls=0 (the #630 patch still cold). cg=1: persist=0 (already_persisted=True path) so engine work is just save_state p90=84ms. Round-4 target: batch the 2x INSERTs into one execute_values call inside _handle_event_inner. Findings on noetl/ai-meta#29. Pointer bumps to ce9d5351 (release 2.103.2).

## Actions
-

## Repos
-

## Related
-
