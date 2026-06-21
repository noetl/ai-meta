# EHDB placement policy merged
- Timestamp: 2026-06-21T19:23:49Z
- Author: Kadyapam
- Tags: ehdb,storage,placement-policy,data-gravity,replication,submodule,pointer,memory

## Summary
noetl/ehdb PR #27 merged on main as df0029de6fbbbf24bc398a5d33062eefcdf47ff0 and closed issue #26. The merged slice adds PlacementRole, PlacementTarget, and PlacementPolicy to ehdb-storage. Placement policies validate exactly one primary, minimum copy count, shared data-gravity shard across all targets, and no duplicate geo/shard placements; local-dev policy remains deterministic. This turns geo/data-gravity pointers into an explicit metadata contract for future replication planners without implementing copy execution or gateway data-touch behavior. Validation passed locally and in GitHub CI: cargo fmt --all --check, cargo test --workspace with 53 tests, cargo clippy --workspace --all-targets -- -D warnings, cargo bench --workspace --no-run, and targeted Criterion benches. Benchmarks: placement_policy_validate_1000 ~1.19 ms, catalog_commit_snapshots_1000 ~2.12 ms, local_object_store/put_get_verified_100 ~14.7 ms, stream_publish_replay_1000 ~614 us, transaction_append_replay_1000 ~1.16 ms, local_reference_runtime/append_reopen_100 ~443 ms, local_transaction_jsonl/append_reopen_100 ~542 ms, local_stream_jsonl/publish_reopen_100 ~534 ms. Wiki updated in noetl/ehdb.wiki as ebe7a4c. ai-meta should bump repos/ehdb to df0029d and repos/ehdb-wiki to ebe7a4c.

## Actions
-

## Repos
-

## Related
-
