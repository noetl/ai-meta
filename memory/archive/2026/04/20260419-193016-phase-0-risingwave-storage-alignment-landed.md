# phase-0 RisingWave storage alignment landed
- Timestamp: 2026-04-19T19:30:16Z
- Author: Kadyapam
- Tags: noetl,docs,storage,tempstore,risingwave,phase-0,disk-cache

## Summary
Landed phase 0 of RisingWave alignment in repos/noetl (feat/storage-rw-alignment-phase-0 @ 58947ab2) and repos/docs (main @ 9320567). Removed experimental NATS Object Store tier from TempStore; reserved StoreTier.DISK with NotImplementedError placeholder backend; rewrote router so <1MB->KV and >=1MB->DISK (phase 0 spills directly to NOETL_STORAGE_CLOUD_TIER=s3|gcs). Back-compat shim auto-remaps store='object' -> 'disk' with one-time warn. Added reserved env vars for phase 1 disk cache (NOETL_STORAGE_LOCAL_CACHE_* + NOETL_STORAGE_CLOUD_TIER + NOETL_S3_ENDPOINT). Design doc at docs/features/noetl_storage_and_streaming_alignment.md anchors phases 1-3 (disk cache backend; Source/Table/MV/Sink DSL primitives; barrier+compactor). Import tests + functional assertions pass; existing 11 doc files refreshed.

## Actions
-

## Repos
-

## Related
-
