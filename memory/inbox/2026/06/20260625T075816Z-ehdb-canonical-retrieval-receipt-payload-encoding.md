# EHDB Canonical Retrieval Receipt Payload Encoding

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/194
PR: https://github.com/noetl/ehdb/pull/195
EHDB merged SHA: `7fb92e9f5b7fdb1383e484a95a42f8b2f53a783d`
EHDB wiki SHA: `b6b58e3557cd4954f114f8474921a42d4229cf4b`

Summary:
- Added canonical local retrieval context execution receipt payload
  byte validation.
- `RetrievalContextPayloadExecutionReceiptPayload::decode` now rejects
  pretty-printed or otherwise non-canonical JSON bytes unless they
  exactly match the EHDB encoding produced by
  `RetrievalContextPayloadExecutionReceiptPayload::encode`.
- Existing artifact validation and receipt-event helper paths remain on
  the stricter receipt decoder.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local retrieval context receipt payload byte-contract validation only.
- No stream publication behavior, network API, gateway route, prompt
  engine, LLM invocation, retrieval daemon, distributed search service,
  production IAM, background processing, or persistent per-tenant
  service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #195.
- Coverage snapshot: 236 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
