# issue 249 async batch acceptance implemented
- Timestamp: 2026-03-05T08:40:11Z
- Author: Kadyapam
- Tags: noetl,docs,issue-249,batch,async,kind,validation

## Summary
Implemented async /api/events/batch contract in repos/noetl (202+request_id, idempotency key retries, status+SSE endpoints, failure class codes, metrics, and tests), opened PR noetl/noetl#250 and docs PR noetl/docs#4, validated with targeted pytest and local kind API checks, and posted update on issue #249.

## Actions
- Pushed branch `codex/issue-249-async-batch-acceptance` to `noetl/noetl`.
- Opened PR: https://github.com/noetl/noetl/pull/250
- Pushed branch `codex/issue-249-async-batch-docs` to `noetl/docs`.
- Opened PR: https://github.com/noetl/docs/pull/4
- Commented issue update: https://github.com/noetl/noetl/issues/249#issuecomment-4003328758
- Deployed `local/noetl:2026-03-05-00-22` to local `kind-noetl` and validated async API behavior.

## Repos
- noetl/noetl: `b4a18e1e` (branch `codex/issue-249-async-batch-acceptance`)
- noetl/docs: `3ff1cad` (branch `codex/issue-249-async-batch-docs`)
- noetl/ai-meta: pending submodule pointer updates for `repos/noetl` and `repos/docs`

## Related
- https://github.com/noetl/noetl/issues/249
