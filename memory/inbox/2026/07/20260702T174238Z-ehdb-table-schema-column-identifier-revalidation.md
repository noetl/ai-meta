# EHDB table schema column identifier revalidation

- Date: 2026-07-02 UTC
- Issue: noetl/ehdb#222
- PR: noetl/ehdb#223
- EHDB merged SHA: `20d4bca81dd32c91ebb7ed17425a29951e59850b`
- EHDB wiki SHA: `04e06b470eda6b5e10e1570858c383c36c8dfa1b`
- ai-meta submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

Added table schema column identifier revalidation in `ehdb-core`.
`TableSchema::new` now revalidates every column identifier, including
preconstructed or decoded `ColumnSchema` values, before catalog state is
created. This preserves non-empty schema and duplicate-column validation
while keeping Arrow projection and predicate selectors unambiguous.

The README and wiki architecture, roadmap, and session log now document
the table schema column identifier revalidation contract.

## Boundary

This remains table schema validation only. It does not add schema
evolution, type coercion, SQL planning, predicate pushdown, distributed
execution, gateway direct reads, production IAM/ACL behavior, object
movement, or persistent per-tenant service processes.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace` (252 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #223.
