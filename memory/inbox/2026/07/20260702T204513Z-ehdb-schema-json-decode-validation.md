# EHDB schema JSON decode validation

- Date: 2026-07-02 UTC
- Issue: noetl/ehdb#224
- PR: noetl/ehdb#225
- EHDB merged SHA: `7c00dd7e185a02ecd4922de17ff0160a2018515c`
- EHDB wiki SHA: `a2cc35bedb37000d732b617a496914c7099c457a`
- ai-meta submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

Added table and column schema JSON decode validation in `ehdb-core`.
`ColumnSchema` decode now routes through `ColumnSchema::new`, and
`TableSchema` decode routes through `TableSchema::new`, preserving
strict unknown-field behavior and the existing JSON shape while
rejecting invalid column identifiers and duplicate table schema columns
during metadata decode.

The README and wiki architecture, roadmap, and session log now document
the schema JSON decode contract.

## Boundary

This remains table/column schema JSON decode validation only. It does
not add schema evolution, type coercion, SQL planning, predicate
pushdown, distributed execution, gateway direct reads, production
IAM/ACL behavior, object movement, or persistent per-tenant service
processes.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace` (253 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #225.
