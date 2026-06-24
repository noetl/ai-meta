# EHDB scan info byte-count validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/152
- PR: https://github.com/noetl/ehdb/pull/153
- Merged EHDB SHA: `c188e3d49afe5f4be791b8ce8d92fd8b3cc2eb40`
- Wiki SHA: `259f20f1c5f5e428217fbaaeaa1f4c829963ca01`

## Summary

Validated Arrow Flight scan `FlightInfo` byte-count metadata. The local
`FlightInfo` validator now requires positive `total_bytes`, rejecting
zero byte-count fixtures while preserving negative byte-count rejection.

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
- GitHub Actions `rust` check passed on PR #153.

Coverage snapshot: 222 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
