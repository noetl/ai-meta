# phase-1 validation: end-to-end disk + MinIO spill green
- Timestamp: 2026-04-20T02:37:11Z
- Author: Kadyapam
- Tags: noetl,storage,disk-cache,minio,phase-1,validation,podman,kind

## Summary
Validated phase-1 DiskCacheBackend end-to-end on podman-kind cluster with new image localhost/local/noetl:2026-04-19-19-33 (built from feat/storage-rw-alignment-phase-1 @ 3127f022). Stack: in-cluster MinIO at minio.minio.svc.cluster.local:9000 (bucket noetl-results), worker ConfigMap exposes NOETL_STORAGE_CLOUD_TIER=s3, NOETL_S3_ENDPOINT, NOETL_STORAGE_LOCAL_CACHE_DIR=/opt/noetl/data/disk_cache, data pool 2GB / meta pool 256MB / insert rate 200 MB/s / recover_mode=Quiet, MinIO creds from configmap (minioadmin). Validation execution test_storage_tiers (608890336932266112): 192K written to local disk cache /opt/noetl/data/disk_cache/data on worker, 2 objects (92 KiB total) spilled to MinIO via aioboto3 within seconds — test_disk 23 KiB and test_large_storage 69 KiB matching the disk:// URI hash. Caught + fixed during validation: (1) phase-0 schema migration applied to local postgres to add command_id column to noetl.event (run as demo owner, not noetl); (2) aioboto3 missing from pyproject deps surfaced as 'aioboto3 not installed' warning during cloud spill — added aioboto3>=13.0.0 to pyproject.toml + uv lock + rebuilt image (commit 3127f022). PFT smoke run (608879114543432644) on prior image was clean (4541 events / 798 commands completed in 2 min, 0 actual failures) but did not exercise disk tier because per-batch payloads stay under the 1MB KV threshold.

## Actions
-

## Repos
-

## Related
-
