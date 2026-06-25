# EHDB Strict Retrieval Context Payload Field Validation

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/188
PR: https://github.com/noetl/ehdb/pull/189
EHDB merged SHA: `9c80d974aefc7abe5582d0c8da0732ab1f88e004`
EHDB wiki SHA: `a3ab141fab30f8f19528d5f80d8a5889ff8b4641`

Summary:
- Added strict local retrieval context payload field validation.
- `RetrievalContextRequestPayload::decode` rejects unknown request
  envelope and embedded assembly request fields.
- `RetrievalContextResultPayload::decode` rejects unknown result
  envelope, context object, and context block fields.
- Valid request/result payload round trips remain supported.
- Updated `repos/ehdb/README.md` and wiki design/session notes.

Boundary:
- Local retrieval context worker/playbook payload validation only.
- No network API, gateway route, prompt engine, LLM invocation,
  retrieval daemon, distributed search service, production IAM,
  background processing, or persistent per-tenant service process was
  added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #189.
- Coverage snapshot: 233 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
