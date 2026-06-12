# #90 Phase 5 shipped — out-of-cluster Cloud Run target + gcs spool backend (live proof green)
- Timestamp: 2026-06-12T06:42:16Z
- Author: Kadyapam
- Tags: noetl,subscription,cloud-run,gcs,spool,pubsub,phase5,issue-90

## Summary
RFC #90 Phase 5: the subscription runtime runs out-of-cluster on Google Cloud Run. tools v3.5.0 GcsBackend (GCS impl of the Phase-4 SpoolBackend trait, ADC+reqwest, no new dep), worker v5.18.0 (gcs spool wiring + optional NOETL_INTERNAL_API_TOKEN bearer + $PORT health bind), server v3.4.2 (gcs/s3 spool credential optional = ADC/Workload Identity), ops automation/cloud-run/ (least-priv SA + bucket + Pub/Sub setup, Cloud Build + deploy + teardown), docs Cloud Run arch page, e2e Pub/Sub+gcs fixture+driver. LIVE on noetl-demo-19700101 (server via cloudflared tunnel to kind): Cloud Run runtime activated over HTTPS, 6/6 Pub/Sub msgs dispatched over HTTPS -> COMPLETED on the subscription pool, a msg buffered to the real GCS bucket under a live outage. NOT auto-triggered: cross-restart GCS drain (in-memory-circuit limitation; drain proven in Phase 4). Finding: real Pub/Sub sync-pull needs timeout_ms>=10s (emulator-only Phase-1 validation) -> tools#57. All test resources torn down, no cost-bearing left. ai-meta a1eb2bd. #90 stays open (Phases 6-7).

## Actions
-

## Repos
-

## Related
-
