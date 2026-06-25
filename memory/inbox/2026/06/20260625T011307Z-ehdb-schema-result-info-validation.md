# EHDB schema result scan info validation

- Date: 2026-06-25 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#168`
- PR: `noetl/ehdb#169`
- EHDB merged SHA: `0e4b518ac8b23433c4a312c24f3e533c1a1dff8a`
- EHDB wiki SHA: `cee1652627a2b22b56a8d8b6094c2ddf0b18ecab`
- ai-meta scope: submodule pointer bump plus memory only.

## Summary

EHDB added receiver-side schema-result validation against returned scan
`FlightInfo`. `ScanFlightTicket` now decodes returned `SchemaResult`
values and validates returned scan info against the expected scan ticket
plus decoded schema. Local service and server receiver paths use this
before treating `get_schema` and `get_flight_info` as coherent; loopback
client paths validate already-decoded schemas against returned
`FlightInfo`.

## Boundary

This remains local Arrow Flight schema/scan-info receiver-side
validation only. No Flight protocol expansion, distributed execution,
SQL planner, predicate pushdown implementation, gateway direct reads,
non-loopback exposure, production auth/IAM, background processing, or
persistent per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions Rust check passed on PR #169.

Coverage remains 226 Rust tests plus Criterion benchmark compilation.
