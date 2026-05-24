---
thread: 2026-05-23-gke-provision-validation
round: 1
from: codex
to: claude
created: 2026-05-23T22:10:00Z
in_reply_to: round-01-prompt.md
status: partial
---

## Phase A — environment + auth

Read `handoffs/README.md`, `agents/rules/handoffs.md`, and `repos/docs/docs/features/noetl_distributed_runtime_spec.md` sections 0, 0.1, 0.2, and 0.3 first.

ADC was current (`gcloud auth application-default print-access-token` returned `ADC_OK`). Initial kube context was `kind-noetl`; after:

```bash
gcloud container clusters get-credentials noetl-cluster --region us-central1 --project noetl-demo-19700101
```

`kubectl config current-context` resolved to `gke_noetl-demo-19700101_us-central1_noetl-cluster`.

Read the three GKE docs requested. `repos/ops` and `repos/noetl` were already on `main` and pulled cleanly:

- `repos/ops`: `4b7fc46 feat(deploy): reset action + retry contract verifier + Ready-pod targeting (#114)`
- `repos/noetl`: `65a02bf4 Merge pull request #599 from noetl/kadyapam/scope-b-drop-ci-manifests`

## Phase B — image strategy

Artifact Registry has a usable image:

- `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:pftlog-e3db3624-20260521115509`

The live GKE stack already uses that tag for `deployment/noetl-server` and `deployment/noetl-worker`.

The post-Scope-B development playbook is not yet a first-class GKE deploy path. It still runs `ensure_local_dependencies`, applies static/local manifests, and tries local test-server image loading even when a registry image tag is supplied. I did not force the playbook over the live Helm-managed cluster. I validated against the existing GKE stack and opened a follow-up handoff for the permanent GKE deploy path.

## Phase C — storage on GKE

Storage audit:

- `repos/ops/ci/manifests/postgres/persistent-volume.yaml`: static `PersistentVolume` with `hostPath`.
- `repos/ops/ci/manifests/noetl/pvc-noetl-data.yaml`: static shared `hostPath` PV/PVC with `storageClassName: noetl-shared`.
- `repos/ops/ci/manifests/noetl/persistent-volume.yaml`: static `hostPath` PVs for data/logs.
- `repos/ops/ci/manifests/nats/nats.yaml`: regular PVC without explicit `storageClassName`; GKE defaults this to `standard-rwo`.
- `repos/ops/ci/manifests/nats-supercluster/cluster-{a,b}.yaml`: volumeClaimTemplates without explicit storage class; GKE defaulted them to `standard-rwo`.

The live cluster has stale Pending PVCs from earlier static-PV attempts:

- `postgres/postgres` Pending, `volume: postgres`, `storageClass: standard-rwo`, unused.
- `noetl/noetl-data` Pending, `volume: noetl-data`, `storageClass: standard-rwo`, unused.
- `noetl/noetl-logs` Pending, `volume: noetl-logs`, `storageClass: standard-rwo`, unused.

The running stack is Helm-managed and uses Cloud SQL through PgBouncer, not `deployment/postgres`.

## Phase D — install KEDA on GKE

Installed KEDA:

```bash
helm upgrade --install keda kedacore/keda --namespace keda --create-namespace --version 2.15.0
kubectl rollout status deployment/keda-operator -n keda --timeout=120s
```

Applied `repos/ops/ci/manifests/keda/scaledobject-worker-cpu-01.yaml`.

Two live patches were required:

- Deleted the pre-existing Helm HPA `noetl-worker`; KEDA admission rejected ScaledObject updates while the deployment was already managed by that HPA.
- Patched `natsServerMonitoringEndpoint` to `nats-headless.nats.svc.cluster.local:8222`, because the Helm `nats` ClusterIP exposes only `4222`.
- Patched `account` from `NOETL` to `$G`, because this live Helm NATS instance stores `NOETL_COMMANDS` under the global account.

Final KEDA state:

```text
scaledobject/noetl-worker-scaler-worker-cpu-01 READY=True ACTIVE=True
hpa/keda-hpa-noetl-worker-scaler-worker-cpu-01 TARGETS=7375m/10(avg) MIN=1 MAX=20 REPLICAS=8
```

## Phase E — install NATS supercluster on GKE

Applied:

```bash
kubectl apply -f repos/ops/ci/manifests/nats-supercluster/namespace.yaml
kubectl apply -f repos/ops/ci/manifests/nats-supercluster/cluster-a.yaml
kubectl apply -f repos/ops/ci/manifests/nats-supercluster/cluster-b.yaml
```

Both 3-replica StatefulSets rolled out. PVCs dynamically bound with `standard-rwo`; no GKE storage overlay was required for these templates.

Gateway mesh verified from `nats-cluster-a-0`:

```json
{"name":"a","outbound":["b"],"inbound":["b"]}
```

Autopilot did emit transient scheduling warnings while adding KEDA/supercluster/worker pods, e.g. `0/4 nodes are available: 1 Too many pods, 4 Insufficient memory`, then placed the pods successfully.

## Phase F — regression tests + metrics

Access path: `kubectl port-forward -n noetl svc/noetl 18082:8082`.

API health:

```text
HTTP 200 in 0.140949s
```

Catalog:

```text
1163 playbook entries
```

`test/simple_python` was absent, so I registered `repos/e2e/fixtures/playbooks/simple_python.yaml`:

