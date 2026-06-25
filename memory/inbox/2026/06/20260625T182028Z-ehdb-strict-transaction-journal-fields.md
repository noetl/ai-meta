# EHDB Strict Transaction Journal Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/204
PR: https://github.com/noetl/ehdb/pull/205
EHDB merged SHA: `4fdd7f4d7e7641845767382501bee3fd3dbd6d75`
EHDB wiki SHA: `3986c6a584f3acaf804bc7c10168359b95d540cf`

Summary:
- Added strict JSONL transaction journal field replay validation.
- Persisted transaction records now reject unknown fields during replay.
- Catalog, stream, retrieval, system-library, and storage mutation
  payloads now reject unknown fields during replay.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local transaction journal replay validation only.
- No network API, gateway route, prompt engine, LLM invocation,
  retrieval daemon, distributed transaction coordinator, production
  replication, background processing, or persistent per-tenant service
  process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #205.
- Coverage snapshot: 243 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
