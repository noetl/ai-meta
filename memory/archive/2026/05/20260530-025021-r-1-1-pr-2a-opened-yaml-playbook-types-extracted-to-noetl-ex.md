# R-1.1 PR-2a opened: YAML playbook types extracted to noetl-executor::playbook
- Timestamp: 2026-05-30T02:50:21Z
- Author: Kadyapam
- Tags: rust,executor,migration,issue-30,pr-21,r1-1-pr2a

## Summary
PR noetl/cli#21 moves 432 LoC of Pydantic-like YAML types from src/playbook_runner.rs to executor/src/playbook.rs as the first of four sub-PRs that finish R-1.1. Mechanical extraction with no behaviour change: types/fields private to playbook_runner.rs become pub in the executor crate so the impl block reaches them across the crate boundary. main.rs untouched. Re-exported via pub use noetl_executor::playbook::{...} with #[allow(unused_imports)]. playbook_runner.rs went 2688 -> 2277 lines. cargo check --workspace + cargo test --workspace green; 3 noetl-executor unit tests pass. Originally task #32 split into PR-2a/2b/2c/2d for reviewability. Task #35 next: PR-2b lifts parser + command-generation logic (~1,200 LoC) into executor/src/sources/local_playbook.rs.

## Actions
-

## Repos
-

## Related
-
