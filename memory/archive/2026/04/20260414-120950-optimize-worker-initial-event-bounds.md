# Optimize worker initial event bounds
- Timestamp: 2026-04-14T12:09:50Z
- Author: Kadyapam
- Tags: worker, optimization, performance, events

## Summary
The previous agent identified that informative initial events (command.started, step.enter) for hot-path task_sequence steps were holding up the worker for 1.2 to 2.5 seconds on average due to network or server overload. I fixed the tests that failed due to lack of mocks for NATS KV output externalization, verified all tests pass, and pushed the optimization to make these events non-blocking on hot paths.

## Actions
-

## Repos
-

## Related
-
