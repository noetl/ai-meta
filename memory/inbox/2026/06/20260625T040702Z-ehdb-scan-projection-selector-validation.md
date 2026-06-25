# EHDB Scan Projection Selector Shape Validation

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/180
PR: https://github.com/noetl/ehdb/pull/181
EHDB merged SHA: `1bfbf73696ee1611de04ca774e9050825bee70d0`
EHDB wiki SHA: `e272a99a7b668c7746a0ecfb1934f7587d8f2083`

Summary:
- Added local Arrow scan projection selector shape validation.
- `ScanFlightTicket` and `LocalArrowScanService` reject empty projection
  lists and duplicate projection columns before scan execution or Flight
  ticket encode/decode succeeds.
- Valid projection/filter scans remain supported.
- Updated `repos/ehdb/README.md` and wiki design/session notes.

Boundary:
- Local scan request selector validation only.
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
- GitHub Actions `rust` check passed on PR #181.
- Coverage snapshot: 228 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
