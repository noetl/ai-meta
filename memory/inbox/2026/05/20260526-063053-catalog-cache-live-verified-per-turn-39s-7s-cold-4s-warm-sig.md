# Catalog cache live-verified: per-turn 39s -> 7s cold / 4s warm; signal correct
- Timestamp: 2026-05-26T06:30:53Z
- Author: Kadyapam
- Tags: noetl,inline-execution,perf,verification,closed,pr611

## Summary
PR #611 deployed (inline-cache-20260526062141, Helm rev 165). Live verification on GKE itinerary-planner workload: Turn 1 Helsinki cold-cache 7s; Turn 2 Copenhagen warm-cache 4s. Comparison across the full arc: pre-#610 placeholder path 10s (signal wrong), post-#610 uncached catalog 39s (signal right, perf bad), post-#611 cold 7s and warm 4s (signal right AND perf better than pre-#610). The cache restoration overshot the original 10s target. Signal preserved: Turn 2 events still show inline=True from allow_list mode with real tool:ok:step[i].kind=python reasoning, confirming no regression from #610. Inline-execution arc now complete for Round A foundation: 5 PRs (#607 case-action batching, #608 detector + dry_run, #609 meta.inline_decision projection, #610 catalog fallback, #611 catalog cache) all merged + live-verified on GKE. The detector is now signal-correct AND perf-clean. Live cluster: Helm rev 165 with image inline-cache-20260526062141 (cumulative noetl HEAD 38d14a6e). Memory inbox now at 21 entries; /memory-compact is the longest-overdue queued item. Active thread 2026-05-26-noetl-inline-trivial-children remains active; Round B (proceed with inline implementation) is the natural next dispatch — foundation is solid.

## Actions
-

## Repos
-

## Related
-
