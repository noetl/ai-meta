# EHDB Object Replica Registry Merged

Date: 2026-06-22

`noetl/ehdb#31` merged as
`c77ad8ad8786fca9edaa4c2b0ec3fac639553b2a`, closing
`noetl/ehdb#30`.

The change added `InMemoryObjectReplicaRegistry`, idempotent object
replica registration, digest/length/data-gravity shard conflict checks,
`StorageMutation::RegisterReplica`, and replay through
`ehdb-reference`/`LocalReferenceRuntime`. Replication planning can now be
fed from durable replica registry state instead of caller-supplied
arrays.

The EHDB wiki was updated as
`8590d475f673a584dc22f333e1a15d3346d2334b` with architecture,
roadmap, and session-log notes.

Validation passed locally and in GitHub CI: `cargo fmt --all --check`,
`cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D
warnings`, `cargo bench --workspace --no-run`, and targeted Criterion
benchmarks. Coverage is 61 Rust tests.

Boundary note: this is replica inventory and planning metadata only.
Object-copy execution remains future bounded worker/playbook behavior;
the gateway still must not perform data-touch work.
