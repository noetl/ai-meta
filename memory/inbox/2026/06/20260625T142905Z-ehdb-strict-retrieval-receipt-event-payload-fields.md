# EHDB Strict Retrieval Receipt Event Payload Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/196
PR: https://github.com/noetl/ehdb/pull/197
EHDB merged SHA: `00b7a488b6617c02ef5fc716d027f03f8a167d8f`
EHDB wiki SHA: `6010d30606fc95b41d4709fe9e4128b69a71b33d`

Summary:
- Added strict local retrieval context execution receipt event payload
  field validation.
- `RetrievalContextPayloadExecutionReceiptEventPayload::decode` now
  rejects unknown top-level event envelope fields.
- Nested receipt payload bytes remain validated by the existing strict
  canonical receipt decoder.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local retrieval context receipt event payload validation only.
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
- GitHub Actions `rust` check passed on PR #197.
- Coverage snapshot: 237 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
