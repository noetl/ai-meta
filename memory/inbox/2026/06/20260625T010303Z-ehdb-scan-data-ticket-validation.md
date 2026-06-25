# EHDB scan data expected ticket validation

- Date: 2026-06-25 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#166`
- PR: `noetl/ehdb#167`
- EHDB merged SHA: `25643a903c0d3ea7426d25e719b99d8c228e0de7`
- EHDB wiki SHA: `5f87b331c4e0606d962a481ff1153c55d4561e46`
- ai-meta scope: submodule pointer bump plus memory only.

## Summary

EHDB added receiver-side scan data validation against the expected scan
ticket. `ArrowScanResult` now exposes helpers for raw `FlightData`
streams and decoded Arrow batches that validate returned scan data
against returned `FlightInfo` plus the expected `ScanFlightTicket`.
Local service, server, and loopback client smoke paths use those helpers
before treating returned scan data as coherent.

## Boundary

This remains local Arrow Flight scan data receiver-side validation only.
No Flight protocol expansion, distributed execution, SQL planner,
predicate pushdown implementation, gateway direct reads, non-loopback
exposure, production auth/IAM, background processing, or persistent
per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions Rust check passed on PR #167.

Coverage remains 226 Rust tests plus Criterion benchmark compilation.
