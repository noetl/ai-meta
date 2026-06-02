# Observability + snowflake IDs standing guidance
- Timestamp: 2026-05-31T03:21:27Z
- Author: Kadyapam
- Tags: observability snowflake-ids metrics traceability execution-id rules-update

## Summary
User directive 2026-05-30: (1) embed traceability + observability everywhere - every substantive PR ships a span, at least one metric, and execution_id correlation; (2) metrics-not-logs - counters / histograms / gauges over INFO-line floods; instrument boundaries first (gateway/server, server/NATS, NATS/worker, worker/tool, tool/external); (3) snowflake IDs generated application-side, not via DB functions - lets spans/metrics use the id before the row hits DB, enables retry idempotency, deterministic test fixtures, sharded deployments. Codified in agents/rules/observability.md with 4 principles + per-component guidance + integration with logging.md / execution-model.md / deployment-validation.md / wiki-maintenance.md. The DB-side gen_snowflake() function stays as fallback for out-of-band admin SQL but application code always supplies IDs explicitly. Per-component migration order: (1) app generates ID via snowflake helper, (2) span/metric uses it immediately, (3) INSERT passes it explicitly, (4) optionally drop DB default later. Rust binaries use snowflaked or sonyflake crate; Python uses noetl.core.ids.snowflake helper. machine_id derived from WORKER_ID env var (server/worker pods), hostname+pid hash (CLI), pod name hash (gateway). Epoch fixed at 2024-01-01T00:00:00Z. execution_id rides every wire format - HTTP path/query (not just body), NATS header (not just body), tracing span field, structured log field on WARN/ERROR. NOT a Prometheus label (cardinality).

## Actions
-

## Repos
-

## Related
-
