# EHDB local reference runtime merged
- Timestamp: 2026-06-21T07:11:07Z
- Author: Kadyapam
- Tags: ehdb,reference-runtime,replay,submodule,pointer,memory

## Summary
noetl/ehdb PR #19 merged on main as 84643386ba21b520003c956168cfbb3eae00dd86 and closed issue #18. The merged slice adds LocalReferenceRuntime over LocalJsonlTransactionLog: it previews transaction records, applies mutations to cloned reference state before durable append, prevents invalid projected commits from advancing the JSONL log, and rebuilds catalog, stream, retrieval, and system-library projections from transaction replay on reopen. Validation passed locally and in GitHub CI: cargo fmt --all --check, cargo test --workspace with 43 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, cargo bench -p ehdb-reference --bench local_runtime, and cargo bench -p ehdb-transaction --bench reference_models. Benchmarks: stream_publish_replay_1000 ~626 us, transaction_append_replay_1000 ~1.18 ms, local_reference_runtime/append_reopen_100 ~486 ms, local_transaction_jsonl/append_reopen_100 ~482 ms, local_stream_jsonl/publish_reopen_100 ~477 ms. Wiki updated in noetl/ehdb.wiki as 1e1f3bf. ai-meta should bump repos/ehdb to 8464338 and repos/ehdb-wiki to 1e1f3bf.

## Actions
-

## Repos
-

## Related
-
