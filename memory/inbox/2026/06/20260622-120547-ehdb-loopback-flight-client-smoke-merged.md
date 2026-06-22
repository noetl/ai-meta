# EHDB loopback Arrow Flight client smoke test merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/57
- Closed issue: https://github.com/noetl/ehdb/issues/56
- EHDB merged SHA: `765f216e453cc9e24704bb8c82617388b3574b19`
- Wiki SHA: `f2d5644f3eaf5c6ab9f3d6d6f84cb4efb860f149`
- Branch: `kadyapam/ehdb-loopback-flight-client-smoke`

## Summary

Added a loopback transport smoke test for the Arrow Flight read path.
The test starts `LocalArrowFlightListener` on loopback with explicit
shutdown, connects with Arrow Flight `FlightClient` over tonic/gRPC
transport, calls `get_flight_info` using the scan command descriptor,
follows the returned endpoint ticket with `do_get`, and asserts decoded
Arrow rows.

## Boundary

This is local-reference verification only. It does not add gateway
integration, non-loopback exposure, TLS/auth implementation, request
scheduling, SQL planning, predicate pushdown, distributed execution, or
gateway direct storage access. The NoETL execution model boundary
remains intact: gateway = gatekeeper, worker = atomic compute, playbook
= ephemeral blueprint, shared cache = state vehicle, event log = source
of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #57 in 3m06s.

Coverage after merge: 102 Rust tests plus Criterion benchmark
compilation/baselines.

