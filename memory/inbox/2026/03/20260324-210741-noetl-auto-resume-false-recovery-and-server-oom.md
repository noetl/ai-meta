# NoETL auto-resume false recovery and server OOM
- Timestamp: 2026-03-24T21:07:41Z
- Author: Kadyapam
- Tags: noetl,runtime,auto-resume,server,oom,db-pool,nats,worker

## Summary
Prod BHS validation showed three linked runtime problems on noetl `v2.10.37`: fresh executions could stay at `command.issued` for `start` during transient server outages, auto-resume then incorrectly treated those fresh pending executions as interrupted and cancelled/restarted them, and long-running worker callbacks could hit the NATS subscriber timeout and `NAK` live commands back onto the queue for redelivery. At the same time both prod server pods were being `OOMKilled`, and previous logs showed internal NoETL DB pool saturation during claim, batch acceptance, and credential lookup paths.

## Actions
- Root-caused the false restart loop to `server/auto_resume.py`, where recovery candidates were any recent non-terminal parent execution with no guard for fresh pending `command.issued` state.
- Patched auto-resume to skip pending-only `command.issued` candidates and require a configurable stale-age floor before recovering in-flight executions.
- Reduced server DB pool pressure in `server/api/credential/service.py` by reusing the current DB connection for keychain cache writes instead of opening a second pool checkout during `include_data=true` credential reads.
- Added unit coverage for the new auto-resume candidate filtering.
- Patched `core/messaging/nats_client.py` so worker subscribers keep JetStream messages alive with periodic `in_progress` heartbeats while a command callback is still running instead of timing out the callback wrapper and `NAK`ing active work for redelivery.
- Added unit coverage for the new NATS in-progress heartbeat helper.
- Pushed NoETL branch `kadyapam/fix-auto-resume-recovery-criteria` at commit `89de91aa`.
- Pushed gitops branch `kadyapam/bhs-prod-noetl-v2-10-37` commit `618c38b` to raise prod `server-noetl` memory from `2Gi` to `4Gi` after both server pods showed repeated `OOMKilled`.

## Evidence
- Worker logs for executions `589870863738995591` and `589872170172416981` showed `Error claiming command ... All connection attempts failed` on `start`, followed by later successful claim once the server recovered.
- Worker logs on execution `588817070813348433` showed `Command callback timed out after 180.0s; issuing NAK for redelivery`, which matches the duplicate-notification churn seen on long-running commands.
- Server logs showed `[AUTO-RESUME] Marked execution 589870863738995591 as CANCELLED` and launched replacement execution `589872170172416981` even though the original run had only reached `command.issued` for `start`.
- `kubectl describe pod` on both server pods showed `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`.
- Previous server logs showed `psycopg_pool.PoolTimeout: couldn't get a connection after 3.00 sec` in runtime sweeper, `DB pool saturated` on claim paths, and `/api/postgres/execute` failing because credential lookup could not get a pool connection.

## Repos
- `repos/noetl`
- `repos/gcp-gitops-cybx`
- `repos/ai-meta`

## Related
- `AHM-4342`
- `sync/issues/2026-03-24-execution-589832032755123070-monitoring-report.md`
