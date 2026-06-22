# EHDB Flight concurrency guard merged

Date: 2026-06-22

## Summary

- Merged `noetl/ehdb#71`, closing issue #70.
- EHDB merged SHA: `76622a7d38911f222bb11cdb9f5b37ef00565c17`.
- EHDB wiki SHA: `f4deb46b252e79860d8b4b52e1822e959136e8a6`.
- Feature branch: `kadyapam/ehdb-flight-concurrency-guard`.

## Platform Note

`LocalArrowFlightServerConfig::max_concurrent_requests` now feeds a
fail-fast local semaphore in the generated Arrow Flight reference
adapter. Implemented scan methods `get_flight_info`, `get_schema`, and
`do_get` return gRPC `RESOURCE_EXHAUSTED` when all local request slots
are occupied.

This remains a local lifecycle guard only. It does not introduce a
request queue, distributed admission controller, non-loopback service
exposure, production IAM, gateway integration, SQL planning, predicate
pushdown, distributed execution, gateway direct data access, or a
persistent per-tenant service process.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage snapshot: 121 Rust tests across unit, integration, and
doc-test targets plus benchmark compilation.
