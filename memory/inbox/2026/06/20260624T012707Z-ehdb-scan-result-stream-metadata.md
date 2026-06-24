# EHDB scan result stream metadata validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/138
- PR: https://github.com/noetl/ehdb/pull/139
- Merged EHDB SHA: `5bd6982fabde4f355e96f64b50f633006f70127e`
- Wiki SHA: `44150fe8dcd49deedfaee698753889c70e725e7d`

## Summary

Validated Arrow Flight scan result stream metadata during local result
stream encode/decode. `ArrowScanResult` now stamps produced `FlightData`
streams with `ehdb.arrow.scan.result.v1`, aligns `FlightInfo` app
metadata to that result-stream version, and rejects empty,
missing-version, unsupported-version, or malformed streams before
accepting decoded Arrow batches.

Scope remains local Arrow Flight scan result stream codec validation
only: no Flight protocol expansion, distributed execution, SQL planner,
predicate pushdown implementation, gateway direct reads, non-loopback
exposure, production auth/IAM, background processing, or persistent
per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #139.

Coverage snapshot: 215 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
