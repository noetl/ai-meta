# EHDB scan info endpoint ticket helper

- Date: 2026-06-25 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#162`
- PR: `noetl/ehdb#163`
- EHDB merged SHA: `188f0a82e17130792df3ad728cfa64b9fd6f1fcd`
- EHDB wiki SHA: `cf82e7a563c0f98a248958adda35e7a05d832c6a`
- ai-meta scope: submodule pointer bump plus memory only.

## Summary

EHDB added receiver-side validated endpoint-ticket extraction for local
Arrow Flight scan `FlightInfo`. `ScanFlightTicket` now returns the
endpoint ticket only after validating the returned scan info against the
expected scan ticket, and the loopback client smoke path uses the helper
before `do_get`.

## Boundary

This remains local Arrow Flight scan `FlightInfo` receiver-side
validation only. No Flight protocol expansion, distributed execution,
SQL planner, predicate pushdown implementation, gateway direct reads,
non-loopback exposure, production auth/IAM, background processing, or
persistent per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions Rust check passed on PR #163.

Coverage remains 226 Rust tests plus Criterion benchmark compilation.
