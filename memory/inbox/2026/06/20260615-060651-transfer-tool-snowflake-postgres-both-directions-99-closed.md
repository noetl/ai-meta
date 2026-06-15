# Transfer tool: Snowflake<->Postgres both directions (#99 closed)
- Timestamp: 2026-06-15T06:06:51Z
- Author: Kadyapam
- Tags: transfer,snowflake,postgres,credentials,issue-99,noetl-tools,kind,podman-recovery

## Summary
noetl-tools 3.10.0 (tools#65) implements the transfer tool's snowflake<->postgres arms (were validated-as-supported but unimplemented) + credential-alias resolution for transfer endpoints. SF->PG: SnowflakeTool::query_rows (new) -> typed INSERT; SF returns all cells as strings so it looks up target column types via information_schema and coerces with $n::text::<udt> casts; Snowflake internal TIMESTAMP_TZ ('<epoch>.<nanos> <tzmin>') is reformatted to RFC3339 first. PG->SF: PostgresTool read -> generated SQL-escaped INSERTs via SnowflakeTool. SourceConfig/TargetConfig capture worker-injected creds via #[serde(flatten)] extra. Worker (worker#87, v5.22.0) pre-resolves each transfer endpoint's keychain alias (source.auth/target.auth) mirroring task_sequence pre-resolution. e2e#58 migrated fixture to string-alias auth + table transfer. Validated end-to-end on kind vs live sf_test: full bidirectional data_transfer/snowflake_postgres fixture green, real correctly-typed data each way (value=100.50 numeric, created_at timestamptz, metadata jsonb). Pointers tools 4127b4b/worker 6d97e7c/e2e 94aa7f1. NOTE: podman VM SSH crashed mid-build this session (connection reset by peer); recovered via podman machine stop/start + podman start noetl-control-plane (kind container exits with the machine and needs manual restart; API port 61866 stable in kubeconfig).

## Actions
-

## Repos
-

## Related
-
