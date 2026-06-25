# EHDB Canonical Retrieval Receipt Event Payload Encoding

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/198
PR: https://github.com/noetl/ehdb/pull/199
EHDB merged SHA: `095db5246ecb272ece7a1ee07a871672808513fb`
EHDB wiki SHA: `c6c5a9c81384a0224ae1e01726b82e4d2c9d0e34`

Summary:
- Added canonical local retrieval context execution receipt event
  payload byte validation.
- `RetrievalContextPayloadExecutionReceiptEventPayload::decode` now
  rejects pretty-printed or otherwise non-canonical JSON bytes unless
  they exactly match the EHDB encoding produced by
  `RetrievalContextPayloadExecutionReceiptEventPayload::encode`.
- Nested receipt payload bytes remain validated by the existing strict
  canonical receipt decoder.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local retrieval context receipt event payload byte-contract validation
  only.
- No stream publication behavior changes, network API, gateway route,
  prompt engine, LLM invocation, retrieval daemon, distributed search
  service, production IAM, background processing, or persistent
  per-tenant service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #199.
- Coverage snapshot: 238 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
