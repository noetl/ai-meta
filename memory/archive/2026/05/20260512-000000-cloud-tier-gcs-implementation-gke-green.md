# GKE cloud spill tier switched to GCS

Date: 2026-05-12
Status: GREEN

Round D's recommendation was implemented on GKE.

ops#73 merged `d866c53c8a40289c32118ab3963c4021b91e7c98`, setting `NOETL_STORAGE_CLOUD_TIER=gcs` in the Helm values and CI configmaps while keeping the S3/SeaweedFS env available for direct callers and rollback.

GKE rollout:

- Helm release `noetl` revision `127`
- `noetl-worker`: `2/2` ready on `ghcr.io/noetl/noetl:v2.37.8`
- `noetl-server`: `1/1` ready on `ghcr.io/noetl/noetl:v2.37.8`
- Worker env: `NOETL_STORAGE_CLOUD_TIER=gcs`
- Router introspection: `Router.default_cloud_tier=gcs`, `ResultHandler.default_tier=kv`, `select_2mb_auto=disk`

IAM nuance:

- Bucket-level `roles/storage.objectAdmin` is present for `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`.
- `bucket.exists()` still returns `403 storage.buckets.get denied`, because objectAdmin does not grant bucket metadata read.
- The actual NoETL GCSBackend operations passed from inside the worker: upload, blob exists, download, and delete.

Durability proof:

- Wrote `gs://noetl-demo-output/results/_noetl_gcs_durability_probe.txt`.
- Restarted `deployment/noetl-worker`.
- Re-read the object from the new worker pod.
- ETag, generation, content, and SHA-256 matched.
- Probe object was deleted after verification.

Travel smoke:

- Execution `624862041857065895`
- Query: `activities near Times Square`
- Completed at `render_activities` with `app:column`.
- GCS contains the Amadeus MCP spill object:
  `gs://noetl-demo-output/results/execution_624862076334244851_result_amadeus_search_activities_57a3e6e4`

Synthetic GCS path:

- Direct `StoreTier.GCS` put/resolve from inside the worker returned `store=gcs` and `resolved_match=true`.
- Synthetic object was cleaned up after verification.

Deferred: optionally grant a narrow `storage.buckets.get` permission if future health checks must use `bucket.exists()`. The runtime path does not require it today.
