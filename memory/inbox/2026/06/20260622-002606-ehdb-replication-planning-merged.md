# EHDB replication planning merged
- Timestamp: 2026-06-22T00:26:06Z
- Author: Kadyapam
- Tags: ehdb,storage,replication-planning,placement,data-gravity,submodule,pointer,memory

## Summary
noetl/ehdb PR #29 merged on main as 6b3393a696b13e34b84eb2c4d62c44dec4dd4d51 and closed issue #28. The merged slice adds ObjectReplica, ReplicationAction, ReplicationPlan, and plan_replication to ehdb-storage. The planner compares a source object and known replicas with PlacementPolicy, emits AlreadySatisfied and CopyNeeded actions, and rejects source/policy shard mismatch plus replica digest, length, or shard mismatch. This is planner metadata only; it does not execute copies or add background workers/gateway data-touch behavior. Validation passed locally and in GitHub CI: cargo fmt --all --check, cargo test --workspace with 56 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, and targeted Criterion benches. Benchmarks: replication_plan_1000 ~2.92 ms, placement_policy_validate_1000 ~1.18 ms, catalog_commit_snapshots_1000 ~1.98 ms, local_object_store/put_get_verified_100 ~15.7 ms, stream_publish_replay_1000 ~626 us, transaction_append_replay_1000 ~1.16 ms, local_reference_runtime/append_reopen_100 ~516 ms, local_transaction_jsonl/append_reopen_100 ~554 ms, local_stream_jsonl/publish_reopen_100 ~540 ms. Wiki updated in noetl/ehdb.wiki as 289440f. ai-meta should bump repos/ehdb to 6b3393a and repos/ehdb-wiki to 289440f.

## Actions
-

## Repos
-

## Related
-
