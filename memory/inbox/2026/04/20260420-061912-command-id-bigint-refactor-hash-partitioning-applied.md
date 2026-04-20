# command_id BIGINT refactor + hash partitioning applied
- Timestamp: 2026-04-20T06:19:12Z
- Author: Kadyapam
- Tags: noetl,schema,command-id,bigint,partitioning,phase-1

## Summary
Refactored noetl.command.command_id (and noetl.event.command_id, noetl.command.parent_command_id) from TEXT to BIGINT to align with execution_id and event_id which are already snowflake bigints. Plain int is smaller, comparable in O(1), faster index, cleaner over the wire. Mint sites in server/api/core/{execution.py,events.py,batch.py} now write the bare snowflake int (no str() wrap) instead of the obsolete composed format <execution_id>:<step>:<seq>. Extractors in server/api/core/events.py and core/dsl/engine/executor/common.py accept both int and numeric str (back-compat for in-flight legacy payloads). Schema_ddl.sql + scripts/db/migrate_command_to_hash_partitioned.sql updated to BIGINT. Hash partitioning (16 partitions on execution_id) applied separately in commit a6477b62 — partition column unchanged. Worker step extractor at nats_worker.py:1347 uses .split(':')[1] which now degrades to 'unknown' (server has authoritative step in noetl.command anyway). PRIMARY KEY of noetl.command is composite (execution_id, command_id) per Postgres partitioned-UNIQUE rule. ON CONFLICT in 3 inserts changed to (execution_id, command_id) DO NOTHING. Live cluster migrated via TRUNCATE + ALTER COLUMN TYPE BIGINT USING NULL (existing rows had obsolete composed strings that can't cast). Image localhost/local/noetl:2026-04-19-23-15 deployed; pending rollout + fresh PFT validation.

## Actions
-

## Repos
-

## Related
-
