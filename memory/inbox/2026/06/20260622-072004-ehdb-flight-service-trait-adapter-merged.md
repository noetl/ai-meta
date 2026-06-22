# EHDB Arrow Flight scan service trait adapter merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/51
- Closed issue: https://github.com/noetl/ehdb/issues/50
- EHDB merged SHA: `42ff431a9d102bf7b8af3f4c9091960b9f28aa73`
- Wiki SHA: `c0bb1f54e6473bb0c728acd32d8ae33cd06b9179`
- Branch: `kadyapam/ehdb-flight-service-trait-adapter`

## Summary

Added `LocalArrowFlightServer`, the first generated Arrow Flight
`FlightService` trait adapter for EHDB scans. The adapter handles
`get_flight_info` by decoding command descriptors through
`ScanFlightTicket`, handles `do_get` by streaming `FlightData` from the
existing local facade, maps EHDB errors to deterministic gRPC statuses,
and returns explicit `UNIMPLEMENTED` statuses for unsupported Flight
methods.

## Boundary

This is a trait-level network boundary only. It does not bind a port,
start a persistent server runtime, add TLS/auth policy, introduce
request-concurrency or access-log policy, add SQL planning, predicate
pushdown, distributed execution, or give the gateway direct storage
access. The NoETL execution model boundary remains intact: gateway =
gatekeeper, worker = atomic compute, playbook = ephemeral blueprint,
shared cache = state vehicle, event log = source of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #51 in 3m05s.

Coverage after merge: 95 Rust tests plus Criterion benchmark
compilation/baselines.

