# EHDB placement pointers merged
- Timestamp: 2026-06-21T19:04:07Z
- Author: Kadyapam
- Tags: ehdb,storage,placement,geo,data-gravity,submodule,pointer,memory

## Summary
noetl/ehdb PR #25 merged on main as 784215c0853a35a48cfc0066096ae9b899f21b66 and closed issue #24. The merged slice adds CloudProvider, GeoLocation, DataGravityShard, and ObjectPlacement to ehdb-storage; ObjectRef now carries path, byte length, digest, geo placement, and data-gravity shard metadata. LocalObjectStore defaults to deterministic local-dev placement, and catalog snapshot fixtures now carry placement pointers with content-checked object refs. This records geo location and data gravity as storage-layer routing pointers for future distributed placement, replication, compaction locality, and read scheduling without moving data-touch logic into the gateway. Validation passed locally and in GitHub CI: cargo fmt --all --check, cargo test --workspace with 50 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, plus targeted Criterion benches. Benchmarks: catalog_commit_snapshots_1000 ~1.94 ms, local_object_store/put_get_verified_100 ~14.6 ms, stream_publish_replay_1000 ~613 us, transaction_append_replay_1000 ~1.14 ms, local_reference_runtime/append_reopen_100 ~486 ms, local_transaction_jsonl/append_reopen_100 ~571 ms, local_stream_jsonl/publish_reopen_100 ~517 ms. Wiki updated in noetl/ehdb.wiki as f13f148. ai-meta should bump repos/ehdb to 784215c and repos/ehdb-wiki to f13f148.

## Actions
-

## Repos
-

## Related
-
