# gke pending rollout mitigated via strategy patch
- Timestamp: 2026-03-04T03:50:03Z
- Tags: gke,rollout,pending,autoscaler,ops

## Summary
Pending noetl-server/noetl-worker pods were caused by autoscaler scale-up failures and low-memory scheduling pressure during RollingUpdate surge. Applied live deployment strategy patch maxSurge=0,maxUnavailable=1 on both deployments; rollout completed and all noetl pods are running.

## Actions
- Confirmed kube context: `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- Diagnosed pending pods:
  - `noetl-server-564c589b7b-8l4xd`
  - `noetl-worker-5674c67c45-8d9fh`
- Scheduler/autoscaler events indicated:
  - `Insufficient memory`
  - `Too many pods`
  - `FailedScaleUp ... GCE quota exceeded` (autoscaler backoff)
- Applied live mitigation:
  - `kubectl -n noetl patch deploy noetl-server --type merge -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'`
  - `kubectl -n noetl patch deploy noetl-worker --type merge -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'`
- Verified rollout completion:
  - `kubectl -n noetl rollout status deploy/noetl-server`
  - `kubectl -n noetl rollout status deploy/noetl-worker`
- Final pod status:
  - `noetl-server-564c589b7b-8l4xd` Running
  - `noetl-worker-5674c67c45-8d9fh` Running
  - `noetl-worker-5674c67c45-zckc7` Running

## Repos
- noetl/ai-meta: memory update only
