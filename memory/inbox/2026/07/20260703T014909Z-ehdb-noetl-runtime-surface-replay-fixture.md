# EHDB NoETL Runtime Surface Replay Fixture

Date: 2026-07-03 UTC

Issue:
- `noetl/ehdb#228` — Add NoETL runtime surface replay fixture

Merged PR:
- `noetl/ehdb#229` — `test: add NoETL runtime surface replay fixture`

Pointers:
- `repos/ehdb` should point at
  `200ade198095d172a796bce8d1bcd076f39ec9ba`.
- `repos/ehdb-wiki` should point at
  `8cacacfcf342f8565d6ff5e1cd05e20f5fca4404`.

Summary:
- Added an `ehdb-reference` integration test that drives a
  worker/playbook-shaped NoETL flow only through
  `LocalReferenceRuntime` appends.
- The fixture covers catalog table/snapshot/grant metadata, stream
  events, retrieval document/chunk/embedding metadata, system WASM
  library binding, and storage replica inventory.
- The fixture reopens the runtime and verifies catalog scan grants,
  stream consumer replay, retrieval text lookup, system library
  resolution, and storage replica counts from transaction replay.

Boundary:
- This is a local reference/runtime integration fixture only.
- No gateway route, direct gateway data access, persistent per-tenant
  service, production IAM, distributed execution, SQL planning, object
  movement, or external dependency replacement behavior was added.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace` — 255 Rust tests
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

