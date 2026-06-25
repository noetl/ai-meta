# EHDB Strict Storage Metadata Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/208
PR: https://github.com/noetl/ehdb/pull/209
EHDB merged SHA: `eb191349e46d60606d3311f84c4eb69b1b1d5520`
EHDB wiki SHA: `947b19b5e312442695f538fc774e2c719162c289`

Summary:
- Added strict storage metadata JSON decode validation.
- Object refs, geo placements, placement policy targets, replica
  records, replication actions, replication plans, and the local replica
  registry now reject unknown JSON fields.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Storage metadata JSON decoding validation only.
- No object movement, cloud adapters, network API, gateway data-touch
  behavior, production replication, scheduler, background worker, or
  persistent per-tenant service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #209.
- Coverage snapshot: 245 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
