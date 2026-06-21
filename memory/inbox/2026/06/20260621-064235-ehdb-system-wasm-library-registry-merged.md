# EHDB system WASM library registry merged
- Timestamp: 2026-06-21T06:42:35Z
- Author: Kadyapam
- Tags: ehdb,wasm,system-libraries,submodule,pointer,memory

## Summary
noetl/ehdb PR #13 merged on main as 039adefdb7f15076283e2ef38c53f9f7207282a9 and closed issue #12. The merged slice adds ehdb-system for immutable NoETL system WASM module manifests and mutable tenant/namespace/environment/channel bindings, supporting hot replacement by rebinding stable channels to new digest/revision values without Rust crate semantic-version churn. It also adds SystemMutation publish/bind records to ehdb-transaction and extends the NoETL cross-domain surface test. Validation passed locally: cargo fmt --all --check, cargo test --workspace with 36 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, and cargo bench -p ehdb-transaction --bench reference_models. Benchmarks: stream_publish_replay_1000 ~626 us, transaction_append_replay_1000 ~1.04 ms, local_transaction_jsonl/append_reopen_100 ~448 ms, local_stream_jsonl/publish_reopen_100 ~456 ms. Wiki updated in noetl/ehdb.wiki as 9df35a1. ai-meta should bump repos/ehdb to 039adef and repos/ehdb-wiki to 9df35a1.

## Actions
-

## Repos
-

## Related
-
