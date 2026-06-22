# EHDB local Arrow Flight service facade merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/49
- Closed issue: https://github.com/noetl/ehdb/issues/48
- EHDB merged SHA: `0e501004ef01fa45c1b1ce65de93fa5e415b97b0`
- Wiki SHA: `d4fbad2097ded5d1f9ba12cafec713bf5ff32344`
- Branch: `kadyapam/ehdb-local-flight-service-facade`

## Summary

Added `LocalArrowFlightService` as an in-process facade over the local
scan service and Arrow Flight codecs. The facade builds `FlightInfo`
from typed latest-table scan requests and executes `do_get` from Arrow
Flight tickets to `FlightData` result streams.

The slice reuses `ScanFlightTicket`,
`ArrowScanResult::to_flight_info`, and
`ArrowScanResult::to_flight_data`. Tests cover the info/do_get
round-trip, malformed ticket rejection before scan execution, and
missing-table error propagation.

## Boundary

This remains a local service facade only. It does not introduce an
Arrow Flight network server/client, SQL planner, predicate pushdown,
distributed executor, or gateway direct read path. The NoETL execution
model boundary remains intact: gateway = gatekeeper, worker = atomic
compute, playbook = ephemeral blueprint, shared cache = state vehicle,
event log = source of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #49 in 2m56s.

Coverage after merge: 91 Rust tests plus Criterion benchmark
compilation/baselines.

