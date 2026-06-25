# EHDB Stream Sequence Serde Validation

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/200
PR: https://github.com/noetl/ehdb/pull/201
EHDB merged SHA: `d14eba7589bae84eb9089c35e904fbcb30afd7a0`
EHDB wiki SHA: `6c0b603b8c1cb850b45277a21972bfe923607182`

Summary:
- Added custom `StreamSequence` serde deserialization that preserves the
  same nonzero invariant as `StreamSequence::new`.
- JSONL stream journal replay now rejects persisted zero publish record
  sequences before rebuilding retained stream state.
- JSONL stream journal replay now rejects persisted zero ack cursor
  sequences before rebuilding durable consumer cursors.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Local stream journal replay validation only.
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
- GitHub Actions `rust` check passed on PR #201.
- Coverage snapshot: 241 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
