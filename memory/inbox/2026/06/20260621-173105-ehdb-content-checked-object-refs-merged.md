# EHDB content-checked object refs merged
- Timestamp: 2026-06-21T17:31:05Z
- Author: Kadyapam
- Tags: ehdb,storage,object-refs,digest,submodule,pointer,memory

## Summary
noetl/ehdb PR #21 merged on main as 26911884d49b54c158e1bf4e48c8a4f895f1a1d6 and closed issue #20. The merged slice adds SHA-256 ObjectDigest, extends ObjectRef with path, byte length, and digest, adds ImmutableObjectStore::get_verified for length/digest-checked reads, and defines the deterministic table/snapshot path layout {tenant}/{namespace}/tables/{table}/snapshots/{snapshot}/{file}. Validation passed locally and in GitHub CI: cargo fmt --all --check, cargo test --workspace with 46 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, cargo bench -p ehdb-storage --bench local_store, cargo bench -p ehdb-reference --bench local_runtime, and cargo bench -p ehdb-transaction --bench reference_models. Benchmarks: local_object_store/put_get_verified_100 ~14.8 ms, stream_publish_replay_1000 ~640 us, transaction_append_replay_1000 ~1.17 ms, local_reference_runtime/append_reopen_100 ~476 ms, local_transaction_jsonl/append_reopen_100 ~454 ms, local_stream_jsonl/publish_reopen_100 ~452 ms. Wiki updated in noetl/ehdb.wiki as f9f859a. ai-meta should bump repos/ehdb to 2691188 and repos/ehdb-wiki to f9f859a.

## Actions
-

## Repos
-

## Related
-
