# NoETL Distributed Processing Enhancement Plan
- Timestamp: 2026-04-14T17:04:03Z
- Author: Kadyapam
- Tags: noetl,architecture,distributed,fan-out,loop,NATS,MinIO,PVC,schema,enhancement-plan

## Summary
Comprehensive 5-phase plan created (2026-04-14) covering: P0 correctness fixes (atomic command.issued dedup via unique index, atomic loop.done via unique index + ON CONFLICT DO NOTHING, loop state in event table replacing NATS KV as authority, orchestration-level reaper claim expiry); P1 schema enhancements (new loop event types loop.started/item/done/fanout.started/shard.*/fanin.completed, idx_event_loop_id_type for fan-in counting, extended trg_execution_state_upsert trigger maintaining execution.state JSONB for loop/fanout progress, result_ref store_tier extended with minio+pvc); P2 storage (MinIO for kind k8s, PVC/FUSE-mounted volumes for large file exchange, DuckDB reads Parquet directly from PVC); P3 distributed fan-out implementation (spec already in docs/features/distributed_fanout_mode_spec.md, now with implementation plan, fan-in tracking via event table, shard-level retry); P4 NATS bidirectional transport (high-frequency events switch from HTTP POST to NATS JetStream publish, HTTP retained for command.claimed and context fetch, worker capacity heartbeat, targeted dispatch); P5 observability (execution status from projection, call.partial streaming). Docs in repos/docs/docs/features/: noetl_distributed_processing_plan.md, noetl_schema_enhancements.md, noetl_worker_communication.md. Key architectural decisions: no worker-to-worker communication, no WebSocket, server is sole routing authority, noetl.execution is a projection table reconstructable from event replay.

## Actions
-

## Repos
-

## Related
-
