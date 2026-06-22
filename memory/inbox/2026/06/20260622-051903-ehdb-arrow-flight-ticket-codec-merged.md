# EHDB Arrow Flight Scan Ticket Codec Merged

Date: 2026-06-22

`noetl/ehdb#43` merged as
`63737eb5786c849c876eae83a1edede393034672`, closing issue #42.
Wiki documentation was updated at `repos/ehdb-wiki` commit `e39776b`.

The change adds the first Arrow Flight request contract for Phase 4:

- `ScanFlightTicket` wraps latest-table scan requests in versioned bytes;
- scan requests now preserve tenant, namespace, table, projection, and
  equality predicate fields through serde;
- request payloads round-trip through Arrow Flight `Ticket`;
- command `FlightDescriptor` values can be produced for future Flight
  read APIs;
- unsupported versions and malformed payloads fail before execution;
- decoded tickets can feed `LocalArrowScanService` for local scans.

Validation completed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace` (82 tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary note: this is a Flight contract fixture only. It does not add a
network Flight server/client, SQL planning, predicate pushdown,
distributed query execution, or gateway direct database access.
