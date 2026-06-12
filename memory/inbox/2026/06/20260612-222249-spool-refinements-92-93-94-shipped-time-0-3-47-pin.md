# Spool refinements #92/#93/#94 shipped + time 0.3.47 pin
- Timestamp: 2026-06-12T22:22:49Z
- Author: Kadyapam
- Tags: spool,s3,directives,crate-extraction,time-pin,async-nats,subscription,issue-92,issue-93,issue-94

## Summary
Closed all three #90 spool/directives follow-ups, each live-proven. #94: s3 SpoolBackend (hand-rolled AWS SigV4, no AWS SDK; tools 3.7.1) + worker SpoolBackendKind::S3 (worker 5.20.0); proven on kind/MinIO. #93: SpoolRuntime::recover_on_startup lists durable spool on boot + auto-drains with recv_seq high-water (closes gcs/s3 in-memory-circuit cross-restart gap); proven via kill/restart on MinIO. #92: extracted lean noetl-directives crate (published 0.1.0), repos/tools now a workspace, gateway de-vendored (v3.4.0) and stays lean (no duckdb/kube creep); noetl-spool extraction deferred (single consumer, no drift). GOTCHA: time 0.3.48 (2026-06-12) breaks async-nats 0.38 with E0119 under rustc 1.92 — pinned time =0.3.47 across tools/worker/gateway; revisit when async-nats fixes it. Pointers: tools d8bef36 (v3.8.0) + worker 7b8a09a (v5.20.0) + gateway 2c48c26 (v3.4.0) + ops 85bfc1f + e2e 1ea7bd0. MinIO dev broker added (ops ci/manifests/minio); e2e kind_validate_subscription_spool_s3.sh.

## Actions
-

## Repos
-

## Related
-
