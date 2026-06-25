# EHDB Strict Catalog Metadata Fields

Date: 2026-06-25 UTC

Repository: `noetl/ehdb`
Issue: https://github.com/noetl/ehdb/issues/210
PR: https://github.com/noetl/ehdb/pull/211
EHDB merged SHA: `390a94110cf0acdedd8a61def1eba5e982196dc3`
EHDB wiki SHA: `95da92ee40128cad4508aa3efd349463fbfde63a`

Summary:
- Added strict catalog metadata JSON decode validation.
- Catalog tables, snapshots, scan grants, create-table requests,
  snapshot commits, scan grant requests, table schemas, and column
  schemas now reject unknown JSON fields.
- Updated `repos/ehdb/README.md` and wiki architecture, roadmap, and
  session notes.

Boundary:
- Catalog metadata JSON decoding validation only.
- No network API, gateway route, production ACL/IAM engine, query
  planner, distributed transaction coordinator, background worker, or
  persistent per-tenant service process was added.
- Preserve the NoETL execution model: gateway = gatekeeper, worker =
  atomic compute, playbook = ephemeral blueprint, shared cache = state
  vehicle, event log = source of truth.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #211.
- Coverage snapshot: 246 Rust tests across unit, integration, and
  doc-test targets plus Criterion benchmark compilation.
