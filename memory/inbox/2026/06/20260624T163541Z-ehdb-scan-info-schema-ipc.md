# EHDB scan info schema IPC validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/150
- PR: https://github.com/noetl/ehdb/pull/151
- Merged EHDB SHA: `d17daa13d913e014fb4358ededc59c440fded2fd`
- Wiki SHA: `ed85824a33a954295202f3eb1ed6951d25fbcfad`

## Summary

Validated Arrow Flight scan `FlightInfo` schema IPC bytes. The local
`FlightInfo` validator now decodes non-empty schema metadata as Arrow
schema IPC bytes and rejects malformed schema payloads before treating
scan info as valid.

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
- GitHub Actions `rust` check passed on PR #151.

Coverage snapshot: 221 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
