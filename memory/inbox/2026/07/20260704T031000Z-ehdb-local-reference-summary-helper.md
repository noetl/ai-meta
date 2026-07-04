# EHDB Local Reference Summary Helper

## Tracking

- Issue: `noetl/ehdb#232` — Add local-reference summary helper
- PR: `noetl/ehdb#233` — `feat: add local-reference summary helper`
- EHDB merged SHA:
  `0dc2016f4b692d3d868ccbc3918900962a880ca1`
- EHDB wiki SHA:
  `df3f6fbdd42dbfc4fce36ff44c818146760313e2`
- `ai-meta` submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

- Added `LocalReferenceSummary` in `ehdb-reference`.
- Added `summarize_local_reference` and
  `summarize_local_reference_json`.
- Added `ehdb-local-reference summary --log <path>`.
- Added read-only count accessors in `ehdb-stream` and
  `ehdb-retrieval`.
- Summary JSON includes local replay counts for transactions, catalog
  tables/snapshots/scan grants, streams/records/consumers, retrieval
  documents/chunks/embeddings, system libraries/bindings, and storage
  objects/replicas.

## Boundary

- This is bounded local reference inspection for NoETL worker/playbook
  diagnostics and integration tests.
- It does not add a daemon, network API, gateway route, SQL planner,
  distributed executor, production IAM, storage mutation behavior,
  background worker, or persistent per-tenant process.
- It preserves the NoETL boundary: future NoETL helper invocation can
  call a bounded binary from worker/playbook contexts, while
  gateway/API surfaces remain control-plane only.

## Validation

- `cargo fmt`
- `cargo test -p ehdb-stream -p ehdb-retrieval -p ehdb-reference`
- `cargo run -p ehdb-reference --bin ehdb-local-reference -- --help`
- `cargo test --workspace`
- `cargo bench --workspace --no-run`
- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- GitHub Actions `rust` check passed
