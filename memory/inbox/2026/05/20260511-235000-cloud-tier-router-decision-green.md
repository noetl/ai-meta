# Cloud-tier router decision GREEN

Date: 2026-05-11
Status: GREEN_DESIGN_ONLY

Decision: use **GCS as the GKE production cloud spill tier** once bucket IAM is granted to `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`.

Current GKE state:

- `NOETL_DEFAULT_STORAGE_TIER=kv`
- `NOETL_STORAGE_CLOUD_TIER=s3`
- `NOETL_S3_ENDPOINT=http://object-store.object-store.svc.cluster.local:9000`
- `NOETL_GCS_BUCKET=noetl-demo-output`
- Router default cloud tier: `s3`
- `>= 1 MB` results route to `disk`, whose cloud spill target is the configured cloud tier.

The live S3 tier is in-cluster SeaweedFS, not remote AWS S3. That is good for pod-restart durability and local/kind parity, but it is not a cross-cluster disaster-recovery tier.

GCS is configured by env and the bucket exists, but it is not currently usable by the worker. A read-only metadata probe from inside `deploy/noetl-worker` returned `403 storage.buckets.get denied`; project IAM for the worker SA currently shows AI/cluster roles, not storage roles.

Workload evidence:

- `noetl.event` over 7 days: 216,249 total events.
- 8,933 events contained `temp_ref` / `result_ref` markers.
- 8,621 events exposed embedded byte metadata.
- p50 size: 1,123 bytes.
- p95 size: 9,527 bytes.
- max size: 1,249,108 bytes.
- Largest known shape: `amadeus_search_activities`, 9 rows around 1.24 MB.
- Worker disk cache currently has one file around 1.25 MB.

Conclusion: spillover is real but rare and modest. Cost is not the decision driver. The durability boundary is. For production GKE, GCS is the clean durable tier because it lives in the same cloud/project and uses the existing Workload Identity pattern. SeaweedFS remains valuable as the in-cluster object store; remote AWS S3 is unjustified until a real cross-cloud requirement exists.

Implementation is deferred to a separate round: grant bucket-level GCS permissions, flip `NOETL_STORAGE_CLOUD_TIER=gcs`, restart, run a forced large-result durability smoke, and re-run the travel activities regression.
