# Removed O(N^2) SQL parsing bottlenecks
- Timestamp: 2026-04-13T05:58:24Z
- Author: Kadyapam
- Tags: performance, worker, sql, duckdb, postgres

## Summary
Optimized render_duckdb_commands and render_and_split_commands by replacing the O(N^2) character-by-character string concatenation loop with a fast regex-based SQL splitter. This resolves a massive 1-5 second CPU bottleneck per loop iteration when playbooks insert large payloads via SQL commands.

## Actions
-

## Repos
-

## Related
-
