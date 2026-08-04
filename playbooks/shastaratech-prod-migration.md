# NoETL prod → ShastaraTech GKE migration plan

**Status: DESIGN ONLY. Nothing in this document has been executed.**
No project was created, no billing changed, no cluster provisioned, no
manifest applied. Every mutating command below is written for the
**operator** to run. The agent's role is read-only gates and diff review,
same execution model as
[`playbooks/166-phase5-prod-rollout.md`](166-phase5-prod-rollout.md) and
[`playbooks/194-l1-t4-prod-cutover.md`](194-l1-t4-prod-cutover.md).

Goal: stand up a new GKE cluster in the **shastaratech** org, move the
entire NoETL production stack onto it, and retire the current prod space.

| | current prod | target prod |
| :-- | :-- | :-- |
| GCP project | `noetl-demo-19700101` | **`shastaratech-noetl-prod`** |
| Org / folder | outside the shastaratech org (not visible to the shastaratech credential) | folder `687234939033` (same folder as `shastaratech-noetl-dev`, `shastaratech-ai-lab`) |
| Cluster | `noetl-cluster`, us-central1, **Autopilot**, REGULAR channel, 1.34.3-gke.1051003 | `noetl-cluster` (name reuse OK — different project) |
| kube context | `gke_noetl-demo-19700101_us-central1_noetl-cluster` | `gke_shastaratech-noetl-prod_us-central1_noetl-cluster` |
| WI pool | `noetl-demo-19700101.svc.id.goog` | `shastaratech-noetl-prod.svc.id.goog` |

---

## 0. Executive summary — the five things that matter

1. **HARD BLOCKER: `shastaratech-noetl-prod` has no billing account
   linked.** GKE cannot be created on an unlinked project. Billing account
   `0153F3-73E360-BD0B38` is at its **5/5 project cap**. Nothing else in
   this plan can start until that is resolved (§4.1).
2. **The old prod project is on a *different* billing account.** Verified
   read-only: the 5 projects linked to `0153F3-73E360-BD0B38` are
   `shastaratech-noetl-dev`, `-billing-admin`, `-obs-prod`,
   `-youtube-prod`, `-dns-prod`. `noetl-demo-19700101` is **not** among
   them. **Retiring old prod does not free a slot.** A slot must come from
   a quota increase or from unlinking one of those five.
