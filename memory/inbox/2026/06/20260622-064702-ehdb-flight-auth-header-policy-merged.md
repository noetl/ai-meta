# EHDB Arrow Flight auth header policy merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/59
- Closed issue: https://github.com/noetl/ehdb/issues/58
- EHDB merged SHA: `c8a92c081c07a4d30cb990425b29ee168a168449`
- Wiki SHA: `36426853b398bc5a1623ebfa8be3018ca6bd95ef`
- Branch: `kadyapam/ehdb-flight-auth-header-policy`

## Summary

Added the first request metadata auth contract for the local Arrow
Flight reference path. `FlightAuthPolicy::HeaderToken` validates ASCII
metadata header names, rejects binary metadata headers, requires
non-empty non-control-character tokens, and returns gRPC
`UNAUTHENTICATED` statuses for missing or mismatched scan request
metadata.

`LocalArrowFlightServerConfig` now validates the auth policy and passes
it into the generated service adapter. Implemented scan methods
`get_flight_info` and `do_get` enforce the policy. Direct service tests
cover missing, wrong, and valid tokens; a loopback Arrow Flight client
smoke test proves config-to-listener auth propagation over tonic/gRPC.

## Boundary

This is a local-reference auth-boundary contract only. It does not add
non-loopback exposure, production TLS/identity, ACL enforcement, gateway
integration, SQL planning, predicate pushdown, distributed execution, or
gateway direct storage access. The NoETL execution model boundary
remains intact: gateway = gatekeeper, worker = atomic compute, playbook
= ephemeral blueprint, shared cache = state vehicle, event log = source
of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #59 in 2m23s.

Coverage after merge: 106 Rust tests plus Criterion benchmark
compilation/baselines.
