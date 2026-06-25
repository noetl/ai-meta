# EHDB strict system-library metadata field validation

- Date: 2026-06-25 UTC
- Issue: noetl/ehdb#214
- PR: noetl/ehdb#215
- EHDB merged SHA: `a7776b919a82130ac5f249b88f367d886c258304`
- EHDB wiki SHA: `3454b96b502ddcd86982c85703b3068ff417a820`
- ai-meta submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

Added strict system-library metadata JSON decode validation for resolved
WASM library manifests, NoETL WASM plugin references, and
environment/channel binding metadata. These shapes now reject unknown
JSON fields before persisted or worker-handoff system-library metadata is
accepted.

The wiki architecture, roadmap, and session log now document the
strict metadata handoff contract for NoETL hot-replaceable system WASM
libraries.

## Boundary

This remains system-library metadata decode validation only. It does not
add WASM execution, background processing, network API, gateway
data-touch behavior, production replication, scheduler behavior,
distributed transaction coordination, object transfer execution, or
persistent per-tenant service processes.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace` (248 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #215.
