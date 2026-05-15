# minio local provisioning and storage guidance integration
- Timestamp: 2026-04-19T17:34:00Z
- Author: Kadyapam
- Tags: ops,minio,s3,storage,bootstrap

## Summary
Provisioned MinIO in repos/ops for local S3-compatible storage. Updated kind config with port mappings (9000/9001) and cache mount. Added minio namespace, deployment, and service manifests. Created minio.yaml infrastructure playbook and integrated it into bootstrap.yaml and destroy.yaml workflows. Updated noetl-worker and noetl-server ConfigMaps with S3_ENDPOINT_URL and credentials to support payloads > 1MB via S3 backend. Pushed to repos/ops origin/fix/bootstrap-postgres-external-service.

## Actions
-

## Repos
-

## Related
-
