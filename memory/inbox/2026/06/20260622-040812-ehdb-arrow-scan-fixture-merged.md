# EHDB Arrow Snapshot Scan Fixture Merged

Date: 2026-06-22

`noetl/ehdb#37` merged as
`6f271754a83969a30900b8a71266a50978a89047`, closing
`noetl/ehdb#36`.

The change added `LocalArrowSnapshotScanner` in `ehdb-reference`. The
scanner resolves the latest catalog snapshot, verifies Arrow IPC object
bytes before decode, returns decoded `RecordBatch` output, and supports
optional named column projection in caller-specified order. Missing
projection columns fail deterministically.

The EHDB wiki was updated as
`56283fcbb619b0c3bb29c162056918d7b258c051` with architecture, roadmap,
and session-log notes.

Validation passed locally and in GitHub CI: `cargo fmt --all --check`,
`cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D
warnings`, `cargo bench --workspace --no-run`, and targeted Criterion
benchmarks. Coverage is 68 Rust tests.

Boundary note: this is a local scan fixture only. Predicate pushdown,
SQL planning, Arrow Flight, distributed execution, and gateway direct
data access remain future surfaces.
