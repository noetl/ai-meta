# phase-1 DiskCacheBackend landed with two-pool split and cloud spill
- Timestamp: 2026-04-20T01:59:55Z
- Author: Kadyapam
- Tags: noetl,storage,tempstore,risingwave,phase-1,disk-cache,backend

## Summary
Shipped phase-1 disk cache backend on feat/storage-rw-alignment-phase-1 @ ac03db45. DiskCacheBackend implements RisingWave-aligned two-pool architecture: _DiskCachePool (LRU, OrderedDict index, atomic fsync+rename writes, capacity-bounded eviction) composed into meta pool (~10%, <10KB entries) + data pool (~90%, >=10KB entries). Shared _TokenBucket rate limiter enforces NOETL_STORAGE_LOCAL_CACHE_INSERT_RATE_MB. Warm-start via recover_mode=Quiet re-indexes on-disk files by sha256 filename at first use. Async cloud spill via asyncio.create_task uploads to NOETL_STORAGE_CLOUD_TIER (S3/MinIO/GCS). Read path: memory->data pool->meta pool->cloud read-through with local re-populate. result_store.py DISK branches now call backend.put/get/delete directly (previous phase-0 cloud fallthrough removed); hard failure still falls back to cloud for durability. 12 unit tests all green, covering put/get roundtrip, pool routing, LRU eviction, cloud read-through, async spill, warm-start reindex, rate-limit throttle, atomic write cleanup. Remaining follow-up (not in this commit): Helm values + ConfigMap env wiring + PVC mount guidance for kind and GKE.

## Actions
-

## Repos
-

## Related
-
