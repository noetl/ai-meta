# Refactor nested engine and stabilize loop execution
- Timestamp: 2026-04-13T03:30:25Z
- Author: Kadyapam
- Tags: engine, refactor, nats, tests, database

## Summary
Renamed double nested engine package to executor. Implemented NATS KV loop collection methods, removed redundant internal imports, added idempotency index to Postgres, and upgraded test suites to canonical v10 specs.

## Actions
- Verified `repos/noetl` local commit `e5bd2045` includes `NATSKVCache.get_loop_collection()` and `save_loop_collection()` plus the executor package rename, while the live cluster was still serving an older image without those methods.
- Verified execution `603677866533847170` was a stale ghost run: status remained `RUNNING`, but the last event was `2026-04-12 22:00:21 UTC`, there were `0` new events in the last 10 minutes, and no queue rows remained in `demo_noetl`.
- Confirmed newer v10 runs were failing immediately in `events.batch` with missing loop-cache methods:
  - `603744798641488488` / `603739647583191573`: missing `get_loop_collection`
  - `603749923695100603` / `603750165043741455`: missing `save_loop_collection`
- Redeployed local `repos/noetl` and `repos/ops` through `repos/ops/automation/development/noetl.yaml`, which produced `local/noetl:2026-04-12-20-37`, then `local/noetl:2026-04-12-20-44`.
- Found and fixed a startup regression introduced by the local refactor: `noetl.server.app` called `init_pool(get_pgdb_connection(), max_size=64)` even though `init_pool()` only accepts `conninfo`. Reverted the call to `await init_pool(get_pgdb_connection())`.
- Validated the new server pod on `local/noetl:2026-04-12-20-44` starts cleanly, exposes both loop-collection methods in `/opt/noetl/noetl/core/cache/nats_kv.py`, and initializes the DB pool with env-driven sizing (`min=4 max=64 waiting=512`).
- Cancelled the stale v10 executions and launched fresh validation run `603855207864206271` after the old replica set drained.
- Verified the fresh run no longer fails in `claim_patients_for_assessments`:
  - after ~12s: `batch.completed=75`, `call.done=51`, `batch.failed=0`
  - after ~62s: facility 1 assessments `100 done / 900 pending`
  - after ~111s: facility 1 assessments `170 done / 30 claimed / 800 pending`, `loop.done=1`, `batch.failed=0`
- Noted a remaining non-blocking test debt after the package rename: `tests/api/test_v2_db_resilience.py` still monkeypatches `noetl.server.api.core.get_pool_connection`, but that symbol is no longer re-exported from the package.

## Repos
- `repos/noetl`
  - local `main` at `e5bd2045 fix: rename double nested engine to executor and stabilize v10 loop execution`
  - local hotfix applied after review: remove unsupported `max_size=64` kwarg from `noetl/server/app.py` startup path
- `repos/ops`
  - local branch `fix/bootstrap-postgres-external-service` at `7bed212 fix: increase db memory and connection pool limits for high parallel workloads`

## Related
- Execution investigated: `603677866533847170`
- Fresh validation run after corrected redeploy: `603855207864206271`
- Related stale/restarted executions: `603739647583191573`, `603744798641488488`, `603749923695100603`, `603750165043741455`, `603854417917379426`
