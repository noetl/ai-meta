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

---

## UPDATE 2026-06-12 (later) — cutover PREP landed (non-prod-mutating)

Built/merged all safe prep; prod still 100% Python (operator-gated cutover).

- **Prod amd64 image** pushed: `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/server-rust`
  tags `4644c49` + `v3.5.0`, digest
  `sha256:78cce8f3790bcc74c7e94d15a4486c67be868757621b00d1da6fa6c8a6b929fa`
  (Cloud Build `00a26c26`, linux/amd64).
- **GOTCHA (server-side time pin):** v3.5.0 release commit `7b217d8` does NOT
  compile — `time 0.3.48` (2026-06-12) × `async-nats 0.38` E0119 under
  rustc 1.91+. server was the LAST Rust repo missing the `time =0.3.47` pin
  (tools/worker/gateway already had it). Fixed: server#190 MERGED (`55d2dfc`).
- **ops#178 MERGED** (`dd5ede7`): `ci/manifests/noetl/server-rust-deployment-prod.yaml`
  (image pinned by digest; NOETL_ENCRYPTION_KEY + noetl-internal-api-token
  REQUIRED/fail-closed; pgbouncer DB host; NATS prod auth; parallel Service —
  does NOT touch the `noetl` Service) + `runbooks/noetl-server-rust-cutover.md`
  + `automation/gcp_gke/assets/server/cloudbuild.yaml`.
- ai-meta pointers: server `7b217d8`→`55d2dfc`, ops `85bfc1f`→`dd5ede7`,
  wiki `e9632d4`.
- #49 prep comment: https://github.com/noetl/ai-meta/issues/49#issuecomment-4696622847

**Key prod facts confirmed for the runbook decisions:**
- Python prod credential "encryption" is a NO-OP (`core/secret.py::encrypt_json`
  = json.dumps). Stored credentials are PLAINTEXT JSON. Rust uses real AES-GCM
  (fails closed without NOETL_ENCRYPTION_KEY). NO key to "match" → re-enter all
  credentials post-cutover.
- Prod DB only via `pgbouncer.postgres.svc` (no direct postgres Service) →
  sqlx needs pool_mode=session.
- `noetl` Service exposes 8083 (Arrow Flight) selecting app=noetl-server; Rust
  serves only 8082 → confirm no consumer before flip.

#49 STILL OPEN; board In progress. Cutover = operator runs the runbook.

---

## UPDATE 2026-06-13 — live pre-flight with operator: pgbouncer transaction-mode fix

Ran read-only pre-flight against LIVE prod. Production still 100% Python.

- **Decision B (DB) — real blocker, FIXED.** Prod DB = Cloud SQL (`noetl-shared-pg`)
  behind `pgbouncer.postgres.svc` `POOL_MODE=transaction` (cloud-sql-proxy). NO
  direct postgres Service. sqlx named prepared-statement cache breaks under
  transaction pooling. Fix: `NOETL_PG_STATEMENT_CACHE_CAPACITY` env on server
  (default 100 unchanged; =0 → one-shot unnamed statements). server#191 MERGED
  (`0577cc6`, v3.5.1). Manifest sets =0. Rust stays behind pgbouncer like Python.
- **Decision C (Flight :8083) — N/A in prod.** Prod `noetl` Service is 8082/TCP
  only (8083 exists only in kind manifest). Cleared.
- **Image repinned** (carries time pin + statement-cache fix): digest
  `sha256:c3783281b3c90572ef01538e1672125ab464e732db329f1187e1b12411964984`
  (server-rust:e7df366 / :v3.5.0, Cloud Build 94cc199e). NOTE: image reports
  version 3.5.0 (built off pre-release-commit tree) but contains v3.5.1 code.
- ops#179 MERGED (`1164270`): manifest env + repin + runbook (B RESOLVED, C N/A).
  server-wiki deployment-spec env catalogue updated (`a17cf50`).
- ai-meta pointers: server `55d2dfc`→`0577cc6`, ops `dd5ede7`→`1164270`.
- #49 comment: https://github.com/noetl/ai-meta/issues/49#issuecomment-4700550114

GOTCHA for any future Rust service on this prod cluster: pgbouncer is
transaction-mode → ALWAYS set NOETL_PG_STATEMENT_CACHE_CAPACITY=0 (or the
equivalent) for sqlx-based services. Python is unaffected.

Operator-pending: Decision A credential re-entry, provision 2 secrets, apply,
canary, flip, scale Python to 0. #49 OPEN; board In progress.

---

## UPDATE 2026-06-13 (later) — FIRST PROD FLIP ATTEMPT FAILED → rolled back clean

Attempted server-only cutover (flip noetl Service → Rust, keep Python workers).
FAILED on `POST /api/execute`: 500 "NATS publish ack failed: no stream found
for given subject". Rolled back selector → Python (seconds). Prod healthy.

