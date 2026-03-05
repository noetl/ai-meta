# issue 251 log flood suppression follow-up
- Timestamp: 2026-03-05T15:18:18Z
- Author: Kadyapam
- Tags: noetl,issue-251,logging,observability,ai-meta

## Summary
Added follow-up fix on noetl PR #252 to suppress uvicorn access logs for /api/health, /health, /api/pool/status, /metrics and worker register path; added NOETL_ACCESS_LOG_SUPPRESS_PATHS override and unit test. Also updated ai-meta AGENTS logging hygiene guidance to keep log volume minimal for high-frequency endpoints.

## Actions
- Pushed follow-up commit `71b5e7ab` to branch `codex/issue-251-recovery-playbook`.
- Updated issue with log-flood fix details: https://github.com/noetl/noetl/issues/251#issuecomment-4005820063
- Added `ai-meta/AGENTS.md` logging hygiene instructions to minimize high-frequency endpoint logs.

## Repos
- noetl/noetl: `71b5e7ab` (PR https://github.com/noetl/noetl/pull/252)
- noetl/ai-meta: pending pointer + memory commit

## Related
- https://github.com/noetl/noetl/pull/252
- https://github.com/noetl/noetl/issues/251
