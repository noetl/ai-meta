# EHDB scan info endpoint envelope

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/146
- PR: https://github.com/noetl/ehdb/pull/147
- Merged EHDB SHA: `f452decce58a191e33f2bbfcff893dd48e0544ea`
- Wiki SHA: `fafa8acc0ce80de7247729911ace223b0784595b`

## Summary

Validated the local Arrow Flight scan `FlightInfo` endpoint envelope. The
local `FlightInfo` validator now rejects endpoint locations, endpoint
expiration timestamps, and endpoint app metadata so the single endpoint
stays pre-network.

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
- GitHub Actions `rust` check passed on PR #147.

Coverage snapshot: 219 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
