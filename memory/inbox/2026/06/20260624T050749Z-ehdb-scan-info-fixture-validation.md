# EHDB scan info fixture validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/142
- PR: https://github.com/noetl/ehdb/pull/143
- Merged EHDB SHA: `5a1954eb81565015e6f956586632d91d0d84c2af`
- Wiki SHA: `bb0ae6828e0c10f6abc3b214d962bba93a5cf447`

## Summary

Added local Arrow Flight scan `FlightInfo` fixture validation.
`ArrowScanResult::to_flight_info` now validates generated fixtures, and
`ArrowScanResult::validate_flight_info` rejects unsupported app metadata,
unordered scan results, negative record or byte counts, missing endpoint
tickets, and multiple endpoints while reusing the scan ticket validation
boundary for descriptors and endpoint tickets.

Scope remains local Arrow Flight scan `FlightInfo` fixture validation
only: no Flight protocol expansion, distributed execution, SQL planner,
predicate pushdown implementation, gateway direct reads, non-loopback
exposure, production auth/IAM, background processing, or persistent
per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #143.

Coverage snapshot: 217 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