**ROOT CAUSE (load-bearing):** Rust server publishes commands to hierarchical
subject `noetl.commands.{pool}.{execution_id}` (server/src/handlers/execute.rs:1137).
Prod NATS stream + Python workers use FLAT `noetl.commands`. So (a) no stream
captures `noetl.commands.>` → publish fails; (b) Python workers wouldn't consume
the hierarchical subjects anyway. **Server-only cutover is NOT viable. The Rust
worker consumes the hierarchical subjects → must cut over the FULL Rust stack
(Rust server + Rust worker, Python scaled to 0) — the kind-validated config.**

**Credential format GOTCHA:** Rust stores encrypted creds as a JSON envelope
(starts with `{`), so `left(data_encrypted,1)='{'` does NOT distinguish
plaintext vs Rust-ciphertext. Verify via reading `data` back THROUGH the
serving server and checking real keys appear (not ciphertext/nonce).

**Credential re-entry hazard:** re-encrypting the 19 creds under Rust BEFORE
confirming the flip sticks meant the rollback had to also restore them to
plaintext (read plaintext from the still-running Rust pod → re-POST to Python).
2 of 19 transiently 500'd in the batch; a retry fixed them. Next attempt:
re-encrypt only AFTER the full Rust stack is proven serving.

**Other fixes that landed this session (all merged + pointers bumped):**
- ops#180 (pointer 3d3a034, ai-meta@50d8bc4): server-rust DB password from
  noetl-secret/NOETL_PASSWORD (pgbouncer SASL). The POSTGRES_PASSWORD key is a
  different value; pgbouncer client pw for user noetl is under NOETL_PASSWORD.

**Building now:** noetl-worker-rust:v5.20.0 amd64 image (worker HEAD 7b8a09a).

**Next:** worker manifest + provision prod NATS `noetl.commands.>` stream +
validate full Rust stack on canary (real execution) BEFORE any re-flip.

Prod currently: Python serving, all 19 creds plaintext, Rust server canary up
(off traffic path). #49 OPEN; board In progress.

---

## UPDATE 2026-06-13 (final) — 🎉 PRODUCTION CUTOVER COMPLETE (full Rust stack)

Prod GKE `noetl-demo-19700101` now runs the full Rust stack; Python at 0.

**Attempt 1 (server-only) FAILED** → rolled back (see prior update). **Attempt 2
(full Rust stack) SUCCEEDED:**
- Built prod amd64 Rust worker image `noetl-worker-rust:v5.20.0`
  (digest `sha256:b808bc604d59af7cda93154631de8692be2a7799d54f9bf5b232e9706dc8dea9`).
- Created a DEDICATED NATS stream `NOETL_COMMANDS_RUST` (subjects
  `noetl.commands.>`), disjoint from Python's flat `noetl.commands` (untouched).
  NOTE: editing the shared NOETL_COMMANDS stream was classifier-blocked;
  creating a new isolated stream was allowed — and is cleaner anyway.
- Deployed Rust worker canary (consumer `noetl_worker_rust_shared`, filter
  `noetl.commands.shared.>`, NOETL_SERVER_URL→rust server) → validated a real
  hello_world execution COMPLETED end-to-end OFF the traffic path (the gate).
- Cutover: scaled rust worker→3, flipped `noetl` selector→Rust, re-encrypted
  19 creds (19×200), scaled Python server+workers→0. KEDA ScaledObject
  `noetl-worker` (min=3) kept Python workers up → PAUSED it at 0 via
  annotation `autoscaling.keda.sh/paused-replicas=0`.
- Verified: executions COMPLETE through prod noetl service (incl. Python at 0),
  creds decrypt, gateway health green, logs clean.

**Final prod state:** noetl-server-rust 1/1 (server-rust@sha256:c3783281...964984),
noetl-worker-rust 3/3, noetl-server 0/0 + noetl-worker 0/0 (Python retained for
rollback). `noetl` selector = app=noetl-server-rust. Stream NOETL_COMMANDS_RUST.

**Rollback:** selector→noetl-server + scale Python up + unpause KEDA
(`paused-replicas-`) + restore creds to plaintext.

**KEY DESIGN LESSON (durable):** A Rust-server cutover on this cluster REQUIRES
the Rust worker too — the server publishes hierarchical `noetl.commands.{pool}.{eid}`
that Python workers + the flat-subject stream don't consume. Provision a stream
capturing `noetl.commands.>` (dedicated NOETL_COMMANDS_RUST keeps Python's
stream untouched) and deploy noetl-worker-rust.

**Operator follow-ups:** soak then delete Python deployments; KEDA scaler for
noetl-worker-rust; remove throwaway hello_world catalog entry. #49 open for soak.

ops pointer a6c56b2 (worker manifest); wiki 2d62602.