3. **Do NOT run this concurrently with the L1 T4 NATS→EHDB command-bus
   cutover** ([ai-meta#194](https://github.com/noetl/ai-meta/issues/194)).
   Migrate on the current transport (NATS), soak, then run T4 on the new
   cluster (§2).
4. **`NOETL_ENCRYPTION_KEY` is the single most dangerous item in the
   move.** The credential store in Postgres is AES-GCM encrypted with it.
   If the key does not travel with the database, every stored credential
   in prod becomes permanently undecryptable. Treat it as a
   move-blocking pre-flight, not a step (§5.3).
5. **Current prod is Autopilot, not Standard.** The premise that a
   dedicated Standard node pool is needed does not hold *today* — the
   "system pool" is a logical pool (NATS consumer + env), not a node pool,
   and the #166 shard-0/shard-1 split is two single-replica Deployments
   with distinct app labels. Autopilot-for-Autopilot is the lowest-variable
   migration. Standard becomes a live question only when EHDB's durable
   writer lands (§3.2).

---

## 1. What could not be read (operator must supply)

The agent has **no credential for `noetl-demo-19700101`** — it is not in
the shastaratech org and does not appear in `gcloud projects list` for the
active account. Every fact about live prod below is reconstructed from
`repos/ops` manifests, `agents/`, `memory/`, and prior session records.
The following need a live read before the plan is executed. Mark each
CONFIRMED / CORRECTED in this file as you go.

| # | Live read needed | Command (operator) |
| :-- | :-- | :-- |
| L1 | Actual running images + digests + replica counts | `kubectl --context $OLD -n noetl get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'` |
| L2 | Full env drift vs the checked-in prod manifests (prod was cut over with `kubectl set env` more than once) | `kubectl --context $OLD -n noetl get deploy -o yaml > /tmp/prod-deploy-snapshot.yaml` |
| L3 | Every namespace actually present | `kubectl --context $OLD get ns` |
| L4 | All PVCs / StatefulSets (expect: NATS JetStream only) | `kubectl --context $OLD get pvc,statefulset -A` |
| L5 | JetStream streams, consumers, and **current pending/lag** | `kubectl --context $OLD -n nats exec deploy/nats-box -- nats stream ls` / `nats consumer info ...` |
| L6 | Cloud SQL instance shape + flags + storage used | `gcloud sql instances describe noetl-shared-pg --project noetl-demo-19700101` |
| L7 | Every GSM secret name in old prod | `gcloud secrets list --project noetl-demo-19700101` |
| L8 | Every GSA + WI binding | `gcloud iam service-accounts list --project noetl-demo-19700101`; per-GSA `get-iam-policy` filtered on `roles/iam.workloadIdentityUser` |
| L9 | Artifact Registry repos + image inventory | `gcloud artifacts repositories list --project noetl-demo-19700101` |
| L10 | GCS buckets + object counts/size | `gcloud storage ls --project noetl-demo-19700101` |
| L11 | Static IPs / LBs still reserved | `gcloud compute addresses list --project noetl-demo-19700101` |
| L12 | Cloudflare zone: DNS records, tunnels, Pages projects, LB pools | Cloudflare dashboard for zone `mestumre.dev` |
| L13 | GMP `PodMonitoring` / `Rules` / alertmanager config | `kubectl --context $OLD get podmonitoring,rules -A`; `kubectl -n gmp-public get operatorconfig config -o yaml` |
| L14 | Org policies on the shastaratech org/folder that could block GKE, external IPs, or SA keys | `gcloud resource-manager org-policies list --organization 561323743912` |

```bash
OLD=gke_noetl-demo-19700101_us-central1_noetl-cluster
NEW=gke_shastaratech-noetl-prod_us-central1_noetl-cluster
```

---

## 2. Sequencing decision: migrate first, T4 second

**Recommendation: cluster migration and L1 T4 are strictly serialized.
Migrate on NATS. Soak. Then run T4 on the new cluster.**

Justification:

1. **One variable per change.** T4 replaces the command transport; the
   migration replaces the substrate under everything. Run together, a
   failure has two candidate causes and two different rollback targets
   (old cluster vs. NATS transport), and the rollbacks are not
   independent — reverting the transport on a half-migrated cluster
   leaves commands split across two brokers in two projects.
2. **T4 requires new prod-only infrastructure that does not exist yet**
   — writer-host env, a **PVC** for `NOETL_COMMAND_BUS_WRITER_DIR`, a
   `noetl-cmdbus-writer` ClusterIP Service, and scrape config for the
   KEDA `ehdb_feed_total_lag` trigger (T4 pre-flight finding F3). Building
   that for a cluster that is about to be discarded is wasted work, and
   the T4 **writer-singleton hazard** (finding F4) has to be re-solved on
   the new cluster's autoscaling shape anyway.
3. **Migration is easier while EHDB is off.** Every `NOETL_EHDB_*` flag is
   default-off in prod today, so there is **no EHDB durable state to
   migrate**. Doing T4 first would create a brand-new stateful,
   single-writer, PVC-backed component and then immediately ask us to
   migrate it across projects. That is the single hardest thing to move
   in the whole stack, and right now it does not exist. Keep it that way
   until after the move.
4. **The migration wants a drained transport.** Cutover requires the
   JetStream `noetl_events` WAL drained to zero pending (§5.5) so the old
   broker can be abandoned without losing unmaterialized events. Mid-T4,
   events would be in flight across *two* transports at once.
5. **T4 Step 0 is already a large image jump** (server v3.52.0 →
   v3.58.0, worker v5.52.0 → v5.78.0, per T4 finding F2). Bake that on a
   stable substrate.

**Corollary — freeze the prod image version across the migration.**
The new cluster runs the **same image digests** as old prod so the move is
a pure substrate change. Do the T4 Step 0 image bake *after* the flip and
soak, on the new cluster. Order:

```
migrate substrate (same images)  →  soak 7d  →  T4 Step 0 image bake
  →  soak  →  T4 shadow  →  T4 flip  →  (T5 later)
```

Record the decision on [ai-meta#194](https://github.com/noetl/ai-meta/issues/194)
so T4 is not picked up in parallel by another session.

---

## 3. Current-prod inventory

Legend — **SR** = stateless redeploy (manifest + image, no data);
**SM** = stateful migrate (carries data that must move or be reproduced);
**EX** = external to GKE (edge, SaaS, or another project).

### 3.1 Cluster and platform

| Item | Detail (source) | Class | Notes |
| :-- | :-- | :-- | :-- |
| GKE cluster | `noetl-cluster`, **Autopilot**, regional `us-central1` (zones a/b/c/f), REGULAR channel, 1.34.3-gke.1051003, network/subnet `default`/`default`, cluster CIDR `10.55.0.0/17`, private endpoint `10.128.15.193` + public endpoint (`blueprints/noetl-cluster-blueprint.json`) | SR | Recreate, do not migrate |
| Addons enabled | dnsCache, GCE PD CSI, Filestore CSI, GCS Fuse CSI, Parallelstore CSI, **statefulHa**; k8s dashboard disabled, network policy disabled | SR | Match on new cluster |
| Workload Identity | pool `noetl-demo-19700101.svc.id.goog` | SM* | Bindings must be recreated in the new project (§5.4) |
| KEDA | operator installed in-cluster; ScaledObjects in `ci/manifests/keda/` | SR | Reinstall + reapply |
| GMP (Google Managed Prometheus) | `gke-gmp-system` / `gmp-public`; `PodMonitoring` `noetl-workers` (incl. the shard-1 app label), `Rules` `noetl-materializer-lag`, managedAlertmanager via OperatorConfig `config` + secret `alertmanager` (`memory/gke-prod-monitoring-gmp.md`, `ci/manifests/noetl/gmp/`) | SM* | Metric **history** does not migrate; see §5.9 |
| VictoriaMetrics | **kind only** — not in prod | — | `ci/vmstack/`, `vmrule-*.yaml` are dev artifacts |

### 3.2 Workloads — namespace `noetl`

| Workload | Shape (source) | Class |
| :-- | :-- | :-- |
| `noetl-server-rust` | 1 replica, `maxUnavailable=0/maxSurge=1`, port 8082, image `…/noetl/server-rust@sha256:…` — **prod runs v3.52.0** (`memory/MEMORY.md`) while `server-rust-deployment-prod.yaml` is pinned at v3.39.5 → **the checked-in manifest is stale; L2 is authoritative** | SR |
| `noetl-worker-rust` (user pool) | 2 replicas baseline, `WORKER_POOL_NAME=worker-rust-pool`, consumer `noetl_worker_rust_shared`, filter `noetl.commands.shared.>`, `WORKER_MAX_CONCURRENT=4`, req 250m/128Mi, lim 2 CPU/768Mi, `dshm` emptyDir, `NOETL_IPC_CACHE_BUDGET_BYTES=256Mi` | SR |
| `noetl-worker-system-pool` (shard 0) | 1 replica, SA `noetl-worker-system-pool`, `NOETL_MATERIALIZER_ENABLED=true`, `NOETL_STATE_BUILDER=offserver`, `NOETL_SHARD_INDEX=0`, `NOETL_SHARD_COUNT=2`, `NOETL_STATE_AFFINITY_ROUTE=true`, `NOETL_RESULT_MATERIALIZER_ENABLED=true` (#104 Phase B, left on), consumer `noetl_worker_system_rust_shard0`, filter `noetl.commands.system.shard.0.>`, req 250m/1Gi lim 2/2Gi | SR |
| `noetl-worker-system-pool-shard1` | 1 replica, clone of shard 0 with `NOETL_SHARD_INDEX=1`, consumer `…_shard1`, filter `…shard.1.>`, **distinct app label** `noetl-worker-system-pool-shard1` (selectors are immutable; the two must not share one) | SR |
| KEDA `ScaledObject noetl-worker-rust` | min 2 / max 20, trigger nats-jetstream `nats-headless.nats.svc:8222`, stream `NOETL_COMMANDS_RUST`, consumer `noetl_worker_rust_shared`, lag 10 | SR |
| `cronjob-scheduled-cleanup` | `system/scheduled_cleanup` | SR |
| Services | `noetl` (selector `app=noetl-server-rust`), `noetl-worker-rust-metrics`, `noetl-worker-system-pool-metrics` | SR |
| Secrets | **`noetl-secret`** (`NOETL_ENCRYPTION_KEY`, `NOETL_PASSWORD`, `POSTGRES_PASSWORD`), **`noetl-internal-api-token`** (`token`) | **SM — see §5.3** |
| RBAC | SA + Role + RoleBinding `noetl-worker-system-pool` (narrow: one Secret by name + configmaps) | SR |

> **Live-state warning.** Prod has been mutated repeatedly with
> `kubectl set image` / `set env` (#103 flip, #104 Phase B, #166 Phase 4
> and Phase 5, #172). The checked-in `*-prod.yaml` manifests explicitly
> say they pin a *past* state. **Rebuild the new cluster's manifests from
> the L2 live snapshot, not from git.** Reconciling git to live is a
> worthwhile side-quest but must not be conflated with the migration.

### 3.3 Data plane and dependencies

| Component | Detail | Class |
| :-- | :-- | :-- |
| **Cloud SQL `noetl-shared-pg`** | POSTGRES_15, ENTERPRISE, db-g1-small, private IP only (PSA range `noetl-cloudsql-psa-range`), hosts DBs `postgres` + `noetl` (platform) + `demo_noetl` (tenant/app) | **SM — the big one** |
| PgBouncer | ns `postgres`, `pool_mode=transaction`, 1–2 replicas + `cloud-sql-proxy:2.18.3` sidecar (GSA `noetl-cloudsql-proxy`, KSA `cloudsql-proxy`, port 6432); server sets `NOETL_PG_STATEMENT_CACHE_CAPACITY=0` to be safe behind it; egress firewall rule `noetl-allow-cloudsql-3307` | SR (config) |
| **NATS / JetStream** | ns `nats`, helm, file store 5Gi. Streams `NOETL_COMMANDS_RUST`, `noetl_events`. Consumers: `noetl_worker_rust_shared`, `noetl_worker_system_rust_shard0/1` (+ drained legacy `noetl_worker_system_rust`, residue `obs_shard0/1`), `noetl_materializer`, `noetl_state_builder`, `noetl_result_materializer` | **SM — must be drained, not copied (§5.5)** |
| Gateway | ns `gateway`, Deployment+Service `gateway`, ClusterIP :80 → targetPort 8090; reached only via Cloudflare Tunnel | SR |
| **Cloudflare Tunnel** | ns `cloudflare`, `cloudflared`, tunnel `noetl-gke-gateway`, hostname `gateway.mestumre.dev`, 1–2 replicas HPA (`automation/cloudflare/gke_gateway_edge.yaml`) | SR + EX |
| GUI | Cloudflare **Pages** project `noetl-gui`, domain `mestumre.dev` — `deploy_gui=false` in cluster | EX |
| Travel app (Muno) | `travel.mestumre.dev`; in the gateway CORS allow-list. Hosting to confirm (L12) — believed Cloudflare Pages | EX |
| Auth0 | tenant `mestumre-development.us.auth0.com`, redirect `https://mestumre.dev/login`; #169 JWT-sig verification in **shadow** | EX |
| **Artifact Registry** | `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/{server-rust,noetl-worker-rust,gateway,…}`, prod pinned by immutable digest | **SM (§5.2)** |
| **GSM secrets** | at least `duffel-api-test`, plus hotelbeds / hotelbeds-transfers / hotelbeds-activities / google-places / amadeus / vertex credentials. Read at runtime by the worker via the **metadata server WI token → Secret Manager REST** (`automation/agents/mcp/*.yaml`, ai-meta#137) | **SM — values are secret; operator-only (§5.3)** |
| **GCS `noetl-demo-19700101-results`** | #104 Phase B result tier, **SHADOW** (Phase C/D read paths OFF, `authoritative=false`); server-mediated writes via WI/ADC | SM (discardable) |
| Other GCS | `gs://{project}-noetl-state` (IAP/terraform state), `gs://tradetrend/...` (IBKR, unrelated to noetl prod) | SM (confirm L10) |
| MCP providers | duffel, hotelbeds ×3, google-places, amadeus, vertex — dispatched in-worker; auth via WI + GSM | SR (playbooks) + SM (secrets) |
| **EHDB** | **not in prod.** All `NOETL_EHDB_*` off; no PVC, no writer, no durable segments | — (nothing to migrate) |

---

## 4. Prerequisites and blockers

### 4.1 BLOCKER #1 — billing (everything waits on this)

`shastaratech-noetl-prod` (folder `687234939033`) exists and is ACTIVE but
is **not billing-linked**. Billing account `0153F3-73E360-BD0B38` is at
its **5-project cap**. Verified read-only:

```
shastaratech-noetl-dev       True
shastaratech-billing-admin   True
shastaratech-obs-prod        True
shastaratech-youtube-prod    True
shastaratech-dns-prod        True
```

`noetl-demo-19700101` is **not on this billing account** — so **retiring
old prod frees nothing here.** Two ways forward, both operator actions:

- **(a) Quota increase (preferred).** Request a projects-per-billing-account
  increase in the Cloud Billing console (Billing → account → Quotas, or a
  support case). Unblocks all 6 blocked projects at once. Lead time:
  hours to days, unpredictable.
- **(b) Free a slot by unlinking one of the five.** Immediate, but
  destructive to whatever runs there — unlinking billing stops billable
  resources in that project. Candidate ranking is a **user decision**
  (§7): `shastaratech-billing-admin` (likely no billable workloads) and
  `shastaratech-youtube-prod` (unrelated to noetl) are the plausible
  candidates; `shastaratech-obs-prod` and `-dns-prod` are probably needed
  *by* this migration; `shastaratech-noetl-dev` should be preserved as the
  pre-prod rehearsal target (§5.1).

**Do not unlink `shastaratech-noetl-dev` and do not touch old prod's
billing before the flip.** Old prod must stay fully funded until §5.10.

### 4.2 Other prerequisites

| # | Prerequisite | Check (read-only) | Risk if skipped |
| :-- | :-- | :-- | :-- |
| P1 | Billing linked (§4.1) | `gcloud billing projects describe shastaratech-noetl-prod` | cluster create fails outright |
| P2 | APIs enabled: container, sqladmin, secretmanager, artifactregistry, servicenetworking, compute, monitoring, iamcredentials | `gcloud services list --enabled --project shastaratech-noetl-prod` | each fails at first use |
| P3 | **Global CPU quota ≥ 64** (`CPUS_ALL_REGIONS`) — both provisioning playbooks precheck this (`min_global_cpu_quota: 64`, `enforce_cpu_quota_check: true`) | `gcloud compute project-info describe --project shastaratech-noetl-prod` | Autopilot upgrade surges fail mid-flight |
| P4 | Regional quota us-central1: CPUs, SSD_TOTAL_GB, IN_USE_ADDRESSES | same | scale-up stalls under load |
| P5 | GPU quota — **not needed**; SLM/GPU work is kind/dev only | — | n/a |
| P6 | Org policies on org `561323743912` / folder `687234939033` (shielded VM, external IP restrictions, `iam.disableServiceAccountKeyCreation`, `compute.restrictVpcPeering` for Cloud SQL PSA) | L14 | silent create failures, PSA peering refused |
| P7 | Cloudflare API token with zone `mestumre.dev` DNS + Tunnel + Pages scopes | `CLOUDFLARE_API_TOKEN` env | cannot canary or flip |
| P8 | GSM secret **values** available to the operator (agent must never read them) | — | providers fail post-cutover |
| P9 | `NOETL_ENCRYPTION_KEY` retrievable from old prod | operator only | **catastrophic, unrecoverable** |
| P10 | T4 sequencing decision recorded on ai-meta#194 | — | parallel session collides |
| P11 | Decide GSM/monitoring project home (§7) | — | rework mid-migration |
| P12 | Freeze window agreed; Muno/travel users notified | — | user-visible outage |

---

## 5. Migration plan

Nine stages. Each has an entry gate, operator actions, verification, and a
rollback. **Rollback target is the old cluster, untouched and running,
until Stage 8.** That is the core safety property: nothing is deleted in
old prod until the new cluster has soaked.

### Stage 0 — rehearse in `shastaratech-noetl-dev`

**Do this while waiting on billing.** `shastaratech-noetl-dev` is already
billing-enabled. Rehearse §5.1–§5.6 there end-to-end with a scratch
database. Every IAM binding, WI annotation, PSA range, and playbook
`--set` you get wrong will be found here for free.

Deliverable: a completed `--set` line for the fresh-stack playbook that
provisions cleanly from zero, plus a written list of corrections to
`repos/ops` (open an ai-task issue per `agents/rules/issue-tracking.md`).

Rollback: delete the dev cluster. No prod exposure.

---

### Stage 1 — provision the cluster and project infrastructure (dark)

Gate: P1–P6 all green.

**Preferred: NoETL provisioning playbook** (per the IaC-as-playbooks
direction; see `agents/rules/execution-model.md`). The provisioning path
already exists at `repos/ops/automation/gcp_gke/`:

```bash
cd repos/ops
noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml \
  --runtime local \
  --set action=provision \
  --set project_id=shastaratech-noetl-prod \
  --set region=us-central1 \
  --set cluster_name=noetl-cluster \
  --set release_channel=regular \
  --set create_artifact_registry=true \
  --set repository_id=noetl \
  --set min_global_cpu_quota=64 \
  --set enforce_cpu_quota_check=true
```

Cluster-only lifecycle (snapshot / provision / destroy) is
`automation/gcp_gke/gke_cluster_recreate.yaml`.

> **Blueprint caveat.** `automation/gcp_gke/blueprints/noetl-cluster-blueprint.json`
> is a `describe` dump of the **old** cluster and embeds
> `workloadIdentityConfig.workloadPool = noetl-demo-19700101.svc.id.goog`
> plus old network/endpoint values. Do **not** feed it to `provision`
> unmodified. Either run with `use_blueprint=false` and explicit `--set`,
> or fork it to `blueprints/shastaratech-noetl-prod-cluster.json` with the
> project-scoped fields rewritten. Snapshot the *new* cluster after
> creation to establish its own blueprint.

**gcloud equivalent** (what the playbook shells out to; the shape to match):

```bash
PROJECT=shastaratech-noetl-prod
gcloud services enable container.googleapis.com sqladmin.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com \
  servicenetworking.googleapis.com monitoring.googleapis.com \
  --project $PROJECT

gcloud container clusters create-auto noetl-cluster \
  --project $PROJECT \
  --region us-central1 \
  --release-channel regular \
  --network default --subnetwork default \
  --enable-private-nodes
# Autopilot enables Workload Identity, GMP, and the CSI drivers by default.
```

**Terraform equivalent** (for reference, if the org standardizes on TF):

```hcl
resource "google_container_cluster" "noetl" {
  provider            = google-beta
  name                = "noetl-cluster"
  project             = "shastaratech-noetl-prod"
  location            = "us-central1"
  enable_autopilot    = true
  release_channel { channel = "REGULAR" }
  network             = "default"
  subnetwork          = "default"
  private_cluster_config { enable_private_nodes = true }
  deletion_protection = true
}
```

**Also in this stage:**

- Artifact Registry repo `noetl` in `us-central1`.
- Cloud SQL: new instance (§7 decides self-hosted vs Cloud SQL; assume
  Cloud SQL). **Size up from `db-g1-small`** — `memory/noetl-scale-constraints.md`
  records that tier's ~25–50 connection ceiling as a live scale blocker
  against a 20-replica worker pool. A migration is the natural moment to
  fix it. Private IP + a PSA range in the new VPC.
- Reserve any static IPs the new edge needs (probably none — the gateway
  is ClusterIP behind a tunnel).

**Verify:** cluster RUNNING; `kubectl --context $NEW get nodes`; WI pool
is `shastaratech-noetl-prod.svc.id.goog`; GMP namespaces present.

**Rollback:** delete the new cluster. Old prod is untouched and serving.

#### Autopilot vs Standard — the actual decision

Today's prod is **Autopilot**, and everything currently running fits it:

- The "system pool" is a **NATS-consumer/env** distinction, not a node
  pool. No taints, no node labels, no nodeSelectors in the prod manifests.
- The #166 shard-0/shard-1 split is two single-replica Deployments —
  Autopilot schedules those fine.
- The only volume in the workload specs is a `dshm` **emptyDir**.
- No hostPath, no privileged containers, no local SSD in prod today.

Therefore: **provision Autopilot for parity.** It removes node-pool
sizing from the migration entirely.

**Where Standard becomes a real question — T4 / EHDB, later.** T4's
writer needs (a) a PVC for `NOETL_COMMAND_BUS_WRITER_DIR`, (b) exactly one
writer per shard, and (c) fsync latency good enough to hold the measured
bus p99 (~137µs shadow; the 4ms first-seen figure is posture-A fsync
durability, not the bus). Autopilot supports (a) and (b) — an RWO PD via
the `premium-rwo` StorageClass, and a 1-replica StatefulSet or a
`strategy: Recreate` Deployment for the singleton. It does **not** give
local SSD without the `Performance` compute class. So:

- Migrate on **Autopilot**.
- Re-open Standard-vs-Autopilot as a **T4 design question**, benchmarked
  on `premium-rwo` first. Do not pre-emptively pay Standard's operational
  cost for a component that does not exist in prod yet.

StorageClasses: `premium-rwo` (SSD PD) for anything latency-sensitive,
`standard-rwo` otherwise. Set `reclaimPolicy: Retain` on any EHDB/Postgres
PVC created later.

---

### Stage 2 — images and Artifact Registry

Goal: the new cluster can pull **the exact digests old prod runs**.

Two options:

- **(a) Cross-project pull (fast, do this first).** Grant the new
  cluster's node service agent `roles/artifactregistry.reader` on the old
  repo. Zero copy, zero digest drift, and the new cluster runs bit-identical
  images. Creates a dependency on the old project that must be removed
  before Stage 8.
- **(b) Copy the images (required before decommission).**

  ```bash
  gcloud artifacts docker images copy \
    us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/server-rust@sha256:<digest> \
    us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust:v3.52.0 \
    --project shastaratech-noetl-prod
  ```

  **Digests change on copy** (new registry, new manifest location) unless
  copied by digest with `--include-tags`; re-pin the manifests to the new
  digests and record the old→new mapping in this file.

**Recommendation:** (a) for the dark bring-up and canary — it removes a
whole class of "is it the image?" doubt — then (b) during the soak, with
a manifest re-pin and a rolling restart, before Stage 8.

**Verify:** `crane digest` / `gcloud artifacts docker images describe` on
both sides match for the copied set.

**Rollback:** revert the manifest pin. Images are immutable; nothing is lost.

---

### Stage 3 — secrets, IAM, Workload Identity

**⚠ `NOETL_ENCRYPTION_KEY` — read this before anything else.**
The Rust server fails closed without it (ai-meta#61) and, critically, the
credential store in `noetl.credential` is **AES-GCM encrypted with it**.
The migrated database and this key are a matched pair. If the key is lost
or a fresh one is generated, **every stored credential in prod becomes
permanently undecryptable** and every keychain-backed provider (Auth0,
Duffel, HotelBeds ×3, Google Places, Amadeus, tenant DSNs) breaks with no
recovery path but manual re-entry of every secret.

Operator pre-flight, **before Stage 4**:

1. Retrieve `NOETL_ENCRYPTION_KEY` from old prod's `noetl-secret`.
2. Store it in the new project's GSM as a **versioned** secret.
3. Verify byte-identity (compare SHA-256 of the decoded value, never the
   value itself, and never in a chat transcript, a commit, or this file).

The agent must not read, print, or handle these values. This repo is
public (`agents/rules/safety.md`).

**Kubernetes secrets to recreate in ns `noetl` on the new cluster:**

| Secret | Keys | Source |
| :-- | :-- | :-- |
| `noetl-secret` | `NOETL_ENCRYPTION_KEY` (**must be identical**), `NOETL_PASSWORD`, `POSTGRES_PASSWORD` | old prod; `NOETL_PASSWORD` may change only if the DB role password changes with it |
| `noetl-internal-api-token` | `token` | may be **rotated** — it is a shared bearer between server and system pool, not encrypted-at-rest data. Rotating during migration is a free security win, but roll server and both system-pool Deployments together |

**GSM secrets** (L7 gives the full list; known: `duffel-api-test`,
hotelbeds ×3, google-places, amadeus, vertex). Recreate each in
`shastaratech-noetl-prod`:

```bash
# operator only — values never pass through the agent
gcloud secrets create duffel-api-test --project shastaratech-noetl-prod \
  --replication-policy=automatic
gcloud secrets versions add duffel-api-test --data-file=<file>
```

> The MCP playbooks read GSM via the metadata-server WI token against
> `projects/{project}/secrets/{name}/versions/latest:access`. Check
> whether the project is derived from the metadata server or hardcoded —
> if hardcoded to `noetl-demo-19700101`, that is a **code/playbook change**
> in `automation/agents/mcp/*.yaml` and must land before cutover. Add it
> as a Stage 3 sub-task with its own ai-task issue.

**GSAs + WI bindings to recreate** (L8 for the authoritative list):

| GSA | Bound KSA | Roles |
| :-- | :-- | :-- |
| `noetl-server-rust@…` | `noetl/noetl-server-rust` | `roles/storage.objectAdmin` on the results bucket; `roles/secretmanager.secretAccessor` as needed |
| `noetl-cloudsql-proxy@…` | `postgres/cloudsql-proxy` | `roles/cloudsql.client` |
| worker GSA(s) | `noetl/noetl-worker*`, `noetl/noetl-worker-system-pool` | `roles/secretmanager.secretAccessor` per provider secret; `roles/container.viewer` + `roles/mcp.toolUser` if the managed GKE MCP agent is used |

```bash
gcloud iam service-accounts add-iam-policy-binding <GSA>@shastaratech-noetl-prod.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:shastaratech-noetl-prod.svc.id.goog[noetl/noetl-server-rust]"
kubectl --context $NEW -n noetl annotate sa noetl-server-rust \
  iam.gke.io/gcp-service-account=<GSA>@shastaratech-noetl-prod.iam.gserviceaccount.com --overwrite
```

**Verify:** a throwaway pod using each KSA can mint a token and read one
non-sensitive secret. Do this *before* deploying the stack.

**Rollback:** delete the new bindings. No effect on old prod.

---

### Stage 4 — Postgres migration

The whole platform's source of truth. `noetl.event` is **append-only and
must never be purged** (`agents/rules/data-access-boundary.md`).

**Recommended: Database Migration Service (DMS), continuous.**

1. Create the destination Cloud SQL instance in the new project
   (POSTGRES_15+, right-sized above `db-g1-small` per §5.1).
2. Create a DMS **continuous** migration job, source = `noetl-shared-pg`
   (needs `pglogical`/logical decoding and network reachability — likely a
   VPC peering or a public-IP-with-authorized-network window on the
   source; note the source is **private-IP only** today, so this needs
   deliberate setup).
3. Let it reach steady-state CDC replication. All three DBs: `noetl`,
   `demo_noetl`, `postgres`.
4. At cutover (Stage 6) with writers stopped: verify zero replication lag,
   then **promote** the destination.

**Fallback: dump/restore** (simpler, needs a longer freeze):

```bash
# operator, from a host that can reach both
pg_dump -h <old-pgbouncer-or-proxy> -U postgres -Fc -d noetl      > noetl.dump
pg_dump -h <old-pgbouncer-or-proxy> -U postgres -Fc -d demo_noetl > demo.dump
pg_restore -h <new> -U postgres -d noetl      --no-owner noetl.dump
pg_restore -h <new> -U postgres -d demo_noetl --no-owner demo.dump
```

Freeze duration = dump + restore time; size it from L6 before committing
to a window.

**Post-restore checks (all of these, before Stage 5 smoke):**

- Row counts match per table for `noetl.event`, `noetl.command`,
  `noetl.execution`, `noetl.catalog`, `noetl.credential`, `noetl.runtime`,
  `noetl.outbox`.
- `MAX(event_id)` on `noetl.event` matches (snowflake ids must not regress
  — a regression risks id collisions).
- **`prev_event_id` column + `idx_event_prev_event_id` exist.** These were
  provisioned once by the DB **owner** (`postgres`) on 2026-06-20 because
  the runtime `noetl` role is not the table owner; the server's startup
  `ensure_columns` is a best-effort no-op that logs a harmless WARN
  forever. A restore under the wrong role can silently drop them. Re-apply
  as `postgres` if missing.
- Roles/grants: `noetl`, `demo`, `auth`; `demo_can_read_noetl_schema`.
- **Credential decryption smoke** — with the migrated `NOETL_ENCRYPTION_KEY`,
  resolve one keychain alias end-to-end. This is the proof that §5.3 worked.

**Verify:** the new server starts, `/api/catalog/list` returns the same
count as old prod, one credential alias resolves.

**Rollback:** drop the destination instance. Source untouched — DMS is
read-only against the source; a dump is read-only by construction.

---

### Stage 5 — deploy the stack dark

Deploy to the new cluster with **identical image digests and identical
env** (from the L2 snapshot), pointed at the **new** database, but with
**no external traffic**.

Order (dependencies first):

1. namespaces: `noetl`, `nats`, `postgres`, `gateway`, `cloudflare`
2. KEDA operator
3. Cloud SQL proxy + PgBouncer (ns `postgres`)
4. NATS + JetStream (ns `nats`) — **fresh, empty streams**
5. secrets + SAs + RBAC (Stage 3)
6. `noetl-server-rust`
7. `noetl-worker-rust`, `noetl-worker-system-pool` (shard 0),
   `noetl-worker-system-pool-shard1`
8. KEDA ScaledObjects
9. GMP `PodMonitoring` + `Rules` + alertmanager
10. gateway
11. cloudflared — **a second, separate tunnel** with a *staging* hostname
    (e.g. `gateway-new.mestumre.dev`). Do **not** add a replica to the
    existing `noetl-gke-gateway` tunnel: Cloudflare load-balances across a
    named tunnel's connectors, which would split live traffic between two
    clusters backed by two different databases. That is a split-brain, not
    a canary.

**Stream/consumer bootstrap.** The new JetStream is empty. Create
`NOETL_COMMANDS_RUST` and `noetl_events` with the same config as old
(L5), and the durable consumers `noetl_worker_rust_shared`,
`noetl_worker_system_rust_shard0/1`, `noetl_materializer`,
`noetl_state_builder`, `noetl_result_materializer`. Note the #166 Phase 5
shape: the server shard-routes **every** `pool==system` command, so the
per-shard consumers must cover the full range `[0, COMMAND_SHARD_COUNT)`
— nothing stays on the legacy subject.

**CORS trap.** `gateway_cors_allowed_domains` is a single string and
`--set` **replaces** it. The canary hostname must be *appended* to the
full existing list (`mestumre.dev,gateway.mestumre.dev,travel.mestumre.dev`),
not substituted. Auth0 allowed callback/logout/web-origins need the
canary hostname too.

**Smoke on the new cluster (no user traffic):**

- server `/health`, `/api/catalog/list` count matches old
- register + execute a scratch playbook end-to-end
- both system-pool shards claim work; `state_equivalence_mismatch_total = 0`
- materializer lag → 0; `projected == acked`
- one credential alias resolves (Stage 4 check, repeated in situ)
- one Muno/travel planner turn end-to-end against the canary hostname
- GMP `up{namespace="noetl"}` shows every target scraped

**Verify:** all of the above green, ≥ 1h stable, 0 pod restarts.

**Rollback:** scale the new cluster to zero. Zero user impact — no traffic
has ever reached it.

---

### Stage 6 — data cutover (the freeze)

**This is the only user-visible outage.** Everything before it is
additive; everything after is DNS.

Pre-stage (≥ 24h before): drop DNS TTLs for `gateway.mestumre.dev` and
any travel/GUI records to **60s**. Cloudflare-proxied records are already
effectively instant, but do it for any grey-clouded record.

Freeze sequence:

1. **Announce the window.** Muno/travel is user-facing.
2. **Stop new work on old prod.** Pause the KEDA ScaledObjects and scale
   `noetl-server-rust` to 0 on the **old** cluster. Leave the workers up
   to finish in-flight commands.
3. **Drain.** Wait for: JetStream `NOETL_COMMANDS_RUST` pending = 0; the
   `noetl_events` WAL consumers (`noetl_materializer`, `noetl_state_builder`)
   pending = 0; no running executions. **This is load-bearing** — with
   `NOETL_EVENT_INGEST_PUBLISH_ONLY=true` the materializer is the *sole*
   `noetl.event` writer, so any event still in JetStream that has not been
   materialized exists **only** in the old broker's file store and is lost
   the moment the old cluster is abandoned. Do not proceed until pending
   is zero and stays zero.
4. **Scale old workers to 0.** Old prod is now quiesced.
5. **Finish the data move.** DMS: confirm zero lag, promote the
   destination. Dump/restore: run it now.
6. **Re-run the Stage 4 post-restore checks** against the promoted DB.
7. **Copy the GCS results bucket** if you want #104's shadow history:
   `gcloud storage rsync -r gs://noetl-demo-19700101-results gs://shastaratech-noetl-prod-results`.
   It is shadow, non-authoritative, and nothing reads it (Phase C/D off) —
   skipping is defensible. Point the new server's tier env at the new
   bucket either way.
8. **Bring the new cluster up** at full replica count; re-verify the
   Stage 5 smoke list.

**Rollback (still cheap here):** the old cluster is intact and its data is
untouched — DMS/dump read from the source without modifying it. Scale old
back up, unpause KEDA. Cost: the freeze window, and any work done on the
new cluster after promote is stranded (so: no user traffic until Stage 7).

---

### Stage 7 — DNS canary, then full flip

The edge is **Cloudflare Tunnel**, which changes the shape of this step
for the better: `gateway.mestumre.dev` is a CNAME to
`<tunnel-id>.cfargotunnel.com`, and the tunnel is an *outbound* connection
from the cluster. There is **no origin IP to move and no TLS certificate
to re-issue** — Cloudflare terminates TLS at the edge, and the Pages sites
keep their own certs. Confirm against L12; if any hostname is grey-clouded
to a GKE LoadBalancer IP, that one *does* need an A-record flip and
low-TTL pre-stage.

**7a — canary.** Send a small share of real traffic to the new cluster:

- **Preferred:** a Cloudflare **Load Balancer** on `gateway.mestumre.dev`
  with two origin pools (old tunnel, new tunnel) weighted 95/5, plus a
  health check. Weight is adjustable in seconds and the health check
  drains a bad pool automatically.
- **Simpler:** keep `gateway.mestumre.dev` on old and drive synthetic +
  internal-user traffic at `gateway-new.mestumre.dev`. No real-user
  exposure, less signal.

> **Canary caveat — two clusters, one database.** After Stage 6 the new
> cluster owns the promoted database and the old cluster's DB is a stale
> orphan. A weighted canary therefore means *some* users are served by a
> cluster with **stale data**, and any writes it accepts diverge. Either
> (i) repoint the old cluster's server at the new database for the canary
> window — extra risk, cross-project DB access — or (ii) treat 7a as
> **synthetic-only** and go straight to 7b. **Recommendation: (ii).** The
> tunnel makes the flip fast and reversible, so a real-user canary buys
> little and risks split-brain. Take the honest small cutover instead of a
> canary that cannot be correct.

**7b — flip.** Repoint `gateway.mestumre.dev` at the new tunnel (or set
the LB pool weight to 0/100). Update Cloudflare Pages env for the GUI and
travel app if they carry a gateway URL. Verify:

- real login end-to-end (this is also the chance to collect the #169
  `outcome=success` sample the JWT-signature enforce flip is waiting on)
- a full Muno planner turn with widgets
- SSE / subscription delivery
- GMP: no error-rate or latency regression vs the old baseline

**7c — soak, 7 days.** Old cluster stays up, scaled to 0, fully
recoverable. Watch materializer lag, worker restarts, Cloud SQL
connections, p99 latency, cost.

**Rollback:** flip DNS/LB weight back. Old cluster scales back up. If any
writes landed on the new DB during the flip, they must be reconciled or
accepted as lost — so keep 7b short and decide *fast*. Past ~1h of real
traffic, forward-fix beats rollback.

---

### Stage 8 — decommission the old prod space

Gate: **7 clean days** after the flip, plus explicit user sign-off.
Nothing here is reversible.

1. Cut the last dependency on the old project: confirm images are copied
   (Stage 2b) and manifests re-pinned; remove the cross-project AR reader
   grant.
2. **Take a final, verified backup** of `noetl-shared-pg` — export to GCS
   in a project that will survive, and **test-restore it once**. The
   append-only `noetl.event` log is irreplaceable.
3. Delete in order: NoETL workloads → NATS → gateway/cloudflared → old
   Cloudflare tunnel `noetl-gke-gateway` → GKE cluster → Cloud SQL (with
   deletion protection cleared, after the backup is verified) → GCS
   buckets → GSM secrets → GSAs → static IPs → Artifact Registry.
4. Unlink billing on `noetl-demo-19700101`, then shut down the project
   (30-day recovery window — do not skip straight to delete).
5. Update: `repos/ops` manifests and playbook defaults (`project_id`,
   image registry paths, `kube_context` guards), `agents/` rules, the
   ai-meta wiki (`Home.md`, `Sessions-Log.md`, `Releases.md`, the relevant
   `Umbrella-*.md`) per `agents/rules/wiki-maintenance.md` Rule 0a, and
   `memory/`.

**No rollback.** This stage is the point of no return; that is why it is
gated on soak + sign-off.

---

### Stage 9 — resume the roadmap

1. T4 Step 0: bake server v3.58.0 / worker v5.78.0 on the new cluster with
   `NOETL_COMMAND_BUS` absent (= `nats`). Soak.
2. Re-open Standard-vs-Autopilot as a T4 writer question (§5.1).
3. Run T4 per `playbooks/194-l1-t4-prod-cutover.md`, re-validating findings
   F3 (missing writer manifests) and F4 (writer-singleton hazard) against
   the new cluster's autoscaling shape.
4. Then #169 shadow→enforce, #188 NATS credential move, and the rest.

---

## 6. Risk register

| # | Risk | Impact | Mitigation |
| :-- | :-- | :-- | :-- |
| R1 | `NOETL_ENCRYPTION_KEY` lost or regenerated | **Catastrophic** — every stored credential unrecoverable | §5.3 pre-flight; verify by hash; decryption smoke test in Stage 4 *and* Stage 5 |
| R2 | JetStream drained incompletely at Stage 6 | Silent permanent event loss (materializer is sole `noetl.event` writer) | Hard gate: pending = 0 and stable, on **every** consumer, before promote |
| R3 | Live prod env has drifted from the checked-in manifests | New cluster runs a subtly different config | Rebuild from the L2 live snapshot, not git; diff both and record the delta |
| R4 | MCP playbooks hardcode the old project id for GSM | Every provider fails post-cutover | Grep `automation/agents/mcp/*.yaml` in Stage 3; parameterize; test in Stage 5 |
| R5 | CORS list clobbered by `--set` | Browser login breaks with an opaque `Failed to fetch` | Always pass the **full** list; verify with the `kubectl get deploy -n gateway` jsonpath in the ops README |
| R6 | Cloud SQL PSA peering blocked by org policy | Stage 1 stalls | Check L14/P6 up front; rehearse in Stage 0 |
| R7 | New Cloud SQL sized at `db-g1-small` again | Reproduces the known connection-ceiling stall | Right-size in Stage 1; recheck `maxReplicas × WORKER_MAX_CONCURRENT` against the new ceiling |
| R8 | Snowflake id regression after restore | id collisions in `noetl.event` | Verify `MAX(event_id)` in Stage 4 |
| R9 | Tunnel-replica canary splits live traffic across two DBs | Split-brain writes | Separate tunnel + staging hostname; §7a recommendation (ii) |
| R10 | Billing quota never granted | Migration indefinitely blocked | Decide early: quota request vs. freeing a slot (§7) |
| R11 | Another session starts T4 in parallel | Two prod cutovers at once | Record the sequencing decision on ai-meta#194 before Stage 1 |
| R12 | GMP metric history does not migrate | Alert thresholds lose their baseline | Export key dashboards/queries; expect a fresh baseline; consider `shastaratech-obs-prod` as the metrics home (§7) |
| R13 | Auth0 callback/CORS not updated for canary hostname | Login fails on the canary only | Stage 5 checklist; #169 is in shadow so signature enforcement will not compound it |

---

## 7. Open decisions for the user

| # | Decision | Options | Recommendation |
| :-- | :-- | :-- | :-- |
| D1 | **Target project** | `shastaratech-noetl-prod` (exists, ACTIVE, folder `687234939033`) / something else | Confirm `shastaratech-noetl-prod` — everything above assumes it |
| D2 | **Billing unblock** | (a) request a projects-per-account quota increase; (b) unlink one of the 5 currently-linked projects | Start (a) immediately; in parallel identify a sacrificial project for (b). Candidates: `shastaratech-billing-admin`, `shastaratech-youtube-prod`. **Do not** unlink `-noetl-dev` (rehearsal target), `-obs-prod` or `-dns-prod` (likely needed by this migration) |
| D3 | **Autopilot vs Standard** | Autopilot (parity with today) / Standard (node control for a future EHDB writer) | **Autopilot.** Nothing in prod today needs Standard. Revisit as a T4 design question, benchmarked on `premium-rwo` first |
| D4 | **Postgres** | new Cloud SQL / self-hosted in-cluster / migrate as-is at `db-g1-small` | **Cloud SQL, right-sized above `db-g1-small`.** Self-hosting adds a stateful component to a migration that currently has almost none |
| D5 | **DB move mechanism** | DMS continuous (short freeze, more setup — source is private-IP only) / dump-restore (simple, longer freeze) | DMS if the freeze must be < ~15min; dump/restore otherwise. Size the freeze from L6 first |
| D6 | **GSM home** | `shastaratech-noetl-prod` / a shared secrets project | Secrets in `shastaratech-noetl-prod` — same project as the workloads keeps WI bindings simple and project-scoped |
| D7 | **Monitoring home** | GMP in `shastaratech-noetl-prod` / centralize in `shastaratech-obs-prod` | The existence of `shastaratech-obs-prod` suggests a deliberate central-observability layout. Decide **before** Stage 1 — moving it later means re-pointing every PodMonitoring and alert route |
| D8 | **Region** | `us-central1` (parity) / elsewhere | `us-central1`. Region changes are latency- and cost-relevant and orthogonal to this migration; do not bundle them |
| D9 | **Canary strategy** | weighted Cloudflare LB with real users / synthetic-only then flip | **Synthetic-only then flip** (§7a). A weighted canary cannot be data-correct once the DB is promoted |
| D10 | **Results bucket history** | rsync `noetl-demo-19700101-results` / start empty | Start empty. It is #104 **shadow**, non-authoritative, and nothing reads it. Copy only if the shadow soak data is wanted |
| D11 | **Internal-API token** | carry over / rotate during migration | Rotate. It is a shared bearer, not encrypted-at-rest data, and this is the cheapest window to rotate it |
| D12 | **Freeze window** | date/time + user notification for Muno/travel | Needs a calendar decision before Stage 6 |
| D13 | **`#188` NATS plaintext credential** | fix during the migration / keep as-is and fix after | Keep as-is. It is a coordinated NATS+clients change ([ai-meta#188](https://github.com/noetl/ai-meta/issues/188)) and bundling it violates one-variable-per-change. Schedule right after the soak |

---

## 8. Tracking

Per `agents/rules/issue-tracking.md`, this needs an ai-meta umbrella issue
before Stage 1 (`ai-task` + `repo:ops`), added to
[board 3](https://github.com/orgs/noetl/projects/3/views/1) per
`agents/rules/roadmap-boards.md`, with sub-issues in `noetl/ops` per stage
that ships a PR. **Not opened by this session** — the plan is design-only
and the umbrella should be opened when the billing blocker clears and the
work actually starts.

Wiki (`agents/rules/wiki-maintenance.md` Rule 0a): a migration of this
size warrants `Umbrella-Prod-Migration.md` on the ai-meta wiki plus a
`Home.md` Active-umbrellas row, created with the umbrella issue.

## 9. Sources

Read-only, this session:

- `repos/ops/automation/gcp_gke/{README.md,noetl_gke_fresh_stack.yaml,gke_cluster_recreate.yaml}`
- `repos/ops/automation/gcp_gke/blueprints/noetl-cluster-blueprint.json` (old-cluster `describe` dump)
- `repos/ops/automation/cloudflare/gke_gateway_edge.yaml`
- `repos/ops/ci/manifests/noetl/{server-rust,worker-rust,worker-system-pool}-deployment-prod.yaml`, `serviceaccount-worker-system-pool.yaml`
- `repos/ops/ci/manifests/keda/*.yaml`, `repos/ops/automation/agents/mcp/duffel.yaml`
- `playbooks/194-l1-t4-prod-cutover.md` (findings F1–F4)
- `memory/`: `gke-prod-monitoring-gmp`, `104-phaseb-prod-shadow-live`,
  `166-phase5-prod-rollout-complete`, `172-phase4-affinity-2deploy-prod`,
  `noetl-scale-constraints`, `MEMORY.md`
- `gcloud billing projects list --billing-account=0153F3-73E360-BD0B38`,
  `gcloud projects list` (both read-only)
