# EHDB Canonical Retrieval Context Payload Encoding

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/190
PR: https://github.com/noetl/ehdb/pull/191
EHDB merged SHA: `f28f1492cc2a30d76f00f81f61859bc3ebe2035a`
EHDB wiki SHA: `0e8aead9ec096a53942f21e92661ea3dda7bc871`

Summary:
- Added canonical local retrieval context payload byte validation.
- `RetrievalContextRequestPayload::decode` rejects pretty-printed or
  otherwise non-canonical JSON bytes unless they exactly match the EHDB
  encoding produced by `RetrievalContextRequestPayload::encode`.
- `RetrievalContextResultPayload::decode` applies the same canonical
  byte check for result payloads.
- Existing local payload execution paths remain on the stricter decoder.
- Updated `repos/ehdb/README.md` and wiki design/session notes.

Boundary:
- Local retrieval context worker/playbook payload byte-contract
  validation only.
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
- GitHub Actions `rust` check passed on PR #191.
- Coverage snapshot: 234 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
