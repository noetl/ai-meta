# GKE paginated-api HPA

Date: 2026-05-14

Context:
- The `test-server/paginated-api` deployment in GKE was running 8 pods continuously.
- The desired operating mode is a low idle baseline with burst capacity for tests: scale down to 1 pod and autoscale up to 8.

Change:
- `repos/ops` PR #91 updated `automation/gcp_gke/test-server/deployment.yaml`.
- Deployment baseline changed from `replicas: 8` to `replicas: 1`.
- Added `autoscaling/v2` HorizontalPodAutoscaler:
  - `minReplicas: 1`
  - `maxReplicas: 8`
  - CPU target: 70% utilization
- Added explicit container resource requests (`cpu: 500m`, `memory: 2Gi`) so the CPU utilization target is stable.

Live GKE:
- Applied the manifest to GKE immediately.
- Deployment rolled out successfully.
- `paginated-api` is now `1/1` ready.
- HPA is active and reports `min 1 / max 8`, current replicas `1`.
- In-cluster health smoke returned `{"status":"ok"}` from `http://paginated-api:5555/health`.

Follow-up:
- If load tests need a different scale trigger, tune the HPA target or add custom metrics later. The current setting is intentionally simple and cost-reducing.
