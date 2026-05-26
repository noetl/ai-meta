# Catalog-lookup cache opened as noetl/noetl#611 to restore dry-run perf
- Timestamp: 2026-05-26T06:19:54Z
- Author: Kadyapam
- Tags: noetl,inline-execution,perf,cache,pr611

## Summary
Round A dry-run had a measured 4x slowdown after #610 (10s -> 39s per itinerary-planner turn on Helm rev 164) because each tool: agent step did a fresh POST /api/catalog/resource. PR #611 (kadyapam/inline-dry-run-catalog-cache, commit 244338dd): process-local cache in noetl/tools/agent/executor.py keyed by entrypoint, default 300s TTL, NOETL_INLINE_TRIVIAL_CHILDREN_CATALOG_CACHE_TTL_SECONDS env override (0 disables). Negative caching for 404/network errors so missing entries don't retry storms. Dry-run-only by env-gated caller chain; dispatched path unchanged. 5 new cache tests + 1 autouse fixture for cross-test isolation; 35 tests pass total. After merge + redeploy, per-turn duration target back to ~10s with signal still correct (mcp/firestore decisions show real tool:ok reasons, inline=True via allow_list mode). No changes to detector logic, dispatch behavior, or any earlier PR surface. Cumulative inline-execution arc: 5 PRs (607/608/609/610/611), all merged or open with live verification at each step. Round B (proceed with inline implementation) is still the natural next step after #611 lands; the dry-run path is now both signal-correct AND perf-clean.

## Actions
-

## Repos
-

## Related
-
