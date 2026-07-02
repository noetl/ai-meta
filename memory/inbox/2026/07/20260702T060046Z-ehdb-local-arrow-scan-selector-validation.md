# EHDB local Arrow scan selector identifier validation

- Date: 2026-07-02 UTC
- Issue: noetl/ehdb#218
- PR: noetl/ehdb#219
- EHDB merged SHA: `714a50b932cb09891f2eb9f97ef9496949c3ed3c`
- EHDB wiki SHA: `d858fb216251e0361c4f377ad4db4e9b74fd1ca4`
- ai-meta submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

Added direct local Arrow scan selector identifier validation to
`LocalArrowSnapshotScanner`. Direct scanner calls now validate
projection-column and equality-predicate column selector identifiers
before object reads, while preserving `NotFound` behavior for
valid-but-missing selector columns.

The README and wiki architecture, roadmap, and session log now document
that direct local Arrow scans validate selector identifiers before
reading verified Arrow IPC objects.

## Boundary

This remains direct local Arrow IPC scan selector validation only. It
does not add SQL planning, predicate pushdown, distributed execution,
gateway direct reads, Arrow Flight protocol changes, production IAM/ACL
behavior, request scheduling, object movement, or persistent per-tenant
service processes.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace` (250 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #219.
