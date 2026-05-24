---
thread: 2026-05-24-gke-worker-hpa-conflict
round: 1
from: codex
to: claude
created: 2026-05-24T01:46:18Z
status: open
---

# GKE worker HPA conflict follow-up

## Context

During the noetl `v2.100.5` GKE deploy-and-verify round, the targeted Helm upgrade succeeded and the image fixes verified, but the cluster surfaced an autoscaler configuration conflict.

Cluster:

- Project: `noetl-demo-19700101`
- Cluster: `noetl-cluster`
- Region: `us-central1`
- Namespace: `noetl`
- Helm release: `noetl`

## Evidence from deploy round

The GKE deployment has an external KEDA `ScaledObject` for `noetl-worker`:

- `scaledobject.keda.sh/noetl-worker-scaler-worker-cpu-01`
- target: `Deployment/noetl-worker`
- min/max: `1/20`
- trigger: `nats-jetstream`
- live patches still present:
  - `account=$G`
  - `natsServerMonitoringEndpoint=nats-headless.nats.svc.cluster.local:8222`
  - `stream=NOETL_COMMANDS`
  - `consumer=noetl_worker_pool`

After `helm upgrade --install noetl ./automation/helm/noetl --namespace noetl --reuse-values --set image.tag=v2.100.5`, Helm also rendered the chart CPU HPA:

- `horizontalpodautoscaler.autoscaling/noetl-worker`
- target: `Deployment/noetl-worker`
- min/max: `1/8`
- metric: CPU `70%`

`helm get values noetl -n noetl` showed:

```yaml
worker:
  autoscaling:
    enabled: true
    keda:
      enabled: false
    maxReplicas: 8
    minReplicas: 1
    targetCPUUtilizationPercentage: 70
```

The result is two HPAs managing the same deployment:

- `keda-hpa-noetl-worker-scaler-worker-cpu-01`
- `noetl-worker`

During the deploy smoke, the worker fleet briefly showed many pending pods while desired replicas oscillated.

## Task

Find the narrowest durable fix for the GKE/KEDA deployment profile so only one autoscaler controls `noetl-worker`.

Preferred remediation:

- For the GKE KEDA path, set `worker.autoscaling.enabled=false` when the external KEDA `ScaledObject` is installed.
- Alternatively, update the Helm chart condition so the built-in CPU HPA is not rendered when KEDA is expected to own `noetl-worker` scaling.

## Constraints

- Do not run `noetl_gke_fresh_stack.yaml --set action=provision`.
- Do not recreate infrastructure.
- Do not merge PRs yourself.
- If the fix is only cluster-side Helm values, document the exact `helm upgrade` command and apply only if explicitly authorized by the dispatcher.
- If the fix touches `repos/ops` chart/playbook code, open a PR with a concise summary and stop.

## What to report

Write the result to:

`handoffs/active/2026-05-24-gke-worker-hpa-conflict/round-01-result.md`

Include:

- Current HPA and ScaledObject inventory.
- Root cause.
- Exact proposed remediation.
- Whether the remediation was applied or left for approval.
- Post-change verification if applied.
