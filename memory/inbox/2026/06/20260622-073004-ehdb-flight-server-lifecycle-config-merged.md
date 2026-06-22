# EHDB Arrow Flight server lifecycle config merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/53
- Closed issue: https://github.com/noetl/ehdb/issues/52
- EHDB merged SHA: `2d9837900aa7c22bd5fff6ac9150d48b75c74289`
- Wiki SHA: `51d64eedd536b52a70ff939c20e6ce377a354b5b`
- Branch: `kadyapam/ehdb-flight-server-lifecycle-config`

## Summary

Added `LocalArrowFlightServerConfig`, a validated lifecycle/config
surface for the local Arrow Flight scan service adapter. The config
tracks intended bind address, max decode/encode message sizes, max
concurrent requests, auth policy, and access-log policy. It defaults to
loopback local-reference use with bounded messages, bounded concurrency,
disabled local auth, and DEBUG-only access logs.

Validation rejects zero bounds and unauthenticated non-loopback binds.
The config can construct the generated `FlightServiceServer` with
message limits applied.

## Boundary

This adds lifecycle guardrails only. It does not bind a socket, start a
persistent server runtime, implement TLS/auth, schedule requests, emit
access logs, add SQL planning, predicate pushdown, distributed
execution, or give the gateway direct storage access. The NoETL
execution model boundary remains intact: gateway = gatekeeper, worker =
atomic compute, playbook = ephemeral blueprint, shared cache = state
vehicle, event log = source of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #53 in 3m11s.

Coverage after merge: 99 Rust tests plus Criterion benchmark
compilation/baselines.

