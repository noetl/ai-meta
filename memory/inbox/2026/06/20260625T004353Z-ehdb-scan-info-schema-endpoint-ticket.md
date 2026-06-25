# EHDB scan info schema endpoint ticket helper

- Date: 2026-06-25 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#164`
- PR: `noetl/ehdb#165`
- EHDB merged SHA: `1fbd467802ccb8e902063364b83f712e53407679`
- EHDB wiki SHA: `0a94d39c6497d8cc06aec479bbe68c201f0a726e`
- ai-meta scope: submodule pointer bump plus memory only.

## Summary

EHDB added schema-aware receiver-side endpoint-ticket extraction for
local Arrow Flight scan `FlightInfo`. `ScanFlightTicket` now returns the
endpoint ticket only after validating the returned scan info against the
expected scan ticket and expected Arrow schema. Local service, server,
and loopback client smoke paths use the helper before `do_get`.

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
- GitHub Actions Rust check passed on PR #165.

Coverage remains 226 Rust tests plus Criterion benchmark compilation.
