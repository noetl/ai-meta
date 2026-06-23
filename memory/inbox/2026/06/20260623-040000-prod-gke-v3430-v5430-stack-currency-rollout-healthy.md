# Prod GKE rolled to server v3.43.0 + worker v5.43.0 (stack-currency, result-tier inert)

- Timestamp: 2026-06-23T04:00:00Z
- Author: Kadyapam
- Tags: prod,gke,rollout,v3.43.0,v5.43.0,104,result-tier,off-server-cutover,flags-off,stack-currency

## Summary
Brought prod GKE (noetl-demo-19700101 / us-central1 / noetl-cluster / ns
noetl) to the current functional stack: **server v3.39.5 -> v3.43.0** and
**worker-rust + system-pool v5.40.5 -> v5.43.0**, rolled by digest, keeping the
live off-server CQRS cutover healthy. This was a **stack-currency** rollout —
the new images carry the merged #104 Phase A-D result-tier code (URI accept,
Feather materializer, resolve-by-URN, mint-authoritative + dual-write) but ALL
behind **default-off** flags, so the new code is **inert/safe**. No result-tier
flag was enabled.

## Baseline (pre-roll, read live from pods)
- server v3.39.5 `@feaac0c5…48179`; worker+system-pool v5.40.5 `@45212dbe…f0af2`
- gate: server PUBLISH_ONLY=true, STATE_BUILDER=offserver, EVENT_READ_PATH=event_scan;
  system-pool MATERIALIZER_ENABLED=true, STATE_BUILDER=offserver
- CPU req 250m / limit 2 (the #127 bump) on all three
- cutover healthy: materializer drained==projected==acked=60, lag 0, command lag 0,
  19 COMPLETED / 1 CANCELLED recent, 0 restarts

## No migration
diff v3.39.5..v3.43.0 (server) + v5.40.5..v5.43.0 (worker) = additive Rust only,
ZERO DDL/CREATE/ALTER/migration. Result-tier flags `#[serde(default)]`->false
(unit test `test_result_mint_authoritative_defaults_off`). Confirmed no schema work.

## Build
Cloud Build regional us-central1, E2_HIGHCPU_8 (ops cloudbuild.yaml configs,
timeout 7200s baked in). server v3.43.0 (6f6b9ef) -> `sha256:f2735e81…028455`;
worker v5.43.0 (be6863a) -> `sha256:0c89be5a…d5f26e`. Single build slot — worker
queued behind server. Both SUCCESS, tagged v3.43.0/6f6b9ef + v5.43.0/be6863a in AR.

## Roll (workers->server, plug-in-drive guardrail) + validation
`kubectl set image` by digest (preserves env: gate flags + CPU 250m/2 + result-tier
unset). Workers first, server second. All 4 pods 1/1 Running, **0 restarts**.
- system-pool v5.43.0: WAL index rehydrated (#119) `indexed_executions=2`, materializer
  started, lag 0 both consumers; new inert metric `noetl_worker_result_materializer_drained_total=0`.
- server v3.43.0: health=3.43.0, gate flags preserved, no RESULT/MINT/URI_ACCEPT env.
- SMOKE: tenant-segregated `prod_v343_smoke_20260623/hello` (off-server drive) ->
  COMPLETED, 19 events, last_event_type=playbook.completed (single terminal),
  materializer 19==19==19 sole-writer; `system/scheduled_cleanup` (server-built) -> COMPLETED.
- Invariants: sole-writer parity, lag 0, command lag 0, never-scan delta 0 on off-server
  path (2 server scans = system-path cleanup, by design), 0 restarts.
- Result-tier INERT: result_materializer drained/errors/skipped=0; no dual_write/uri_accept/
  mint counters emitted -> behavior == prior stack.

## State / revert
No rollback triggered. Prod is now CURRENT on v3.43.0/v5.43.0 with off-server cutover
LEFT ON and result-tier OFF. Image rollback targets if needed: server `@feaac0c5` (v3.39.5),
worker `@45212dbe` (v5.40.5). Cutover gate revert armed but unused:
`set env deploy/noetl-server-rust NOETL_EVENT_INGEST_PUBLISH_ONLY=false NOETL_STATE_BUILDER=server`
(+ system-pool). Smoke data namespaced under `prod_v343_smoke_20260623/` (365d retention, no DELETE).
#104 stays OPEN (Phase E/F remain; result-tier not yet enabled on prod).

## Related
- #104 result-tier umbrella; #127 CPU bump; #119 WAL rehydrate; off-server cutover prod-cqrs-cutover.
