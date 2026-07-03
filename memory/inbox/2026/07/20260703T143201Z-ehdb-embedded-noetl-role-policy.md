# EHDB Embedded NoETL Role Capability Policy

## Tracking

- Issue: `noetl/ehdb#230` — Add embedded NoETL role capability policy
- PR: `noetl/ehdb#231` — `feat: add embedded NoETL role policy`
- EHDB merged SHA:
  `16bba82eca54ade012fcfa2b9bf96149e7cb5102`
- EHDB wiki SHA:
  `0a0c01090b05b4520ad43cb1512b26b3d8c113c1`
- `ai-meta` submodules to pin: `repos/ehdb`, `repos/ehdb-wiki`

## Summary

- Added `NoetlEmbeddedRole` in `ehdb-core` for gateway, API, worker,
  playbook, and system contexts.
- Added `EhdbCapability` to distinguish control-plane embedding from
  catalog, transaction, stream, object, retrieval, replication, and
  system-library data-plane access.
- Gateway/API roles default to control-plane only.
- Worker/playbook roles default to explicit data-plane capabilities.
- System role defaults to all control/data-plane capabilities.
- JSON decoding rejects unknown roles and capabilities.
- Wiki now documents EHDB as an embedded distributed database substrate
  for NoETL workers, APIs, and gateways with gateway/API capability
  guardrails.

## Boundary

- This is policy/modeling only.
- It does not add a daemon, network API, gateway route, SQL planner,
  distributed executor, production IAM, storage mutation behavior, or
  persistent per-tenant process.
- It preserves the NoETL boundary: gateway/API embedding is allowed for
  control-plane planning, not direct storage access.

## Validation

- `cargo fmt`
- `cargo fmt --all --check`
- `cargo test -p ehdb-core` — 10 core tests
- `cargo test --workspace` — 258 Rust tests across unit, integration,
  and doc-test targets
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed
