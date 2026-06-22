# EHDB Flight Get Schema Adapter Merged

Date: 2026-06-22

Repository: `noetl/ehdb`

Issue: https://github.com/noetl/ehdb/issues/68

Pull request: https://github.com/noetl/ehdb/pull/69

Merged code SHA: `154c265cc328ca05dd41a831a41cc134cddc03a5`

Wiki SHA: `5c22f657e88031fd0323f7247d434fd815e07a6f`

Branch: `kadyapam/ehdb-flight-get-schema-adapter`

Summary:

- Added `LocalArrowFlightService::get_schema` for projected latest-table
  scan schemas.
- Implemented generated Arrow Flight `get_schema` for versioned scan
  command descriptors.
- Reused the same request metadata auth, tenant/namespace scan scope,
  catalog scan grant, and bounded access-log policies used by
  `get_flight_info` and `do_get`.
- Extended direct service/generator tests and the loopback Arrow Flight
  client smoke path to cover schema discovery.
- Updated README and wiki design pages.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #69 in 3m02s.

Coverage:

- 120 Rust tests across unit, integration, and doc-test targets.

Boundary:

- This is local reference schema discovery only.
- No non-loopback exposure, production IAM, gateway direct reads, SQL
  planning, predicate pushdown, distributed execution, request scheduler,
  or persistent per-tenant service process was added.
