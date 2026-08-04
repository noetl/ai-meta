# ShastaraTech prod migration — Stage 2 finish (reproducible IaC)

Continuation of [`shastaratech-prod-migration.md`](shastaratech-prod-migration.md).
Records the **executed** finish steps that moved the NoETL prod stack onto
`shastaratech-noetl-prod` (GKE Autopilot `noetl-prod-autopilot`, us-central1)
after Stage 2a export + Stage 2b infra bring-up. No secrets or DB dumps are
committed here — only the commands and the shapes.

**State at completion: every workload Running on the new cluster; Cloudflare
tunnel/DNS cutover HELD (cloudflared scaled to 0). Old prod
`noetl-demo-19700101` untouched except read-only.**

```bash
OLDP=noetl-demo-19700101
NEWP=shastaratech-noetl-prod
OLD=gke_noetl-demo-19700101_us-central1_noetl-cluster            # kadyapam reads
NEW=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot # shastaratech
# gcloud auth: shastaratech@gmail.com owns NEWP; kadyapam@gmail.com reads OLDP.
# The gke-gcloud-auth-plugin caches a token — `rm -f ~/.kube/gke_gcloud_auth_plugin_cache`
# after every `gcloud config set account` or kubectl keeps using the prior identity.
```

## 0. Restore verdict (assessed, not redone)

The Stage 2b DB restore of the `noetl` DB was **complete and faithful** —
verified against expected: event 923900 (≥923887), command 174412 (≥174408),
execution 4647, catalog 1389, credential 19, runtime 126, **MAX(event_id)
647063734879257274 exact** (snowflake high-water preserved). Small +deltas are
the pg_dump snapshot taken microseconds after the row-count probe. Ownership
(6 objects `noetl`-owned: outbox/object_store/plugin_module/result_store/
secret_audit/subscription_dedup; 47 `postgres`-owned) matches the dump TOC
exactly. **No re-restore needed.**

The dump was taken `--no-acl`, so the `noetl` app role's grants on the
`postgres`-owned tables were missing. Reconstructed (frozen image = no new
migrations, so DML grants suffice):

```sql
-- as postgres (cloudsqlsuperuser) on the noetl DB
GRANT USAGE, CREATE ON SCHEMA noetl TO noetl;
GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON ALL TABLES IN SCHEMA noetl TO noetl;
GRANT USAGE,SELECT,UPDATE ON ALL SEQUENCES IN SCHEMA noetl TO noetl;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA noetl TO noetl;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA noetl GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON TABLES TO noetl;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA noetl GRANT USAGE,SELECT,UPDATE ON SEQUENCES TO noetl;
GRANT USAGE, CREATE ON SCHEMA public TO noetl;
```

## 1. Cross-project Artifact Registry image copy

Only 3 private images move (workers are public `ghcr.io/noetl/worker:5.51.0`/`5.52.0`).
No `gcloud artifacts docker images copy` exists and no crane/skopeo locally, so
pull-as-kadyapam / push-as-shastaratech via podman (same registry host). podman
re-serialized to v2s2 → **manifest digests changed but image content is
bit-identical** (config sha256 preserved, e.g. server `23d5293230d8…`). Deploy
by the NEW digests.

| image | old (source) | new digest (deploy this) |
| :-- | :-- | :-- |
| server-rust | `@sha256:702ed479…` | `us-central1-docker.pkg.dev/$NEWP/noetl/server-rust@sha256:2a51632d17138d1f439f1df430cb6bd7cca060cc645d2d4775761786c3cefa86` |
| noetl-gateway | `:authz-sync-168 @sha256:bebaf16f…` | `…/noetl/noetl-gateway@sha256:eef3a7c4370741f76ea1ab670d187b878e8e10a4897e5764a80621b26b3e7bf3` |
| noetl-doctor | `:pft-reaper-…-190740 @sha256:0260c806…` | `…/noetl/noetl-doctor@sha256:1a54d34fc2265186547867fa4745016c8a2d0f95e1e57675f23da2e9f5530e77` |

```bash
gcloud auth print-access-token --account=kadyapam@gmail.com | podman login us-central1-docker.pkg.dev -u oauth2accesstoken --password-stdin
podman pull  us-central1-docker.pkg.dev/$OLDP/noetl/server-rust@sha256:702ed479…
podman tag   …/$OLDP/noetl/server-rust@sha256:702ed479… us-central1-docker.pkg.dev/$NEWP/noetl/server-rust:v3.52.0
gcloud auth print-access-token --account=shastaratech@gmail.com | podman login us-central1-docker.pkg.dev -u oauth2accesstoken --password-stdin
podman push --format v2s2 us-central1-docker.pkg.dev/$NEWP/noetl/server-rust:v3.52.0   # repeat for gateway/doctor
```

