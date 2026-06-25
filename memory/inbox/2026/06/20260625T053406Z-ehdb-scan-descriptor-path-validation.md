# EHDB Scan Command Descriptor Path Validation

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/182
PR: https://github.com/noetl/ehdb/pull/183
EHDB merged SHA: `9a60c4da5bc961124dc21f16454047c8dbf1f3a1`
EHDB wiki SHA: `69f1beee22d1c5198e1c79c7a8d54c58b70d1173`

Summary:
- Added local Arrow Flight scan command descriptor path validation.
- `LocalArrowFlightServer` rejects direct `get_flight_info` and
  `get_schema` command descriptors that carry non-empty path entries
  before scan execution.
- Valid command descriptors produced by
  `ScanFlightTicket::command_descriptor` continue to work.
- Updated `repos/ehdb/README.md` and wiki design/session notes.

Boundary:
- Local Arrow Flight scan descriptor request validation only.
- No Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #183.
- Coverage snapshot: 229 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
