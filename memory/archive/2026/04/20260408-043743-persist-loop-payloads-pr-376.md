# Persist loop payloads PR 376
- Timestamp: 2026-04-08T04:37:43Z
- Author: Kadyapam
- Tags: pr, engine, serialization, bug-fix

## Summary
Diagnosed the root cause of the silent loop stall: _persist_event was truncating the loop_event_id out of the JSON result column due to an overly strict shape constraint that dropped keys. Fixed the engine serialization logic to nest the payload correctly under context, pushed to PR 376, and deployed.

## Actions
-

## Repos
-

## Related
-