**Node-SA pull grant (required — pods 403 without it):**
```bash
gcloud artifacts repositories add-iam-policy-binding noetl --project $NEWP --location us-central1 \
  --member="serviceAccount:986938120811-compute@developer.gserviceaccount.com" --role="roles/artifactregistry.reader"
```

## 2. IAM / Workload Identity

GSAs (worker-mcp pre-existing from Stage 2b; result-tier + cloudsql-proxy created here):

```bash
gcloud iam service-accounts create noetl-result-tier    --project $NEWP
gcloud iam service-accounts create noetl-cloudsql-proxy --project $NEWP
# WI bindings (KSA -> GSA)
gcloud iam service-accounts add-iam-policy-binding noetl-worker-mcp@$NEWP.iam.gserviceaccount.com    --role roles/iam.workloadIdentityUser --member "serviceAccount:$NEWP.svc.id.goog[noetl/noetl-worker]"
gcloud iam service-accounts add-iam-policy-binding noetl-result-tier@$NEWP.iam.gserviceaccount.com   --role roles/iam.workloadIdentityUser --member "serviceAccount:$NEWP.svc.id.goog[noetl/noetl-server-rust]"
gcloud iam service-accounts add-iam-policy-binding noetl-cloudsql-proxy@$NEWP.iam.gserviceaccount.com --role roles/iam.workloadIdentityUser --member "serviceAccount:$NEWP.svc.id.goog[postgres/cloudsql-proxy]"
# cloudsql client + results bucket
gcloud projects add-iam-policy-binding $NEWP --member "serviceAccount:noetl-cloudsql-proxy@$NEWP.iam.gserviceaccount.com" --role roles/cloudsql.client --condition=None
gcloud storage buckets create gs://$NEWP-results --project $NEWP --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets add-iam-policy-binding gs://$NEWP-results --member="serviceAccount:noetl-result-tier@$NEWP.iam.gserviceaccount.com" --role="roles/storage.objectAdmin"
```

### ⚠ OPERATOR-REQUIRED (gate-blocked in the automated run)

The 5 `noetl-worker-mcp` **project data/AI roles** could not be applied
automatically (host policy blocks broad project-level grants to a service
account). Run before relying on Vertex/genai providers. GSM secret reads use
per-secret `secretAccessor` (already granted, same project) and do **not** need
these; Vertex AI needs `aiplatform.user`.

```bash
WMCP=noetl-worker-mcp@$NEWP.iam.gserviceaccount.com
for r in aiplatform.user datastore.user serviceusage.serviceUsageConsumer container.viewer mcp.toolUser; do
  gcloud projects add-iam-policy-binding $NEWP --member "serviceAccount:$WMCP" --role "roles/$r" --condition=None
done
```

## 3. GSM provider secret values (never printed)

