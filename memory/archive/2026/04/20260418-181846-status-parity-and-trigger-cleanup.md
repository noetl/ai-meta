# status parity and trigger cleanup
- Timestamp: 2026-04-18T18:18:46Z
- Author: Kadyapam
- Tags: noetl,cli,api,postgres,trigger,status,ddl,recovery,pft

## Summary
Cluster recovery succeeded after Postgres WAL repair and a noetl-server rollout on `docker.io/library/noetl:arm64-e6f4b5fb`. During recovery, schema re-application recreated the legacy `trg_execution_state_upsert` trigger, which reintroduced execution-table contention: statement timeouts on upserts, tuple locking, stuck `command.issued` rows, and batch processor deadlock. The live mitigation was to drop the trigger and restart the server; a fresh PFT run then resumed normal throughput. Follow-on code fixes were applied in `repos/noetl` and `repos/cli`: remove the legacy execution trigger from schema/migration DDL, make `/api/executions/{id}/status` treat `command.failed` as terminal and emit terminal duration/end_time, and harden CLI `noetl status` rendering/fallback so failed or cancelled runs are not mislabeled as RUNNING when `/status` drifts.

## Actions
- Captured root cause: trigger recreation after recovery/bootstrap, not an orchestration engine bottleneck.
- Patched `repos/noetl/noetl/database/ddl/postgres/schema_ddl.sql` and `repos/noetl/scripts/db/migrate_execution_table.sql` to drop `trg_event_to_execution` / `noetl.trg_execution_state_upsert()` instead of recreating them.
- Patched `repos/noetl/noetl/server/api/core/execution.py` to include `command.failed` in terminal-event detection for `/status`.
- Patched `repos/noetl/noetl/server/api/core/utils.py` so terminal failed executions keep `end_time` and bounded duration instead of continuing to look live.
- Added targeted parity tests for `/status` terminal `command.failed` handling in `repos/noetl/tests/api/execution/test_status_endpoint_parity.py`.
- Patched `repos/cli/src/main.rs` so `failed=true` renders `FAILED`, `CANCELLED` stays cancelled, and CLI cross-checks `/api/executions/{id}` when `/status` returns stale non-terminal data.

## Repos
- `repos/noetl`
- `repos/cli`

## Related
- Old execution with mismatch: `607458339856843442` (`/api/executions/{id}` = FAILED while CLI status looked RUNNING-style)
- Clean rerun after trigger removal: `607888713783181353`
- Fast post-trigger-removal run observed: `607902581309833726`
