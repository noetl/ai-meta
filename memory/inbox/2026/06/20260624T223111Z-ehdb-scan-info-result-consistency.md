# EHDB scan info result consistency

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/154
- PR: https://github.com/noetl/ehdb/pull/155
- Merged EHDB SHA: `e8589b86f5923dd9957c0b8494d5c6a8ce9e62f9`
- Wiki SHA: `e4c3f912b752f9cd4cc95070a5cd7e85d60cd876`

## Summary

Validated Arrow Flight scan `FlightInfo` result consistency. EHDB now
validates produced scan `FlightInfo` fixtures against the producing
result schema, row count, encoded byte count, and expected scan ticket,
rejecting internally consistent but wrong-ticket fixtures before they can
be treated as produced metadata.

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
- GitHub Actions `rust` check passed on PR #155.

Coverage snapshot: 223 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
