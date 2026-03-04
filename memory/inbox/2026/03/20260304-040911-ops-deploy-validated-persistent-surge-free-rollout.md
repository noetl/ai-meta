# ops deploy validated persistent surge-free rollout
- Timestamp: 2026-03-04T04:09:11Z
- Tags: ops,gke,deploy,validation,rollout

## Summary
Executed ops GKE deploy playbook with published noetl image v2.8.9 and build_images=false; deployment succeeded and live deployment strategies remained maxSurge=0,maxUnavailable=1 for both noetl-server and noetl-worker.

## Actions
- Ran deploy command from `ops`:
  - `noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml --runtime local --set action=deploy --set project_id=noetl-demo-19700101 --set region=us-central1 --set cluster_name=noetl-cluster --set build_images=false --set noetl_image_repository=ghcr.io/noetl/noetl --set noetl_image_tag=v2.8.9 --set deploy_ingress=false --set gateway_service_type=LoadBalancer --set gateway_load_balancer_ip=34.46.180.136 --set gui_service_type=LoadBalancer --set gui_load_balancer_ip=35.226.162.30 --set pgbouncer_default_pool_size=4 --set pgbouncer_min_pool_size=1 --set pgbouncer_reserve_pool_size=1 --set pgbouncer_max_db_connections=8 --set pgbouncer_server_idle_timeout=120 --set bootstrap_gateway_auth=false`
- Playbook outcome:
  - NoETL/Gateway/GUI deploy steps completed successfully.
  - Cloud SQL + PgBouncer path remained active.
- Verified persistent rollout strategy in cluster:
  - `kubectl -n noetl get deploy noetl-server noetl-worker -o jsonpath='{...}'`
  - `noetl-server maxSurge=0 maxUnavailable=1`
  - `noetl-worker maxSurge=0 maxUnavailable=1`
- Final pod state:
  - all `noetl-server`/`noetl-worker` pods Running.

## Repos
- noetl/ai-meta: memory update only
