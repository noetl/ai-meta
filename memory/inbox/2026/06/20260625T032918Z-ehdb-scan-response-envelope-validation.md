# EHDB scan response envelope validation

Date: 2026-06-25 UTC

Repository state:

- `noetl/ehdb#177` merged to `main` as
  `c6a7ca8822ba7cc61296393505d0d2260742a2e0`.
- Closed issue:
  [#176 Validate Arrow Flight scan response envelope](https://github.com/noetl/ehdb/issues/176).
- Wiki updated as `ef3fbe56ff6c89fa6bf494473c0a5cc9c44c2998`.

Summary:

- Added
  `ArrowScanResult::from_flight_data_for_schema_result_info_and_ticket`
  for the complete receiver-side scan response envelope: raw
  `SchemaResult`, returned scan `FlightInfo`, raw `FlightData`, and
  expected `ScanFlightTicket`.
- Local service and server receiver tests now validate this envelope
  before accepting decoded rows from `do_get`.
- README and wiki architecture/roadmap/session notes document the scan
  response envelope validation boundary.

Boundary:

- Local Arrow Flight scan response receiver-side validation only.
- No Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #177.
