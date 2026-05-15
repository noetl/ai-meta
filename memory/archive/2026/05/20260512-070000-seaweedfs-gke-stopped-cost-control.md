# SeaweedFS object store on GKE stopped for cost control

Date: 2026-05-12
Status: GREEN

The GKE in-cluster SeaweedFS object-store pod was intentionally stopped after the cloud spill tier moved to GCS.

Why this is safe:

- GKE NoETL now uses `NOETL_STORAGE_CLOUD_TIER=gcs`.
- The active GCS bucket is `noetl-demo-output`.
- SeaweedFS is retained as an in-cluster S3-compatible rollback/direct-caller option, but it is not the active cloud spill path.

What changed:

- Merged `noetl/ops#77`, adding `objectStore.replicas` with default `1`.
- Wired `objectStore.replicas` into both SeaweedFS and RustFS Deployment templates.
- Applied Helm release `noetl` revision `131` with `objectStore.enabled=true`, `objectStore.kind=seaweedfs`, and `objectStore.replicas=0`.
- Kept `service/object-store` and PVC `object-store-data` in place.
- ai-meta now points `repos/ops` at `e016d973ef3aa51c94b80975f546f3f5b7a25a5c`.

Verified state:

- `deployment.apps/seaweedfs` is `0/0`.
- No pods match `app=seaweedfs`.
- `service/object-store` remains present in namespace `object-store`.
- `persistentvolumeclaim/object-store-data` remains `Bound` at 50Gi.
- `NOETL_STORAGE_CLOUD_TIER=gcs` remains configured for the worker.

Re-provisioning runbook:

```bash
cd /Volumes/X10/projects/noetl/ai-meta/repos/ops

helm upgrade noetl automation/helm/noetl \
  --namespace noetl \
  --kube-context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  --reuse-values \
  --set objectStore.enabled=true \
  --set objectStore.kind=seaweedfs \
  --set objectStore.replicas=1

kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n object-store rollout status deployment/seaweedfs --timeout=300s
```

If NoETL cloud spillover should use in-cluster S3 again, also set `NOETL_STORAGE_CLOUD_TIER=s3` for worker/server through Helm and restart `deployment/noetl-worker` plus `deployment/noetl-server`.

To stop SeaweedFS again after a test window, run the same Helm command with `--set objectStore.replicas=0`.
