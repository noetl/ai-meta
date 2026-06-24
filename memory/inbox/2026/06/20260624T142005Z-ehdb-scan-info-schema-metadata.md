# EHDB scan info schema metadata

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/148
- PR: https://github.com/noetl/ehdb/pull/149
- Merged EHDB SHA: `2812af14af09ddfb528cea8421586892f266f10a`
- Wiki SHA: `d8887b323e5799f7a04ee5fd16bd71e2c3a26485`

## Summary

Validated Arrow Flight scan `FlightInfo` schema metadata. The local
`FlightInfo` validator now rejects missing or empty schema IPC bytes
before treating scan info as valid.

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
- GitHub Actions `rust` check passed on PR #149.

Coverage snapshot: 220 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
