---
thread: 2026-05-24-gke-worker-hpa-conflict
round: 2
from: codex
to: claude
created: 2026-05-24T03:36:30Z
in_reply_to: round-02-prompt.md
status: complete
---

## Phase A — sync + context

- Confirmed kube context: `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- Synced submodules:
  - `repos/ops`: `4b7fc46 feat(deploy): reset action + retry contract verifier + Ready-pod targeting (#114)`
  - `repos/noetl`: `69d55d40 chore(release): version 2.100.5 [skip ci]`
- Pre-change Helm state:
  - Release `noetl`, namespace `noetl`, revision `153`, status `deployed`.
- Pre-change HPA inventory:

```text
NAME                                         REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-noetl-worker-scaler-worker-cpu-01   Deployment/noetl-worker   0/10 (avg)    1         20        1          5h46m
noetl-worker                                 Deployment/noetl-worker   cpu: 0%/70%   1         8         1          113m
```

- Pre-change worker deployment state: `replicas=1 ready=1`.
- Pre-change Helm values showed `worker.autoscaling.enabled: true` and `worker.autoscaling.keda.enabled: false`.

## Phase B — apply cluster-side fix

- Applied the pre-authorized targeted Helm change:

```bash
helm upgrade --install noetl ./automation/helm/noetl \
  --namespace noetl \
  --reuse-values \
  --set worker.autoscaling.enabled=false
```

- Helm advanced to revision `154`.
- Rollout checks completed:
  - `deployment "noetl-server" successfully rolled out`
  - `deployment "noetl-worker" successfully rolled out`
- Helm pruned the chart-rendered `noetl-worker` CPU HPA; no manual `kubectl delete hpa noetl-worker` was needed.
- Post-change HPA inventory:

```text
NAME                                         REFERENCE                 TARGETS      MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-noetl-worker-scaler-worker-cpu-01   Deployment/noetl-worker   0/10 (avg)   1         20        1          5h48m
```

- Post-change worker deployment state: `replicas=1 ready=1`.
- Post-change worker pod inventory:

```text
NAME                            READY   STATUS    RESTARTS   AGE
noetl-worker-7f486678d5-w9pqt   1/1     Running   0          113m
```

- Post-change Helm values now show `worker.autoscaling.enabled: false`.

## Phase C — durable fix as ops PR

- Created ops branch `kadyapam/gke-playbook-disable-cpu-hpa-default`.
- Changed `automation/gcp_gke/noetl_gke_fresh_stack.yaml`:
  - `noetl_worker_autoscaling_enabled: true` -> `false`.
  - Added a comment explaining that the GKE profile uses the external KEDA `ScaledObject` from `ci/manifests/keda/scaledobject-worker-cpu-01.yaml`, and that the chart CPU HPA conflicts when both own the same Deployment.
  - Updated the connection-budget comment so it no longer describes the chart CPU HPA as the default GKE worker scaling path.
- Ops commit: `79087d2 fix(gke): default noetl_worker_autoscaling_enabled=false (use external KEDA)`.
- Opened PR: https://github.com/noetl/ops/pull/115
- PR state: `OPEN`.
- PR was not merged.

## Issues observed

- No new runtime issues observed after the cluster-side Helm patch.
- The round-1 diagnosis needed correction as stated in the round-2 prompt: the chart guard is correct; the GKE playbook default was the bug.

## Manual escalation needed

- Review and merge https://github.com/noetl/ops/pull/115 when ready.
- After merge, future GKE provision/deploy runs should inherit `noetl_worker_autoscaling_enabled: false` unless explicitly overridden.
