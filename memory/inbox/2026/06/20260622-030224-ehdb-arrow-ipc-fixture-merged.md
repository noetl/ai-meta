# EHDB Arrow IPC Table Fixture Merged

Date: 2026-06-22

`noetl/ehdb#35` merged as
`b0aa14687357a1032a8f8cff98d8a378d2d7fde8`, closing
`noetl/ehdb#34`.

The change added `LocalArrowIpcTableStore` in `ehdb-reference`. The
fixture writes Arrow `RecordBatch` values as immutable IPC objects,
commits catalog snapshots over content-checked `ObjectRef` values, and
reads the latest snapshot back through verified object reads before
Arrow IPC decode. Corrupted object bytes are rejected before decode.

The EHDB wiki was updated as
`1eaa22cca5f0a5ca13895d01398b978e5ab03302` with architecture, roadmap,
and session-log notes.

Validation passed locally and in GitHub CI: `cargo fmt --all --check`,
`cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D
warnings`, `cargo bench --workspace --no-run`, and targeted Criterion
benchmarks. Coverage is 66 Rust tests.

Boundary note: this proves the local Arrow-native catalog/object data
path. It does not add Arrow Flight service endpoints, distributed query
execution, Parquet adapters, or gateway direct data access.
