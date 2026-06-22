# EHDB Arrow Flight scan scope metadata guard merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/61
- Closed issue: https://github.com/noetl/ehdb/issues/60
- EHDB merged SHA: `89a069094deb3fbd3b26f25aa593dab39983daba`
- Wiki SHA: `c79d1e6e25ca5b9016a44b45f3350d3faa14212c`
- Branch: `kadyapam/ehdb-flight-scope-metadata-guard`

## Summary

Added `FlightScanScopePolicy`, the first tenant/namespace request-scope
contract for the local Arrow Flight scan path. When enabled, the
generated service decodes the scan descriptor or ticket and requires
`x-ehdb-tenant` plus `x-ehdb-namespace` metadata to match the decoded
`ScanLatestTableRequest` before local scan execution.

Missing scope metadata returns gRPC `UNAUTHENTICATED`; mismatched scope
metadata returns `PERMISSION_DENIED`. The default remains disabled for
local-reference compatibility. Coverage includes policy validation,
direct generated-service tests, and a loopback Arrow Flight client smoke
test proving the guard over tonic/gRPC transport.

## Boundary

This is a scope-boundary contract for future catalog ACL work, not an
ACL engine. It does not add non-loopback exposure, production
TLS/identity, gateway integration, SQL planning, predicate pushdown,
distributed execution, or gateway direct storage access. The NoETL
execution model boundary remains intact: gateway = gatekeeper, worker =
atomic compute, playbook = ephemeral blueprint, shared cache = state
vehicle, event log = source of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #61 in 3m05s.

Coverage after merge: 110 Rust tests plus Criterion benchmark
compilation/baselines.
