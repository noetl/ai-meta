# Round-5 verification: save_state coalescing delivered -87% p90 / -82% max; #29 closed
- Timestamp: 2026-05-29T23:13:59Z
- Author: Kadyapam
- Tags: perf,batch,issue-29,round-5-verified,closed

## Summary
Round-5 image coalesce-20260529230422 (helm rev 185) deployed. n=18 cg=0 events. save_state_ms p90 91.17->11.58 (-87%), max 157.42->27.58 (-82%). engine_total_ms p90 214->76 (-65%). pms p90 229->140 (-39%). pms max 1151->264 (-77%). save_state_coalesced_count=2.0 on EVERY event (100% coverage). Cumulative across all 5 rounds: cg=0 pms max 1262 -> 264 (-79%). The dominant pathology that motivated #29 is gone. noetl/ai-meta#29 closed with 5-round summary. Pointer bumps to 59f7053a (release 2.103.4).

## Actions
-

## Repos
-

## Related
-
