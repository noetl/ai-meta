# Bug: Server psycopg_pool Exhaustion Under Parallel MDS Batch Load — Checkpointer and Sweeper Stall

**Date**: 2026-04-17
**Execution**: 606972984493867082
**Image**: local/noetl:arm64-2b9dca28
**Status**: Open
**Component**: `noetl/core/db/pool.py`, `noetl/server/app.py` (_runtime_sweeper), `noetl/server/checkpointer.py`

---

## Summary

During peak parallel MDS batch processing (`run_mds_batch_workers`), the server-side
`AsyncConnectionPool` (max_size=16 by default) becomes fully exhausted. Postgres itself
shows all connections as `idle` after the burst, but the pool believes all slots are
checked out and never releases them. The checkpointer and runtime sweeper both fail
continuously with `PoolTimeout`, halting all state transitions for the active execution.

---

## Observed Errors

Server log — sweeper:

```
2026-04-17T13:03:51 [ERROR] noetl/server/app.py:270
(app:_runtime_sweeper:270)
    Message: Runtime sweeper loop error: couldn't get a connection after 3.00 sec
    psycopg_pool.PoolTimeout: couldn't get a connection after 3.00 sec
```

Server log — checkpointer:

```
(checkpointer:run:88)
    Message: [Checkpointer] shard=4 tick error: couldn't get a connection after 30.00 sec
    psycopg_pool.PoolTimeout: couldn't get a connection after 30.00 sec
    ...
    File "noetl/core/db/pool.py:145" in get_snowflake_id
      async with get_pool_connection() as conn:
```

Both errors repeat indefinitely. The execution is stuck at 26 completed steps /
`run_mds_batch_workers` with `failed=True` on the JSON surface (stale status lag),
while the human-readable surface still shows `RUNNING`.

NATS stream: 0 pending messages (workers drained the queue, pool stall happened
server-side, not worker-side).

---

## Environment at Time of Failure

| Parameter | Value |
|---|---|
| Pool max_size default | 16 (`NOETL_POSTGRES_POOL_MAX_SIZE`) |
| Postgres max_connections | 200 |
| Active Postgres connections | 23 total / 16 `idle in transaction` at peak |
| Concurrent MDS batches | Many parallel `fetch_mds_details` loops (50 items each) |
| Workers | 3 pods, concurrency limit ~4.2 each |

---

## Root Cause

The parallel `run_mds_batch_workers` step launches many concurrent MDS batch
sub-executions. Each sub-execution requires server-side DB connections for:

- `get_snowflake_id()` (connection per call, not pooled separately)
- command dispatch / state persistence
- checkpointer shards
- runtime sweeper lease renewal

Under sufficient parallelism, all 16 pool slots are simultaneously checked out.
Any new connection attempt — including the `_runtime_sweeper` (timeout=3s) and
`checkpointer` (timeout=30s) — queues. If the burst sustains longer than the timeout,
these background tasks start erroring out.

The pool does not appear to recover on its own: Postgres shows connections returned
(`idle` / `COMMIT`) but the pool internal state diverges, likely due to an error
mid-transaction that leaves a pool slot in an inconsistent state (not properly reclaimed).

Possible secondary factor: `get_snowflake_id()` uses `get_pool_connection()` without
an explicit timeout, which defaults to `_DEFAULT_POOL_TIMEOUT` (30s). Under contention
this holds the queue slot longer than the sweeper's 3s window, creating head-of-line
blocking.

---

## Impact

- Server pool reaches a permanent stall state that cannot self-recover.
- All running executions stall at the MDS batch phase (or any other high-parallelism step).
- The only recovery path is a server pod restart.
- All in-flight work dispatched to workers before the stall is lost (no requeue).

---

## Reproduction Steps

1. Run `test_pft_flow` with 100 patients against the cluster.
2. Wait for execution to reach `run_mds_batch_workers`.
3. Observe parallel `fetch_mds_details` loops completing (50/50 each) in server logs.
4. Shortly after, server logs show only repeated `PoolTimeout` from sweeper and checkpointer.
5. `noetl execute status <id>` step count stops advancing; NATS queue is empty.

---

## Proposed Fix

### Option 1 (Immediate): Increase pool max_size

Set `NOETL_POSTGRES_POOL_MAX_SIZE` in the server Deployment env to a higher value
(e.g. 32 or 48), giving headroom for background tasks during peak parallel dispatch.

```yaml
# k8s deployment env
- name: NOETL_POSTGRES_POOL_MAX_SIZE
  value: "32"
```

This is a band-aid but reduces frequency.

### Option 2 (Correct): Reserve connections for critical background tasks

The sweeper and checkpointer must not compete with command dispatch for the same pool.
Either:

- Create a dedicated small pool (`min_size=2, max_size=4`) for background tasks
  (`_runtime_sweeper`, `checkpointer`, `get_snowflake_id`), separate from the
  command-dispatch pool.
- Or enforce a reservation: the pool should always hold back N connections (2–4)
  for high-priority callers. `psycopg_pool` supports this via priority queuing or
  a semaphore guard.

### Option 3 (Defensive): Add connection-leak guard

Add a `max_idle_seconds` watchdog that logs pool stats and forcibly recycles
connections that have been checked out (in the pool's "in use" state) longer than
a threshold (e.g. 60s). This catches the divergence between pool state and Postgres state.

### Recommended approach

Implement Option 2 (dedicated pool for background tasks) alongside Option 1 as an
immediate mitigation. Option 3 adds defense-in-depth.

---

## Files to Change

| File | Change |
|---|---|
| `noetl/core/db/pool.py` | Add `_bg_pool` (background pool, small); expose `get_bg_pool_connection()` |
| `noetl/server/app.py` | `_runtime_sweeper` → use `get_bg_pool_connection()` |
| `noetl/server/checkpointer.py` | `_tick` → use `get_bg_pool_connection()` |
| `noetl/core/db/pool.py` | `get_snowflake_id()` → use `_bg_pool` |
| `noetl/server/k8s/` or Helm values | Add `NOETL_POSTGRES_POOL_MAX_SIZE: "32"` as interim |

---

## Related

- Fix #5 (2b9dca28): resolved synthetic placeholder leak in loop collection — confirmed
  working up to `run_mds_batch_workers` before pool exhaustion stalled the run.
- Execution 606972984493867082 reached 26/N completed steps before stalling — furthest
  PFT run to date.
