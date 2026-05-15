# cursor-loop infrastructure complete phases 1-5
- Timestamp: 2026-04-21T05:27:54Z
- Author: Kadyapam
- Tags: cursor-loop,engine,worker,noetl,pft

## Summary
Landed the pull-model cursor-loop primitive across the NoETL engine: CursorSpec + Loop model extension with validation, noetl.core.cursor_drivers registry + postgres driver (psycopg_pool AsyncConnectionPool, autocommit per claim), _issue_cursor_loop_commands dispatch that bypasses CAS/collection rendering and emits N worker commands tagged cursor_worker, noetl.worker.cursor_worker.execute_cursor_worker runtime that opens driver, loops claim-process-release via TaskSequenceExecutor, emits one call.done per worker on drain, and events/rendering guards that skip loop.in_ re-render and tail-repair for cursor loops (synthetic collection = range(worker_count)). All on feat/storage-rw-alignment-phase-1, pushed. Phase 6 (PFT playbook rewrite) and Phase 7 (e2e test) still pending.

## Actions
-

## Repos
-

## Related
-
