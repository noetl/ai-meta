# EHDB raw FlightData schema validation

Date: 2026-06-25 UTC

Repository state:

- `noetl/ehdb#175` merged to `main` as
  `42975587be9ef6cf10416d11b02232ed76aab321`.
- Closed issue:
  [#174 Validate raw Arrow Flight scan data against schema result](https://github.com/noetl/ehdb/issues/174).
- Wiki updated as `dcc707b607b86d95b236d81ad77d72f264ea43b8`.

Summary:

- Added `ArrowScanResult::from_flight_data_for_schema_info_and_ticket`
  for raw Arrow Flight `FlightData` plus decoded `get_schema` schema,
  returned scan `FlightInfo`, and expected `ScanFlightTicket`.
- Local service and server receiver tests now validate raw `do_get`
  `FlightData` through that helper before accepting decoded rows.
- README and wiki architecture/roadmap/session notes document the raw
  scan data schema validation boundary.

Boundary:

- Local Arrow Flight raw scan data receiver-side validation only.
- No Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #175.
