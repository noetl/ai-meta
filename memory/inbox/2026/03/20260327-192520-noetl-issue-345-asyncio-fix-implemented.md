# noetl issue 345 asyncio fix implemented
- Timestamp: 2026-03-27T19:25:20Z
- Author: Kadyapam
- Tags: asyncio,http,worker,fix,pr346,issue345

## Summary
All 5 tracks of asyncio blocking fix implemented and pushed as PR #346. Track 0: httpx.AsyncClient replaces sync httpx.Client in tools/http/executor.py. Track 1: execute_with_retry_async() added to retry.py (additive, sync kept). Track 2: v2_worker_nats.py ThreadPoolExecutor+asyncio.run bridge removed, uses await execute_with_retry_async. Track 3: workbook/executor.py HTTP path now direct await, execution.py uses asyncio.run(execute_with_retry_async). Track 4: fetch_credential_by_key_async() added to secrets.py, resolve_auth_map uses it. Branch: kadyapam/issue-345-asyncio-fix.

## Actions
-

## Repos
-

## Related
-
