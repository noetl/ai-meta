# EHDB scan info schema-response validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/158
- PR: https://github.com/noetl/ehdb/pull/159
- Merged EHDB SHA: `4f154d99529e511bf64415461af7e59fed0b4c8d`
- Wiki SHA: `1b978ce4ebe694ef235585f6726ae59d8837181d`

## Summary

Validated Arrow Flight scan `FlightInfo` schema-response consistency on
the receiver side. `ScanFlightTicket` can now reject well-formed
`FlightInfo` responses whose schema metadata differs from the schema
returned by `get_schema`, and the loopback client smoke path validates
that consistency before using the endpoint ticket.

Scope remains local Arrow Flight scan `FlightInfo` receiver-side
validation only: no Flight protocol expansion, distributed execution, SQL
planner, predicate pushdown implementation, gateway direct reads,
non-loopback exposure, production auth/IAM, background processing, or
persistent per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #159.

Coverage snapshot: 225 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
