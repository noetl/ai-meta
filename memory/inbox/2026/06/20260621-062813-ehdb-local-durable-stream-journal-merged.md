# EHDB local durable stream journal merged
- Timestamp: 2026-06-21T06:28:13Z
- Author: Kadyapam
- Tags: ehdb,stream,submodule,pointer,memory

## Summary
noetl/ehdb PR #11 merged on main as 96b50a3f0c9a539b3e4baef11b4ffc7f9aca4db6 and closed issue #10. The merged slice adds LocalJsonlStreamLog, a fsynced append-only JSONL stream journal for create-stream, create-consumer, publish, and ack operations. Reopen rebuilds retained records, durable consumer ack cursors, and next stream sequence; corrupt journal entries fail deterministically. Validation passed locally: cargo fmt --all --check, cargo test --workspace with 31 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, and cargo bench -p ehdb-transaction --bench reference_models. Benchmarks: stream_publish_replay_1000 ~629 us, transaction_append_replay_1000 ~1.04 ms, local_transaction_jsonl/append_reopen_100 ~454 ms, local_stream_jsonl/publish_reopen_100 ~457 ms. Wiki updated in noetl/ehdb.wiki as cbc4794. ai-meta should bump repos/ehdb to 96b50a3 and repos/ehdb-wiki to cbc4794.

## Actions
-

## Repos
-

## Related
-
