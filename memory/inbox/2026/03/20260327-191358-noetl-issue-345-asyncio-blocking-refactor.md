# noetl issue 345 asyncio blocking refactor
- Timestamp: 2026-03-27T19:13:58Z
- Author: Kadyapam
- Tags: issue-345,asyncio,blocking,worker,refactor,http

## Summary
Worker asyncio blocking root cause identified (issue #345): sync httpx.Client inside async execute_http_task (executor.py:345), sync retry.py with time.sleep, ThreadPoolExecutor+asyncio.run bridge in v2_worker_nats.py:1878 and execution.py:177, workbook/executor.py:159 stale sync assumption, sync secrets.py credential fetch. Refactoring tracked in 5 tracks: Track 0 fix executor.py async client, Track 1 add execute_with_retry_async, Tracks 2-3 remove sync bridges in worker+execution+workbook, Track 4 async secrets path. Feature flag NOETL_HTTP_ASYNC_RETRY=true for rollout. Root cause and plan posted as comments on noetl/noetl#345.

## Actions
-

## Repos
-

## Related
-
