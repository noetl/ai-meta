# Resolved test_pft_flow stall and analyzed NATS KV synchronization issues
- Timestamp: 2026-04-07T06:14:43Z
- Author: Kadyapam
- Tags: pft, stall, nats, cache, engine, bug-fix

## Summary
Analyzed the test_pft_flow execution stall, confirming it was caused by a stale state cache condition within the engine's distributed loop management rather than NATS key errors. Setting NOETL_STATE_CACHE_ALLOWED_MISSING_EVENTS=0 bypassed the cache, allowing the execution to successfully complete batches.

## Actions
-

## Repos
-

## Related
-
