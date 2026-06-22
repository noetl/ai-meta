# EHDB loopback Arrow Flight listener harness merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/55
- Closed issue: https://github.com/noetl/ehdb/issues/54
- EHDB merged SHA: `85ed083c3cb18d7927e2411ab3c3957f555e3c80`
- Wiki SHA: `d21465a59c73e03be8ad53c27c042a31be61d0e2`
- Branch: `kadyapam/ehdb-loopback-flight-listener`

## Summary

Added `LocalArrowFlightListener`, a loopback-only reference harness
behind `LocalArrowFlightServerConfig`. The harness binds configured or
ephemeral loopback sockets, exposes the actual bound local address,
serves the generated Arrow Flight service with configured message
limits, and terminates through an explicit shutdown future.

Non-loopback listener binds are rejected even when external auth policy
is selected.

## Boundary

This remains a local-reference harness only. It does not expose
non-loopback service, implement TLS/auth, add gateway integration,
introduce request scheduling, add SQL planning, predicate pushdown,
distributed execution, or give the gateway direct storage access. The
NoETL execution model boundary remains intact: gateway = gatekeeper,
worker = atomic compute, playbook = ephemeral blueprint, shared cache =
state vehicle, event log = source of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #55 in 3m11s.

Coverage after merge: 101 Rust tests plus Criterion benchmark
compilation/baselines.

