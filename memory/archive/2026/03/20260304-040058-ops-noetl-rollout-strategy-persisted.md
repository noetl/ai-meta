# ops noetl rollout strategy persisted
- Timestamp: 2026-03-04T04:00:58Z
- Tags: ops,gke,rollout,strategy,autopilot

## Summary
Persisted noetl server/worker rollout strategy in ops chart+gke playbook to avoid surge-related Pending pods on constrained Autopilot nodes; defaults now deploy maxSurge=0,maxUnavailable=1 via gke playbook overrides.

## Actions
- Added deployment strategy support to NoETL Helm chart:
  - `automation/helm/noetl/templates/server-deployment.yaml`
  - `automation/helm/noetl/templates/worker-deployment.yaml`
  - `automation/helm/noetl/templates/worker-pool-deployment.yaml`
  - `automation/helm/noetl/values.yaml`
- Added GKE playbook defaults/overrides for surge-free rollout:
  - `noetl_server_rollout_max_surge=0`
  - `noetl_server_rollout_max_unavailable=1`
  - `noetl_worker_rollout_max_surge=0`
  - `noetl_worker_rollout_max_unavailable=1`
  - wired into Helm `deploy_noetl` command in `automation/gcp_gke/noetl_gke_fresh_stack.yaml`
- Updated `automation/gcp_gke/README.md` to document rollout defaults.
- Validation:
  - YAML parse passed for updated values/playbook.
  - `helm template` render shows strategy fields and resolves to `maxSurge: 0` / `maxUnavailable: 1` when overrides are provided.

## Repos
- noetl/ops: `main` -> `b36bbb2`
- noetl/ai-meta: submodule pointer bump pending commit
