# EHDB replay-complete mutations merged
- Timestamp: 2026-06-21T07:00:00Z
- Author: Kadyapam
- Tags: ehdb,transaction,replay,submodule,pointer,memory

## Summary
noetl/ehdb PR #17 merged on main as 16b65db228bd4b6540f595384b0c48ba4c7db0d6 and closed issue #16. The merged slice makes transaction mutations replay-complete: Arrow schema serde is enabled, EHDB table schemas serialize, catalog/stream/retrieval/system mutations carry enough facts to rebuild reference state, and ehdb-reference applies TransactionRecord replay into catalog, stream, retrieval, and system-library reference catalogs. Validation passed locally: cargo fmt --all --check, cargo test --workspace with 41 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, and cargo bench -p ehdb-transaction --bench reference_models. Benchmarks: stream_publish_replay_1000 ~626 us, transaction_append_replay_1000 ~1.21 ms, local_transaction_jsonl/append_reopen_100 ~488 ms, local_stream_jsonl/publish_reopen_100 ~486 ms. Wiki updated in noetl/ehdb.wiki as e165293. ai-meta should bump repos/ehdb to 16b65db and repos/ehdb-wiki to e165293.

## Actions
-

## Repos
-

## Related
-
