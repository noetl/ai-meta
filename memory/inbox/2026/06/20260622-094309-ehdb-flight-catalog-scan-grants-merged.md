# EHDB Flight Catalog Scan Grants Merged

Date: 2026-06-22

Repository: `noetl/ehdb`

Issue: https://github.com/noetl/ehdb/issues/64

Pull request: https://github.com/noetl/ehdb/pull/65

Merged code SHA: `8bd1aace3ddc33911fb8ede47fc6822532cb282c`

Wiki SHA: `eb3b7ec1c0e9f7afc603997493fc52fa2ca43089`

Branch: `kadyapam/ehdb-flight-catalog-scan-grants`

Summary:

- Added `FlightScanGrantPolicy` to the local Arrow Flight reference
  service.
- Added default principal metadata header
  `x-ehdb-principal`.
- Enforced replayed `CatalogScanGrant` records before local
  `get_flight_info` and `do_get` scan execution.
- Returned gRPC `UNAUTHENTICATED` for missing or invalid principal
  metadata and `PERMISSION_DENIED` for principals without scan grants.
- Preserved the existing `new_with_policies` constructor shape and added
  `new_with_authorization_policies` for auth + scope + grant policy
  combinations.
- Covered direct generated-service enforcement and loopback Arrow Flight
  client enforcement.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #65 in 3m21s.

Coverage:

- 117 Rust tests across unit, integration, and doc-test targets.

Boundary:

- This is local reference enforcement over EHDB catalog state.
- No production IAM, policy composition, revocation, non-loopback
  exposure, gateway direct reads, SQL planning, predicate pushdown,
  distributed execution, or persistent per-tenant service process was
  added.
