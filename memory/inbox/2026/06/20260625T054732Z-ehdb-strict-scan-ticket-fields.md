# EHDB Strict Scan Ticket Field Validation

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/184
PR: https://github.com/noetl/ehdb/pull/185
EHDB merged SHA: `3c460370cc3724ea2e08cfaffbbcf523e63522e3`
EHDB wiki SHA: `4ba0753b626c2d51f8f7e10a8a5888be26ef03ff`

Summary:
- Added strict local Arrow Flight scan ticket payload validation.
- `ScanFlightTicket::decode` rejects unknown top-level ticket fields,
  unknown embedded latest-table scan request fields, and unknown
  equality predicate fields before scan execution or Flight handoff.
- Valid ticket encode/decode, command descriptor, and local scan paths
  remain supported.
- Updated `repos/ehdb/README.md` and wiki design/session notes.

Boundary:
- Local Arrow Flight scan ticket/request payload validation only.
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
- GitHub Actions `rust` check passed on PR #185.
- Coverage snapshot: 230 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
