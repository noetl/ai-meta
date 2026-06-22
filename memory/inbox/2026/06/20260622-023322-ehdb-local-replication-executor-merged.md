# EHDB Local Replication Executor Merged

Date: 2026-06-22

`noetl/ehdb#33` merged as
`23227a0833b56abc51c38fb4f7d0c7979d67b7d5`, closing
`noetl/ehdb#32`.

The change added `LocalReplicationExecutor` in `ehdb-reference`. The
executor consumes deterministic `ReplicationPlan` values, verifies
source object bytes through `ImmutableObjectStore::get_verified`, and
appends `StorageMutation::RegisterReplica` transactions through
`LocalReferenceRuntime` for copy-needed targets. Already-satisfied plans
are no-ops.

The EHDB wiki was updated as
`6f10d1de6092b044d00dfbec2d5877fe432ce786` with architecture, roadmap,
and session-log notes.

Validation passed locally and in GitHub CI: `cargo fmt --all --check`,
`cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D
warnings`, `cargo bench --workspace --no-run`, and targeted Criterion
benchmarks. Coverage is 64 Rust tests.

Boundary note: this is a bounded local execution reference for a future
worker/playbook replication step. It does not add gateway data-touch
logic, long-lived schedulers, or cloud transfer adapters.
