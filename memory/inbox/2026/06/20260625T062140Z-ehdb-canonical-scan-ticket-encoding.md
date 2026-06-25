# EHDB Canonical Scan Ticket Encoding

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/186
PR: https://github.com/noetl/ehdb/pull/187
EHDB merged SHA: `dd4633aeeb85270b593256141aa74b98f4ee4586`
EHDB wiki SHA: `df2f3415f23b507457f8ebdea4512a227e3a5e8a`

Summary:
- Added canonical local Arrow Flight scan ticket byte validation.
- `ScanFlightTicket::decode` rejects pretty-printed or otherwise
  non-canonical JSON bytes unless they exactly match the EHDB encoding
  produced by `ScanFlightTicket::encode`.
- `to_arrow_ticket`, `command_descriptor`, and implemented server scan
  methods remain on that stricter decode path.
- Updated `repos/ehdb/README.md` and wiki design/session notes.

Boundary:
- Local Arrow Flight scan ticket byte-contract validation only.
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
- GitHub Actions `rust` check passed on PR #187.
- Coverage snapshot: 231 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
