# EHDB Strict System Library Journal Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/206
PR: https://github.com/noetl/ehdb/pull/207
EHDB merged SHA: `3fe220226f8a96bfc752654b192548b0578a13ba`
EHDB wiki SHA: `774062f2805b7260eaf7529111bc6d54b22d0da7`

Summary:
- Added strict JSONL system-library journal field replay validation.
- Persisted system-library journal entries now reject unknown fields
  during replay.
- Persisted publish and bind request payloads now reject unknown fields
  before rebuilding WASM manifest and hot-replacement binding state.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local system-library journal replay validation only.
- No WASM execution, background processing, network API, gateway
  data-touch behavior, production replication, scheduler behavior,
  object transfer execution, distributed transaction coordinator, or
  persistent per-tenant service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #207.
- Coverage snapshot: 244 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
