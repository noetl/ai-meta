# EHDB duplicate table schema column validation

- Date: 2026-07-02 UTC
- Issue: noetl/ehdb#220
- PR: noetl/ehdb#221
- EHDB merged SHA: `6cc5d8edeb7637304458657acafd7f85fc37785e`
- EHDB wiki SHA: `9cd4807923f2bc21a6cce246b02bc4d5413c2e62`
- ai-meta submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

Added duplicate table schema column validation in `ehdb-core`.
`TableSchema::new` now rejects duplicate column names before catalog
state is created, preserving non-empty schema and per-column identifier
validation while keeping Arrow projection and predicate selectors
unambiguous.

The README and wiki architecture, roadmap, and session log now document
the table schema uniqueness contract.

## Boundary

This remains table schema validation only. It does not add schema
evolution, type coercion, SQL planning, predicate pushdown, distributed
execution, gateway direct reads, production IAM/ACL behavior, object
movement, or persistent per-tenant service processes.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace` (251 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #221.
