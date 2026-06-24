# EHDB scan selector identifier validation

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/136
- PR: https://github.com/noetl/ehdb/pull/137
- Merged EHDB SHA: `f318fcb4a8978a718be2094245c8c672ab611ea4`
- Wiki SHA: `b6cf9a9179072cc86ece0aa30599186e91cf9abf`

## Summary

Validated Arrow Flight scan selector identifiers during local scan ticket
encode/decode. `ScanFlightTicket` now revalidates projection-column and
equality-predicate column identifiers before producing bytes, Arrow
`Ticket` values, or command descriptors, and after decoding ticket bytes.
Invalid decoded selector identifiers fail before local scan execution.

Scope remains local Arrow Flight scan ticket codec validation only: no SQL
planner, predicate pushdown implementation, distributed execution, gateway
direct reads, non-loopback exposure, production auth/IAM, background
processing, or persistent per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #137.

Coverage snapshot: 214 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
