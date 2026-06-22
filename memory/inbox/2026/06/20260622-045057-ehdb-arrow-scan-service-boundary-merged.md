# EHDB Arrow Scan Service Boundary Merged

Date: 2026-06-22

`noetl/ehdb#41` merged as
`51b642f4d8eb60c8971a06f421aa3e6ff8a15374`, closing issue #40.
Wiki documentation was updated at `repos/ehdb-wiki` commit `32cf921`.

The change starts Phase 4 by adding `ehdb-service`, a pre-network
service-facing scan API crate:

- `ScanLatestTableRequest` carries tenant, namespace, table, projection,
  and optional equality predicate inputs;
- `ArrowScanResult` returns Arrow schema, record batches, and row count;
- `LocalArrowScanService` wraps `LocalArrowSnapshotScanner`;
- tests cover full scan schema/row metadata, projection plus filter
  pass-through, missing table errors, and empty result rejection;
- Criterion baseline:
  `local_arrow_scan_service/filter_project_latest_100` at about 12.0 ms.

Validation completed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace` (76 tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- `cargo bench -p ehdb-service --bench local_scan_service`

Boundary note: this is an API shape for future Arrow Flight read paths,
not a network server. It does not add SQL planning, predicate pushdown,
distributed query execution, or gateway direct database access.
