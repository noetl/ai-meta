# #49 Phase F R5 — production cutover readiness: NO-GO

**Date:** 2026-06-12
**Issue:** noetl/ai-meta#49 (stays OPEN; board In progress)
**Assessment comment:** https://github.com/noetl/ai-meta/issues/49#issuecomment-4696382398

## What was asked
Stage-1 readiness + (conditional) Stage-2 flip of production GKE from
Python `noetl-server` (FastAPI) to the Rust `noetl/server` crate.

## Verdict: NO-GO. No production traffic flipped. Prod untouched.

## Why (durable facts about prod)
- Prod cluster: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
  (account `alexis.k@cybx.io`). Read-only access confirmed.
- Routing is NOT a K8s Ingress. `gateway` LoadBalancer (ns `gateway`,
  ext IP `34.46.180.136`) → env `NOETL_BASE_URL=http://noetl.noetl.svc
  .cluster.local:8082` → `noetl` ClusterIP Service (selector
  `app=noetl-server`). A "flip" = repoint that Service selector.
- Prod baseline = **Python only**: `noetl-server` 1/1 image
  `noetl:coalesce-20260529230422` (cmd `["python"]`); `noetl-worker` 3/3.
- **No `noetl-server-rust` Deployment / Service / pods in prod, and no
  `server-rust` image in the prod Artifact Registry.** Rust server has
  never run on GKE — only on the kind stack (healthy runtime v3.4.2).
- Rust pointer that *would* ship: `repos/server` = `7b217d8`
  (`v3.2.0-10-g7b217d8`).

## Hard prerequisite gaps (operator-gated)
1. `noetl-secret` (prod) has only `NOETL_PASSWORD` + `POSTGRES_PASSWORD`
   — **no `NOETL_ENCRYPTION_KEY`**. Rust manifest refs it `optional:true`
   → Rust would use the INSECURE DEFAULT key; credentials wouldn't
   cross-decode with Python. (prereq 3b FAIL)
2. `noetl-internal-api-token` secret **absent** in prod. Rust manifest
   refs it as a NON-optional secretKeyRef → Rust pod would
   CreateContainerConfigError / fail to start. (3c FAIL)
3. NATS auth: manifest `NOETL_NATS_URL=nats://noetl:noetl@nats...:4222`
   matches prod gateway's NATS URL (format correct) but unverifiable
   live — no Rust pod in prod. (3a)
4. Gate `validate-shard-routing-n2.sh` is kind-scoped; fresh re-run
   blocked on kind Postgres `noetl` role lacking `CREATEDB` (harness
   privilege; superuser is `demo`). Did NOT self-grant (out of scope).
   Shard routing N=2 previously PASSED at Phase F R4.

## Eventual-cutover order (recorded on #49 for operator)
build+push amd64 `server-rust` image → provision `NOETL_ENCRYPTION_KEY`
(matching Python's) + `noetl-internal-api-token` secrets → apply
prod `noetl-server-rust` Deployment+Service → verify health (DB + NATS
w/ prod auth) + canary → THEN selector flip + scale Python to 0.

## Flip / rollback (once green)
```
PROD=gke_noetl-demo-19700101_us-central1_noetl-cluster
# cutover:  kubectl --context $PROD -n noetl patch svc noetl -p '{"spec":{"selector":{"app":"noetl-server-rust"}}}'
# rollback: kubectl --context $PROD -n noetl patch svc noetl -p '{"spec":{"selector":{"app":"noetl-server"}}}'
```

## No PR opened
Conservative bias — landing a Rust prod Deployment before the secrets
exist would crashloop or silently use the insecure default key. Those
are operator steps. Left unrelated uncommitted items
(`repos/.dockerignore`, `scripts/start_noetl_ui.command`) untouched.
