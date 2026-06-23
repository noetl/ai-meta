# EHDB scan ticket identifier validation

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/134
- PR: https://github.com/noetl/ehdb/pull/135
- Merged EHDB SHA: `2e18c2190e221efc5d9e9503b79c2f97222afbdd`
- Wiki SHA: `001cea2226b805371193667464071f1fde3c0df2`

## Summary

Validated Arrow Flight scan ticket identifiers during local scan ticket
encode/decode. `ScanFlightTicket` now revalidates tenant, namespace, and
table-name identifiers before producing bytes, Arrow `Ticket` values, or
command descriptors, and after decoding ticket bytes. Invalid decoded
identifiers fail before local scan execution.

Scope remains local Arrow Flight scan ticket codec validation only: no SQL
planner, predicate pushdown, distributed execution, gateway direct reads,
non-loopback exposure, production auth/IAM, background processing, or
persistent per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #135.

Coverage snapshot: 213 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
