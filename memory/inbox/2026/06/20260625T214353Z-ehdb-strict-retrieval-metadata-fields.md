# EHDB Strict Retrieval Metadata Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/212
PR: https://github.com/noetl/ehdb/pull/213
EHDB merged SHA: `9458476eeb7474ba807974e9facaeb7c769e274d`
EHDB wiki SHA: `abc6ef0b0f5b03caab6c94ea445dd07a76b4383f`

Summary:
- Added strict retrieval metadata JSON decode validation.
- Retrieval documents, chunks, embeddings, registration requests,
  vector/text/hybrid search requests, and local search hit metadata now
  reject unknown JSON fields.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Retrieval metadata JSON decoding validation only.
- No ANN index, full-text index, retrieval daemon, network API, gateway
  route, prompt engine, LLM invocation, production IAM, query planner,
  background worker, or persistent per-tenant service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #213.
- Coverage snapshot: 247 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
