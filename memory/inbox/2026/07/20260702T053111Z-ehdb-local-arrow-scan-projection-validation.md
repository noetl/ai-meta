# EHDB local Arrow scan projection shape validation

- Date: 2026-07-02 UTC
- Issue: noetl/ehdb#216
- PR: noetl/ehdb#217
- EHDB merged SHA: `f95aeae0ec3415ce72690383cbb3756e73aadf76`
- EHDB wiki SHA: `aa115072971d49e554ac699f39f7fcd2d63bdf2e`
- ai-meta submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

Added direct local Arrow scan projection shape validation to
`LocalArrowSnapshotScanner`. Direct scanner calls now reject empty
projection lists and duplicate projection columns before object reads,
matching the deterministic projection contract already enforced at the
service/Flight boundary.

The README and wiki architecture, roadmap, and session log now document
that direct local Arrow scans validate projection shape before reading
verified Arrow IPC objects.

## Boundary

This remains local Arrow IPC scan request validation only. It does not
add SQL planning, predicate pushdown, distributed execution, gateway
direct reads, Arrow Flight protocol changes, production IAM/ACL
behavior, request scheduling, object movement, or persistent per-tenant
service processes.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace` (249 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #217.
