# EHDB catalog scan grant reference model merged

- Date: 2026-06-22
- Repo: `noetl/ehdb`
- PR: https://github.com/noetl/ehdb/pull/63
- Closed issue: https://github.com/noetl/ehdb/issues/62
- EHDB merged SHA: `f13258a8c829bdc2950fd1a1f9ec2c970a99df32`
- Wiki SHA: `d9deca78c6f811f0e93c50a58643845f506c5ea7`
- Branch: `kadyapam/ehdb-catalog-scan-grants`

## Summary

Added the first catalog-side scan grant reference model. `PrincipalId`
is now a typed EHDB identifier. `CatalogScanGrant` records tenant,
namespace, table ID, principal, and granting transaction ID.
`InMemoryCatalog::grant_scan` rejects missing tables and duplicate
table/principal grants, while `can_scan` answers the future service
authorization lookup.

`CatalogMutation::GrantScan` makes scan grant metadata replayable
through the transaction log, `ehdb-reference`, and
`LocalReferenceRuntime`. Runtime restart coverage now verifies that scan
grant metadata rebuilds from replay and remains queryable.

## Boundary

This is durable catalog ACL metadata, not production IAM or service
enforcement. It does not add policy composition, revocation,
non-loopback exposure, gateway integration, SQL planning, predicate
pushdown, distributed execution, or gateway direct storage access. The
NoETL execution model boundary remains intact: gateway = gatekeeper,
worker = atomic compute, playbook = ephemeral blueprint, shared cache =
state vehicle, event log = source of truth.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #63 in 3m17s.

Coverage after merge: 113 Rust tests plus Criterion benchmark
compilation/baselines.
