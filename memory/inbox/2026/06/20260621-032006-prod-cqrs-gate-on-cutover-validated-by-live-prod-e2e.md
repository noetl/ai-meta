# Prod CQRS gate-ON cutover validated by live-prod e2e
- Timestamp: 2026-06-21T03:20:06Z
- Author: Kadyapam
- Tags: prod,cqrs,cutover,e2e,validation,103,107,111,gate-on,offserver,sole-writer,never-scan

## Summary
2026-06-20: ops#200 merged (ops@d6633f6, ai-meta 08c73e5) recording the executed prod CQRS rollout (server v3.39.1 @sha256:197a6d10 + worker v5.40.2 @sha256:41713265, worker replicas->2, configmap stream keys -> lowercase noetl_events). Then ran the Rust regression + specialized playbooks against LIVE PROD (gke noetl-cluster ns noetl, PUBLISH_ONLY=true + STATE_BUILDER=offserver, materializer sole writer): 28/30 executions PASS (24/26 distinct fixtures + 4 composition-spawned children) covering python/args/vars/loops/control-flow/output-select/large-result/actions/fan-out-reduce/duckdb/http(in-cluster)/save-to-postgres(json_serialization_save pg_k8s)/sub-playbook-composition. Every gate-ON execution: COMPLETED, sole-writer (rows==distinct, 0 catalog0, 0 __orchestrate__ event rows, >=1 __orchestrate__ command), clean chain (roots=1/terminals=1/dangling=0/walk==total), never-scan (worker state_builder_event_scans delta 0 / cumulative 0), materializer lag 0. The 2 FAILs (postgres_test pg_noetl_k8s stale, postgres_jsonb pg_local) are pg-credential-unreachable PROD-ENV diffs NOT cutover bugs (clean playbook.failed terminal + single-root chain held = failure path gate-ON-correct; consistent with no-default-connection.md). No platform bug found, no issue filed. pg_k8s reaches the prod DB; pg_local/pg_noetl_k8s do not. SKIP+noted: pagination/* (needs paginated-api.test-server.svc), http_to_postgres_* (ext egress), save_simple/save_all/storage_tiers (pg_local/#101), auth0/google_id_token/amadeus/openai/IB/snowflake (ext creds), heavy/OOM/burst. Prod left healthy on the new path (health ok, lag 0, 0 pod restarts ~45min, gate still ON). PROD TEST-DATA FOOTPRINT (uncleanable): tenant prefix prod-e2e-20260620-1946 = 26 catalog entries / 30 executions / 947 noetl.event rows. New reusable rig: e2e scripts/prod_regression_validate.py (tenant-prefix isolation + per-exec gate-ON DB proof + materialization-aware verify) in noetl/e2e#74 (OPEN, pointer bump deferred to merge). Wiki Sessions-Log/Home/Releases + #103/#107/#111 comments + board (all In progress) updated; wiki d694bfc, pointer bump 61dacd6.

## Actions
-

## Repos
-

## Related
-
