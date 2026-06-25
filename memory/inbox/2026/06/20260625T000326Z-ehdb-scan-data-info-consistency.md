# EHDB scan data info consistency

- Date: 2026-06-25 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/160
- PR: https://github.com/noetl/ehdb/pull/161
- Merged EHDB SHA: `c599c181747031516eb10e596ec56441a3925cfc`
- Wiki SHA: `12adb4cfa8c42a696f5522b0de3aa2d46b20daac`

## Summary

Validated Arrow Flight scan data against returned `FlightInfo` metadata
on the receiver side. `ArrowScanResult` can now validate returned
`FlightData` streams against `FlightInfo` schema, row count, and encoded
byte-count metadata; the loopback client smoke path also validates
decoded scan output against returned `FlightInfo` before treating batches
as coherent.

Scope remains local Arrow Flight scan result receiver-side validation
only: no Flight protocol expansion, distributed execution, SQL planner,
predicate pushdown implementation, gateway direct reads, non-loopback
exposure, production auth/IAM, background processing, or persistent
per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #161.

Coverage snapshot: 226 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
