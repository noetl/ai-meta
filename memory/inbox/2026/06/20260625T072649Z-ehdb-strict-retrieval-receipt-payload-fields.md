# EHDB Strict Retrieval Receipt Payload Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/192
PR: https://github.com/noetl/ehdb/pull/193
EHDB merged SHA: `b532146585b13b8a721c23ccffb2e57692f75a2a`
EHDB wiki SHA: `bea5ec4c39aebac442dd4839f70f314df2b04f30`

Summary:
- Added strict local retrieval context execution receipt payload field
  validation.
- `RetrievalContextPayloadExecutionReceiptPayload::decode` now rejects
  unknown top-level receipt envelope fields.
- The embedded `RetrievalContextPayloadExecutionSummary` decoder now
  rejects unknown redacted summary fields.
- Existing artifact validation and receipt-event helper paths remain on
  the stricter receipt decoder.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local retrieval context receipt payload validation only.
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
- GitHub Actions `rust` check passed on PR #193.
- Coverage snapshot: 235 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
