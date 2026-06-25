# EHDB Strict Stream Journal Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/202
PR: https://github.com/noetl/ehdb/pull/203
EHDB merged SHA: `89e35cff7f90e36b02ec47ba521428b5629c4199`
EHDB wiki SHA: `317774a9a705e2549a27371b57316f4ffcffaab5`

Summary:
- Added strict JSONL stream journal field replay validation.
- Persisted stream journal operation envelopes now reject unknown fields
  during replay.
- Persisted stream configs and stream records now reject unknown fields
  during replay.
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
- GitHub Actions `rust` check passed on PR #203.
- Coverage snapshot: 242 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
