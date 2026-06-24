# EHDB scan result metadata envelope

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/140
- PR: https://github.com/noetl/ehdb/pull/141
- Merged EHDB SHA: `72abdb7d29cca0c9bb38e90a3c672691b45093ac`
- Wiki SHA: `1c8fd4715303b38ee2d46143dde77efc6b929e62`

## Summary

Enforced a strict Arrow Flight scan result metadata envelope during local
result stream decode. `ArrowScanResult` now accepts the
`ehdb.arrow.scan.result.v1` marker only on the first `FlightData` message,
keeps locally produced later-message app metadata empty, and rejects
non-empty later-message app metadata before Arrow decode.

Scope remains local Arrow Flight scan result stream codec validation only:
no Flight protocol expansion, distributed execution, SQL planner,
predicate pushdown implementation, gateway direct reads, non-loopback
exposure, production auth/IAM, background processing, or persistent
per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #141.

Coverage snapshot: 216 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
