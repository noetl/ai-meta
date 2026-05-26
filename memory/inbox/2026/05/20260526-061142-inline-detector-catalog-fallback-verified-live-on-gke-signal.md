# Inline detector catalog fallback verified live on GKE; signal is real
- Timestamp: 2026-05-26T06:11:42Z
- Author: Kadyapam
- Tags: noetl,inline-execution,dry-run,verification,closed,pr610,v2.101.2

## Summary
PR #610 deployed (inline-cat-fallback-20260526060402, Helm rev 164). Synthetic itinerary-planner execution 635089456629809409 (Stockholm) completed successfully and confirmed end-to-end that the catalog fallback fix is working. Pre-#610 reasoning was tool:block:step[0].missing_tool_kind + step[1].missing_tool_kind (12 events, all inline=false from placeholder). Post-#610 reasoning is tool:ok:step[0].kind=python + tool:ok:step[1].kind=python (8 tool:ok reasons across decisions, 0 missing_tool_kind, mcp/firestore calls now show inline=True via allow_list mode). The detector now sees the REAL firestore.yaml workflow via the catalog HTTP fallback. Allow-list mode is sufficient on its own — inline=True is reachable for automation/agents/mcp/* paths without needing metadata.inline_when_safe: true. One observation: per-turn duration went from 10s (pre-fix Reykjavik) to 39s (post-fix Stockholm); likely the per-agent-call catalog POST adds latency. For Round A dry-run that's acceptable. May warrant a cached lookup in a follow-up. ai-meta pointer bumped: repos/noetl fbc7716d -> f2c9fafb (v2.101.2 catches both #609 and #610 release tags). No wiki bump needed for #610 (internal fix; public contract unchanged). Active thread 2026-05-26-noetl-inline-trivial-children remains active; Round B (proceed with inline implementation) is the natural next step with the detector now producing accurate signals. Memory inbox now at 18 entries — /memory-compact is overdue. Cumulative Round A + visibility + catalog-fallback arc: 4 PRs (608/609/610 + the earlier 607 case-action batching), all merged, all backed by live cluster verification, dry-run experiment is now fully observable and signal-correct.

## Actions
-

## Repos
-

## Related
-
