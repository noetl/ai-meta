# EHDB scan info expected-ticket validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/156
- PR: https://github.com/noetl/ehdb/pull/157
- Merged EHDB SHA: `6f90a9f084ca23d502f93b0b025ecc026f21c474`
- Wiki SHA: `babfe245eb070a173d6c81c6dc65ce6c2e2759d7`

## Summary

Validated Arrow Flight scan `FlightInfo` against the expected scan ticket
on the receiver side. `ScanFlightTicket` can now reject an internally
consistent `FlightInfo` response that belongs to a different scan request,
and the loopback client smoke path validates returned `FlightInfo` before
using its endpoint ticket.

Scope remains local Arrow Flight scan `FlightInfo` receiver-side
validation only: no Flight protocol expansion, distributed execution, SQL
planner, predicate pushdown implementation, gateway direct reads,
non-loopback exposure, production auth/IAM, background processing, or
persistent per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #157.

Coverage snapshot: 224 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
