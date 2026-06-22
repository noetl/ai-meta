# EHDB Arrow Flight Scan Info Fixture Merged

Date: 2026-06-22

`noetl/ehdb#47` merged as
`8ef14058816cb1dd96ee7253d3877aa28246bb66`, closing issue #46.
Wiki documentation was updated at `repos/ehdb-wiki` commit `fcf6779`.

The change adds the local discovery metadata side of the Phase 4 Flight
contract:

- `ArrowScanResult::to_flight_info` builds pre-network `FlightInfo`
  metadata from a `ScanFlightTicket` and local scan result;
- the fixture includes schema IPC bytes, a command descriptor, one
  ordered endpoint ticket, total records, and encoded FlightData byte
  count;
- endpoint tickets round-trip through `ScanFlightTicket`;
- FlightInfo totals are checked against the decodable FlightData result
  stream.

Validation completed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace` (88 tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary note: this is a pre-network metadata fixture. It does not add a
Flight server/client, SQL planning, predicate pushdown, distributed query
execution, or gateway direct database access.
