# EHDB Arrow Equality Filter Fixture Merged

Date: 2026-06-22

`noetl/ehdb#39` merged as
`f2100737915650e143fe964c05f207da8964fbc9`, closing issue #38.
Wiki documentation was updated at `repos/ehdb-wiki` commit `cd3d2da`.

The change adds a local Arrow equality-filter fixture to
`LocalArrowSnapshotScanner` in `ehdb-reference`:

- single-column equality predicates over UTF-8 and Int64 Arrow arrays;
- filter execution after verified Arrow IPC object reads/decode and
  before optional projection;
- deterministic failures for missing predicate columns and scalar/type
  mismatches;
- focused tests for UTF-8 filtering, Int64 filtering before projection,
  missing columns, and type mismatch handling.

Validation completed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace` (72 tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- targeted Criterion benchmark runs for `ehdb-reference`, `ehdb-storage`,
  `ehdb-catalog`, and `ehdb-transaction`

Boundary note: this is still a local reference fixture for the NoETL
EHDB domain storage path. It does not add SQL planning, predicate
pushdown, Arrow Flight service endpoints, distributed query execution,
or gateway direct database access.
