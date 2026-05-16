# Distributed runtime + event store v2 spec authored
- Timestamp: 2026-05-16T04:56:06Z
- Author: Kadyapam
- Tags: noetl,distributed-runtime,event-store,arrow-ipc,projection,spec,closed

## Summary
Reworked the root-level event-store-design-prompt.md draft as a full distributed runtime spec at repos/docs/docs/features/noetl_distributed_runtime_spec.md (PR noetl/docs#75) and removed the draft from ai-meta (allowed-content rule -- product specs belong in submodules). Spec is anchored on the PFT v2 workload baseline (10 facilities x 1000 patients x ~120k HTTP requests, 26k claim cycles, ~150k command.* events, 3h 54m wall time on local kind GREEN 2026-05-15). Six-phase additive rollout: Phase 0 instrumentation + new noetl.stage and noetl.frame tables; Phase 1 frame-shaped cursor loops (workers claim N=50 row windows instead of single rows, target 10x drop in command-event amplification); Phase 2 noetl-projector StatefulSet running projection out of process behind NATS durable consumer groups; Phase 3 Apache Arrow IPC Tier 1.5 zero-copy data plane between Tier 1 in-process LRU and Tier 2 disk cache, PayloadReference gains optional IpcHint, producer writes RecordBatch to shm + Tier 3, consumer falls back gracefully through the cache hierarchy; Phase 4 unified resource locator + KEDA autoscaling on frame backlog + topology-aware scheduling + NATS supercluster across regions; Phase 5 port/adapter event store (NATS / Kafka / Pub/Sub / Event Hubs / Kinesis) + payload store (S3 / GCS / Azure Blob / SeaweedFS) + projection store (Postgres / DynamoDB / Firestore / Cosmos / Cassandra / ClickHouse / Elasticsearch / vector DBs); Phase 6 stage planner for fanout/reduce, superseding distributed_fanout_mode_spec.md. Document explicitly builds on (does not re-spec) cursor_loop_design, async_sharded_architecture, data_plane_architecture, distributed_processing_plan, distributed_fanout_mode_spec, nats_kv_distributed_cache. Includes per-phase metric targets, a decision-log section explaining what changed vs the original draft (worker-side loop interpretation as the dominant cost reduction, concrete Tier 1.5 GC story, staged additive rollout instead of big-bang abstraction), and source code anchors so implementers can find the existing TempStore tiers / cursor worker / claim API / command reaper without digging.

## Actions
-

## Repos
-

## Related
-
