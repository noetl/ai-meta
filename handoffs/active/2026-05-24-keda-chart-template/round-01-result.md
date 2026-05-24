---
thread: 2026-05-24-keda-chart-template
round: 1
from: codex
to: claude
created: 2026-05-24T04:50:19Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — sync + context snapshot

- Confirmed kube context: `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- Synced submodules:
  - `repos/ops`: `8eff0fb fix(gke): default noetl_worker_autoscaling_enabled=false (use external KEDA) (#115)`
  - `repos/noetl`: `69d55d40 chore(release): version 2.100.5 [skip ci]`
- Pre-change Helm state:

```text
NAME  NAMESPACE  REVISION  UPDATED                              STATUS    CHART       APP VERSION
noetl noetl      154       2026-05-23 20:34:43.524056 -0700 PDT deployed  noetl-0.1.0 0.0.0
```

- Pre-change autoscaling inventory:

```text
NAME                                                     SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   TRIGGERS         AUTHENTICATION   READY   ACTIVE   FALLBACK   PAUSED    AGE
scaledobject.keda.sh/noetl-worker-scaler-worker-cpu-01   apps/v1.Deployment   noetl-worker      1     20    nats-jetstream                    True    True     False      Unknown   6h58m

NAME                                                                             REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/keda-hpa-noetl-worker-scaler-worker-cpu-01   Deployment/noetl-worker   12/10 (avg)   1         20        1          6h58m
```

- Pre-change worker deployment state: `replicas=2 ready=1`.
- Verified `worker-hpa.yaml` still has the mutually exclusive guard:

```text
1:{{- if and .Values.worker.autoscaling.enabled (not .Values.worker.autoscaling.keda.enabled) }}
```

## Phase B — chart + values + playbook edits

- Created ops branch `kadyapam/keda-chart-template-natsjetstream`.
- Rewrote `automation/helm/noetl/templates/worker-keda-scaledobject.yaml` from Prometheus to NATS JetStream.
- Updated `automation/helm/noetl/values.yaml`:
  - removed Prometheus KEDA keys;
  - added `worker.autoscaling.keda.nats.*`;
  - set KEDA defaults to `$G`, `nats-headless.nats.svc.cluster.local:8222`, `NOETL_COMMANDS`, `noetl_worker_pool`;
  - bumped `worker.autoscaling.maxReplicas` from `8` to `20`.
- Updated `automation/gcp_gke/noetl_gke_fresh_stack.yaml`:
  - set `noetl_worker_autoscaling_enabled: true`;
  - added `noetl_worker_autoscaling_keda_enabled: true`;
  - passed `worker.autoscaling.keda.enabled` through the Helm upgrade command;
  - updated comments to describe chart-rendered KEDA ownership.
- Did not modify `ci/manifests/keda/scaledobject-worker-cpu-01.yaml`.
- Did not modify `automation/helm/noetl/templates/worker-hpa.yaml`.
- Render check:

```text
kind: ScaledObject
metadata:
  name: noetl-worker
  namespace: noetl
  labels:
    app: noetl-worker
    component: worker
    managed-by: helm
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: noetl-worker
  pollingInterval: 10
  cooldownPeriod: 30
  minReplicaCount: 1
  maxReplicaCount: 20
  triggers:
    - type: nats-jetstream
      metadata:
        natsServerMonitoringEndpoint: "nats-headless.nats.svc.cluster.local:8222"
        account: "$G"
        stream: "NOETL_COMMANDS"
        consumer: "noetl_worker_pool"
        lagThreshold: "10"
        activationLagThreshold: "1"
        useHttps: "false"
```

- The same render stream had no `kind: HorizontalPodAutoscaler`; the chart CPU HPA was suppressed by `worker.autoscaling.keda.enabled=true`.
- Ops commit: `c1a3582 feat(helm): KEDA NATS-JetStream ScaledObject as chart artifact (GKE Option A)`.

## Phase C — cluster migration

- First literal Helm attempt with only the prompt's two `--set` flags failed because the live release's reused values did not yet contain the new `worker.autoscaling.keda.nats` map:

```text
Error: UPGRADE FAILED: noetl/templates/worker-keda-scaledobject.yaml:23:48
  executing "noetl/templates/worker-keda-scaledobject.yaml" at <.Values.worker.autoscaling.keda.nats.monitoringEndpoint>:
    nil pointer evaluating interface {}.monitoringEndpoint
```

- Retried with the new NATS KEDA values explicitly set, but KEDA rejected the chart ScaledObject while the external ScaledObject still owned the same Deployment:

```text
admission webhook "vscaledobject.kb.io" denied the request: the workload 'noetl-worker' of type 'apps/v1.Deployment' is already managed by the ScaledObject 'noetl-worker-scaler-worker-cpu-01'
```

- Because deletion of the external `noetl-worker-scaler-worker-cpu-01` ScaledObject was pre-authorized, I deleted it first. After deletion, `kubectl get scaledobject,hpa -n noetl` returned `No resources found in noetl namespace.`
- Re-ran Helm from the local branch checkout with `--reuse-values`, the two KEDA enable flags, and the new KEDA NATS values explicitly set. Helm succeeded and advanced the release to revision `156`.
- Rollouts:
  - `deployment "noetl-server" successfully rolled out`
  - `deployment "noetl-worker" successfully rolled out`
- Post-migration autoscaling inventory:

```text
NAME                                SCALETARGETKIND      SCALETARGETNAME   MIN   MAX   TRIGGERS         AUTHENTICATION   READY   ACTIVE   FALLBACK   PAUSED    AGE
scaledobject.keda.sh/noetl-worker   apps/v1.Deployment   noetl-worker      1     20    nats-jetstream                    True    True     False      Unknown   106s

NAME                                                        REFERENCE                 TARGETS      MINPODS   MAXPODS   REPLICAS   AGE
horizontalpodautoscaler.autoscaling/keda-hpa-noetl-worker   Deployment/noetl-worker   3/10 (avg)   1         20        2          106s
```

- New ScaledObject metadata check:

```text
maxReplicaCount: 20
minReplicaCount: 1
account: $G
consumer: noetl_worker_pool
lagThreshold: "10"
natsServerMonitoringEndpoint: nats-headless.nats.svc.cluster.local:8222
stream: NOETL_COMMANDS
type: nats-jetstream
```

- Post-migration worker state:

```text
replicas=2 ready=2
NAME                            READY   STATUS    RESTARTS   AGE
noetl-worker-7f486678d5-g7445   1/1     Running   0          75s
noetl-worker-7f486678d5-w9pqt   1/1     Running   0          3h7m
```

- Smoke run completed:

```json
{"execution_id": "633599564905185763", "duration_s": 5.317, "completed": true, "failed": false, "current_step": "end"}
```

## Phase D — open ops PR

- Pushed branch `kadyapam/keda-chart-template-natsjetstream`.
- Opened PR: https://github.com/noetl/ops/pull/116
- PR state: `OPEN`.
- PR was not merged.

## Issues observed

- `helm upgrade --reuse-values` does not automatically merge newly added chart default keys into the live release values. The first Helm attempt therefore failed on the new `worker.autoscaling.keda.nats.*` path. The successful migration explicitly set the new NATS KEDA values.
- KEDA's admission webhook requires deleting the existing ScaledObject before creating another ScaledObject for the same target Deployment. The migration order had to be adjusted from the prompt's order: delete the external ScaledObject first, then create the chart-rendered ScaledObject via Helm.
- The chart template itself passed local rendering and live validation after these migration-order/value issues were handled.

## Manual escalation needed

- Review and merge https://github.com/noetl/ops/pull/116 when ready.
- Future chart migrations that add new values under `--reuse-values` should either pass the new values explicitly, use a reset/merge strategy, or make templates defensive around missing nested maps.
