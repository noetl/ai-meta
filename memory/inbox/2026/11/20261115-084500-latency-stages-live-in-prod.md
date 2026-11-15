# Latency plan live in PROD: #283 index, #558 local drive, #559 wait + park (server v3.163.0, worker 6.17.0)
- Timestamp: 2026-11-15T08:45:00Z
- Author: Kadyapam
- Tags: latency, prod, rollout, local-drive, await, park, index, ai-meta-283, ai-meta-558, ai-meta-559, ai-meta-570

## Summary

Owner-authorized prod rollout, one change at a time with a prod before/after at each step (record: ops#385, `ci/manifests/noetl/latency-prod/README.md`).
- **#283:** `idx_command_event_id` applied as `postgres` (GSM `noetl-postgres-superuser-password`, cloud-sql-proxy session path in the pgbouncer pod, `CONCURRENTLY`). Claim lookup 72–106 ms → 0.25 ms. Closed.
- **Images:** server v3.161.2 → v3.163.0 `f850267d…`; user worker 6.12.0 → 6.17.0 `70c2b675…`. System pools and cmdbus-writer stay 6.11.9.
- **Flags ON:** `NOETL_SERVER_ADVANCE_API`, `NOETL_WORKER_LOCAL_DRIVE`, `NOETL_EXECUTION_WAIT`, `NOETL_PLAYBOOK_AWAIT_PARK`. **OFF:** `NOETL_CATALOG_REMOTE_PUSH` (no cross-instance calls in prod).
- **Rollback:** unset flags; or pin v3.161.2 / 6.12.0 (ledger rows in ops).

## Prod before → after (p50 / p95)

| Measure | Before | After |
|---|---|---|
| seq10 noop wall | 10.41 / 11.39 s | 3.39 / 7.47 s |
| overhead per step | 712 / 1483 ms | 217 / 546 ms |
| awaited child hop | 2468 / 4942 ms | 1024 / 1456 ms |
| await3 wall | 13.71 / 15.65 s | 5.23 / 7.45 s |
| load 16 runs C=4 | 23.76 / 39.20 s | 4.51 / 5.82 s |
| auth fallback (max) | 7.26 s | 4.73 s (budget 15 s); sync path ~215 ms throughout |
| real travel turn | 11.52 s (flags off) | 9.57 / 11.57 s |

## Lessons
- The #283 index was the single biggest prod win (noop wall 10.4 → 6.1 s on its own); the "~1 % of a turn" estimate was wrong because every hop pays the claim lookup.
- Prod is ~10× slower per step than kind; measure on prod read paths before predicting.
- Watch: 2 of the first 5 travel turns after the #559 enable stalled ~4 s before a next step (not parked); 25 following turns clean.
