# EHDB scan info descriptor-ticket consistency

- Date: 2026-06-24 UTC
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/144
- PR: https://github.com/noetl/ehdb/pull/145
- Merged EHDB SHA: `c86fb397210e6de73ecea17f13c74a3127786503`
- Wiki SHA: `ffe2d7e5b59fec8082970b17fa31721d8f3f50f7`

## Summary

Validated Arrow Flight scan `FlightInfo` descriptor-ticket consistency.
The local `FlightInfo` validator now decodes the command descriptor and
endpoint ticket, compares the resulting scan requests, and rejects valid
but mismatched descriptor/ticket pairs before treating scan info as
valid.

Scope remains local Arrow Flight scan `FlightInfo` fixture validation
only: no Flight protocol expansion, distributed execution, SQL planner,
predicate pushdown implementation, gateway direct reads, non-loopback
exposure, production auth/IAM, background processing, or persistent
per-tenant service process was added.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #145.

Coverage snapshot: 218 Rust tests across unit, integration, and doc-test
targets plus Criterion benchmark compilation.
