# EHDB catalog snapshots merged
- Timestamp: 2026-06-21T17:53:43Z
- Author: Kadyapam
- Tags: ehdb,catalog,snapshots,mvcc,submodule,pointer,memory

## Summary
noetl/ehdb PR #23 merged on main as 296c5c8bd6fe8605dc1f4852883a7bac994f15bb and closed issue #22. The merged slice adds immutable catalog table snapshot metadata over content-checked ObjectRef file sets, latest snapshot tracking per table, parent-chain validation, and CatalogMutation::CommitSnapshot replay support in ehdb-reference and LocalReferenceRuntime. Validation passed locally and in GitHub CI: cargo fmt --all --check, cargo test --workspace with 49 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, cargo bench -p ehdb-catalog --bench snapshots, cargo bench -p ehdb-storage --bench local_store, cargo bench -p ehdb-reference --bench local_runtime, and cargo bench -p ehdb-transaction --bench reference_models. Benchmarks: catalog_commit_snapshots_1000 ~2.06 ms, local_object_store/put_get_verified_100 ~16.9 ms, stream_publish_replay_1000 ~656 us, transaction_append_replay_1000 ~1.37 ms, local_reference_runtime/append_reopen_100 ~491 ms, local_transaction_jsonl/append_reopen_100 ~508 ms, local_stream_jsonl/publish_reopen_100 ~534 ms. Wiki updated in noetl/ehdb.wiki as c5f11c7. ai-meta should bump repos/ehdb to 296c5c8 and repos/ehdb-wiki to c5f11c7.

## Actions
-

## Repos
-

## Related
-