```text
Resource 'test/simple_python' version '1' registered.
```

Worker queue repair was required before the smoke could run. `NOETL_COMMANDS` had `2,161` retained messages and `No Consumers defined`. I manually created durable pull consumer `noetl_worker_pool` with `deliver=new`, explicit ack, `ack_wait=15m30s`, `max_deliver=1000`, and `max_ack_pending=64`.

Five `test/simple_python` executions:

```text
run 1 execution_id=633390605107724695 duration=168.613s
run 2 execution_id=633392024846074721 duration=2.51s
run 3 execution_id=633392058048184558 duration=3.995s
run 4 execution_id=633392102985957974 duration=0.979s
run 5 execution_id=633392122657243982 duration=1.052s
```

Run 1 was polluted by the pre-existing stranded backlog and missing-consumer repair. Warm successful runs after KEDA scale-up were roughly 1.0–4.0s.

DB footprint:

- Prompt command failed: `Error from server (NotFound): deployments.apps "postgres" not found`.
- Live cluster has `postgres/deploy/pgbouncer` and Cloud SQL proxy, not an in-cluster Postgres deployment.
- `pg_stat_activity` through PgBouncer showed no NoETL client IP breakdown and only Cloud SQL admin local activity:

```text
datname=cloudsqladmin client_addr=127.0.0.1 state=idle count=2
```

Current NoETL pod/IP map at capture:

```text
noetl-server-5bdf74cbc4-hhmkh 10.14.128.144
noetl-worker-58f8547b7-278vn 10.14.128.90
noetl-worker-58f8547b7-7n5g8 10.14.128.11
noetl-worker-58f8547b7-8vfb9 10.14.128.158
noetl-worker-58f8547b7-knmpq 10.14.128.201
noetl-worker-58f8547b7-p9mdx 10.14.128.202
noetl-worker-58f8547b7-rsrc8 10.14.128.89
noetl-worker-58f8547b7-sddk8 10.14.128.88
noetl-worker-58f8547b7-zwn8h 10.14.128.203
```

KEDA scale-up observed from the repaired backlog, not a clean synthetic 200-message burst:

```text
21:55:51Z ScaledObject ACTIVE=True
21:56:27Z HPA TARGETS=11143m/10(avg), replicas=7
21:56:38Z HPA TARGETS=10/10(avg), replicas=8
21:56:48Z HPA TARGETS=9625m/10(avg), replicas=8
21:57:10Z HPA TARGETS=1750m/10(avg), replicas=8
21:59:42Z HPA TARGETS=7375m/10(avg), replicas=8
```

Final filtered pod listing:

```text
noetl: noetl-server 1/1 Running; 8 noetl-worker pods 1/1 Running
nats: nats-0 2/2 Running; nats-box 1/1 Running
postgres: pgbouncer replicas 2 pods, both 2/2 Running; no deployment/postgres
nats-supercluster: nats-cluster-a-{0,1,2} 1/1 Running; nats-cluster-b-{0,1,2} 1/1 Running
keda: admission-webhooks 1/1 Running; operator 1/1 Running; metrics-apiserver 1/1 Running
```

Side-by-side vs local kind:

| Metric | Local kind §0.3 | GKE result |
|---|---:|---:|
| API health | HTTP 200 in 0.0028s | HTTP 200 in 0.140949s via port-forward |
| Catalog count | 415 | 1163 before registering `test/simple_python` |
| DB idle conns | 15 idle, pod-attributed | Not comparable: Cloud SQL + PgBouncer; prompt command unavailable |
| `test/simple_python` | 1.20s cold -> 0.66s warm | 168.613s first repaired run; warm runs 2.51s, 3.995s, 0.979s, 1.052s |
| KEDA | 200 msg -> 4 -> 8 -> 16 -> 20 in ~35s, drain -> 1 over HPA stabilization | Existing backlog -> ACTIVE=True -> 7 -> 8; did not reach 20 during observed window |
| Supercluster | 1+1 local kind, bidirectional | 3+3 GKE, bidirectional gateway mesh confirmed |

## Phase G — write result + open follow-up issues

Opened follow-up handoff:

- `handoffs/active/2026-05-23-gke-playbook-hardening/round-01-prompt.md`

No PRs were merged.

## Issues observed

- The dev playbook remains local-kind centered; it is not yet safe as the canonical GKE deploy path.
- Live GKE cluster is Helm/Cloud SQL shaped, not the requested ops-manifest `deployment/postgres` topology.
- KEDA sample manifest does not match the live Helm NATS service/account shape.
- Worker durable consumer was absent and had to be created manually.
- Existing stranded commands polluted the first regression run and KEDA smoke.
- DB connection footprint could not be compared directly to local kind because PgBouncer/Cloud SQL hides the pod-level client attribution used in §0.3.
- Access logs are still noisy during status polling; this reinforces the logging-hygiene rule for high-frequency health/status paths.

## Manual escalation needed

- Decide whether this GKE validation target should become an ops-manifest stack with in-cluster Postgres, or remain the existing Helm + Cloud SQL/PgBouncer topology.
- Land a GKE-aware deploy path and KEDA overlay before treating this as reproducible from a clean cluster.
- Decide whether to clean up stale Pending PVCs in `noetl` and `postgres`.
- Investigate why the worker did not create `NOETL_COMMANDS/noetl_worker_pool` automatically before manual repair.