Migrated 10 provider secrets old→new via a value-blind pipe + per-secret
`secretAccessor` for worker-mcp. (7 are the worker-mcp-bound set; openai +
amadeus key/secret added because ops MCP playbooks reference them — a safe
superset of the brief's "8".)

```bash
for s in duffel-api-test hotelbeds-hotels-test hotelbeds-transfers-test hotelbeds-activities-test \
         google-maps-widget-key anthropic-api-key figma-access-token openai-api-key \
         api-key-test-api-amadeus-com api-secret-test-api-amadeus-com; do
  gcloud secrets create $s --project $NEWP --replication-policy=automatic
  gcloud secrets versions access latest --secret=$s --project=$OLDP --account=kadyapam@gmail.com \
    | gcloud secrets versions add $s --project=$NEWP --data-file=-      # value never hits stdout/logs
  gcloud secrets add-iam-policy-binding $s --project $NEWP \
    --member "serviceAccount:noetl-worker-mcp@$NEWP.iam.gserviceaccount.com" --role roles/secretmanager.secretAccessor
done
```
Verification: compare `... | wc -c` old vs new per secret (byte-length only).

## 4. DB gaps — demo_noetl (incl. auth schema) + role passwords

Role passwords are the plaintext creds in the pgbouncer `DATABASE_URLS`:
`noetl/noetl`, `demo/demo`, `auth/auth`, `postgres/demo`.
Cloud SQL `postgres` is `cloudsqlsuperuser` (not a true superuser) so it cannot
read the `auth`-owned schema — dump each schema **as its owning role**
(auth schema owned by `auth`; public/noetl_test/team4 owned by `demo`) from an
ephemeral read-only pod in OLD (private IP `172.30.0.3`), restore into NEW
(private IP `10.49.0.3`).

```sql
-- NEW noetl DB, as postgres: enable login + set the missing passwords
ALTER ROLE auth LOGIN; ALTER ROLE demo LOGIN; ALTER ROLE noetl LOGIN;
ALTER ROLE auth PASSWORD 'auth'; ALTER ROLE demo PASSWORD 'demo';
-- on demo_noetl: let the owners recreate their schemas
GRANT CREATE,CONNECT,TEMPORARY ON DATABASE demo_noetl TO demo, auth;
GRANT CREATE,USAGE ON SCHEMA public TO demo;
```
```bash
# OLD (kadyapam): ephemeral pod -> per-owner dumps
kubectl --context $OLD -n postgres run migrate-dump --image=postgres:15-alpine --restart=Never --command -- sleep 1200
kubectl --context $OLD -n postgres exec migrate-dump -- sh -c 'PGPASSWORD=auth pg_dump -Fc -n auth  -h 172.30.0.3 -U auth -d demo_noetl -f /tmp/auth.dump'
kubectl --context $OLD -n postgres exec migrate-dump -- sh -c 'PGPASSWORD=demo pg_dump -Fc -N auth  -h 172.30.0.3 -U demo -d demo_noetl -f /tmp/rest.dump'
# stream out (binary), into NEW pod, restore as owning role
kubectl --context $NEW -n noetl exec pgverify -- env PGPASSWORD=demo pg_restore -h 10.49.0.3 -U demo -d demo_noetl --no-owner --no-acl /tmp/rest.dump
kubectl --context $NEW -n noetl exec pgverify -- env PGPASSWORD=auth pg_restore -h 10.49.0.3 -U auth -d demo_noetl --no-owner --no-acl /tmp/auth.dump
kubectl --context $OLD -n postgres delete pod migrate-dump   # leave no footprint on old prod
```
Result: demo_noetl schemas auth(8)/noetl_test(3)/public(49)/team4(4); auth data
users=1 roles=4 sessions=3 permissions=7. (Restored `--no-acl`; per-schema
ownership by auth/demo covers the runtime connection paths.)

## 5. Workloads

Namespace live-dumps from Stage 2a (`workloads/live-*.yaml`, all `kind: List`)
sanitized (strip status/uid/resourceVersion/managedFields/clusterIP-except-headless/
nodePort; drop Jobs, `kube-root-ca.crt`, `default` SAs, standalone PVCs,
KEDA-managed HPA, the Python-pool `noetl-worker` ScaledObject + `noetl-worker-metrics`)
and reparameterized:

- 3 image refs → new-registry digests (table §1)
- blanket `noetl-demo-19700101` → `shastaratech-noetl-prod` (fixes cloud-sql-proxy
  `connectionName`, the 3 KSA `iam.gke.io/gcp-service-account` annotations,
  `NOETL_OBJECT_STORE_GCS_BUCKET` → `shastaratech-noetl-prod-results`)

**Drift env preserved** (verified in the applied manifests): server
`NOETL_SHARD_SUBJECT_ROUTE=true`, `NOETL_COMMAND_SHARD_COUNT=2`,
`NOETL_EVENT_INGEST_PUBLISH_ONLY=true`, `NOETL_STATE_BUILDER=offserver`,
`NOETL_RESULT_MINT_AUTHORITATIVE=true`; system pools shard 0/1 with distinct app
labels + `noetl_worker_system_rust_shard{0,1}` consumers.

Apply order: KEDA 2.15.0 (upstream — CRDs + cluster RBAC the namespace dump
lacks) → nats → postgres → noetl (SA/RBAC/CM/Deploy/Svc/CronJob) → gateway →
noetl-doctor → nats-supercluster → cloudflared **replicas=0** (HOLD; its HPA
dropped) → ScaledObject `noetl-worker-rust`.

Streams: the server auto-creates `NOETL_COMMANDS_RUST` (+ the 3 live consumers,
none of the abandoned ones) on boot; `noetl_events` created explicitly with 24h
retention:
```bash
kubectl --context $NEW -n nats exec deploy/nats-box -- nats -s nats://noetl:noetl@nats:4222 \
  stream add noetl_events --subjects 'noetl.events.>' --retention limits --max-age 24h --storage file --replicas 1 --discard old --defaults
```

### Known non-core follow-ups
- Worker configmap `NOETL_GCS_BUCKET: noetl-demo-output` still points at an
  old-project bucket (name has no project id → not reparameterized). Only
  matters for playbooks that write there; worker-mcp has no access to the old
  bucket. Repoint or create+grant if any such playbook is exercised.
- `gateway` Service kept as `LoadBalancer` (faithful) → provisioned a fresh
  unused external IP (`34.132.30.16`); traffic path is the tunnel. Switch to
  ClusterIP if the LB IP is unwanted.

## 6. Smoke results

- `GET /health` (server) → `{"status":"ok"}`
- **19/19 credentials decrypt** via `GET /api/credentials/{id}?include_data=true`
  → all 200 (proves `NOETL_ENCRYPTION_KEY` migrated intact; AES-GCM would error
  on a wrong key).
- gateway `/health` in-cluster → `ok`.
- `fixtures/playbooks/hello_world` via `POST /api/execute` → **COMPLETED** in
  ~4s (server → NATS command → worker claim → execute → event projection →
  state builder).

## 7. STAGED CUTOVER STEP — HELD (operator go required)

cloudflared is deployed at **replicas=0**, wired to the same tunnel token
(`noetl-gke-gateway-tunnel` secret) pointing at the new in-cluster gateway.
Scaling it up joins tunnel `noetl-gke-gateway` and starts routing
`gateway.mestumre.dev` to the new cluster — **this is the cutover**:

```bash
# FINAL GATED STEP — only on explicit go:
kubectl --context $NEW -n cloudflare scale deploy/noetl-gke-gateway-tunnel --replicas=1
# (optionally re-apply its HPA min=1/max=2). Then scale OLD prod's cloudflared to 0.
```
No DNS record or tunnel ingress config was changed. Rollback = scale new
cloudflared back to 0.

## 8. CUTOVER EXECUTED — 2026-07-26 (headless, operator GO given)

Contexts:
`NEW=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot` (shastaratech@gmail.com)
`OLD=gke_noetl-demo-19700101_us-central1_noetl-cluster` (kadyapam@gmail.com)

### Pre-check (new cluster healthy)
```bash
kubectl --context $NEW -n noetl port-forward svc/noetl-server-rust 18082:8082 &
curl -s http://localhost:18082/health            # {"status":"ok"} 200
kubectl --context $NEW -n gateway port-forward svc/gateway 18080:80 &
curl -s http://localhost:18080/health            # ok 200  (health path = /health)
```
Server 1/1, worker-rust 2/2, system-pool + shard1 1/1, gateway 1/1 — all Running.
External baseline (old serving): `https://gateway.mestumre.dev/health` -> 200 `ok`.

### Bring up NEW connector
```bash
kubectl --context $NEW -n cloudflare scale deploy/noetl-gke-gateway-tunnel --replicas=1
kubectl --context $NEW -n cloudflare rollout status deploy/noetl-gke-gateway-tunnel
```
Connector registered 4 tunnel connections (ord02/06/11/12); ingress config
`gateway.mestumre.dev -> http://gateway.gateway.svc.cluster.local:80`; request_errors=0.

### Region-affinity finding (why overlap-verify from workspace is inconclusive)
cloudflared metrics (`:20241/metrics`, `cloudflared_tunnel_total_requests`):
during overlap a 40-req + 20-req external burst incremented the **OLD**
connector by exactly 40 and 20; the **NEW** connector stayed 0. Workspace
egress hits the SJC edge, which pins to old's west-coast colo connections.
=> new path can only be externally verified once old is down (only-new state).
All independent new-path checks were green, so proceeded.

### Take OLD connector down + verify flip (only-new)
```bash
gcloud config set account kadyapam@gmail.com
kubectl --context $OLD -n cloudflare scale deploy/noetl-gke-gateway-tunnel --replicas=0
# immediate loop: 25x curl https://gateway.mestumre.dev/health
```
Result: **25/25 -> 200, zero blip** (graceful deregister, seamless failover).
NEW connector `total_requests` delta = 50 (25 probes x2 curls), request_errors=0.
OLD cloudflared now 0/0. OLD noetl workloads (server 1/1, worker-rust 2/2,
system-pool, shard1) left **Running** = warm rollback, DB intact.

### Post-cutover verify (only new connector up)
- 8/8 external `/health` -> 200, latency ~0.10s (improved from old ~0.21s).
- End-to-end gateway->server `GET /api/runtime/contract` -> 200 with real
  agent_contract/auth0 payload — gateway proxy to server confirmed on new cluster.

### ROLLBACK RECIPE (not run; old prod untouched + DB intact)
```bash
# return traffic to OLD prod:
gcloud config set account kadyapam@gmail.com
kubectl --context $OLD -n cloudflare scale deploy/noetl-gke-gateway-tunnel --replicas=1
# and drop the new connector so it stops competing:
gcloud config set account shastaratech@gmail.com
kubectl --context $NEW -n cloudflare scale deploy/noetl-gke-gateway-tunnel --replicas=0
# workspace (SJC) traffic returns to old within ~1-2s (region affinity).
```
No DNS record or tunnel-ingress config was changed — connector scale is the
entire flip. OLD prod remains fully warm; do NOT decommission this step.
