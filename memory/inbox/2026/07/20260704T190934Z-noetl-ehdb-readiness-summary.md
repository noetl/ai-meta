# NoETL EHDB typed local-reference readiness summary

Date: 2026-07-04 UTC

`noetl/noetl#687` merged as
`f82ccb7f8fb2c2b8ccbc9881ca230d0ca60a8edd`, closing
`noetl/noetl#686`.

NoETL now has a typed summary/readiness surface over the packaged
`ehdb-local-reference summary --log <path>` helper:

- `LocalReferenceEhdbSummary` validates required summary fields,
  non-negative integer counts, and matching log path.
- `read_ehdb_local_reference_summary_from_env` executes the helper via
  the existing bounded worker/playbook wrapper and returns the typed
  summary.
- `scripts/smoke_ehdb_local_reference_summary.py` reuses the same
  summary contract instead of carrying duplicate raw JSON validation.

Scope boundary: this is a worker/playbook readiness/check surface only.
Gateway/API/server local-reference execution remains rejected by the
NoETL EHDB contract. No public routes, persistent services, GKE rollout,
PostgreSQL/NATS/object-store replacement, or direct gateway data-plane
access were added.

Validation:

- Focused EHDB suite: 66 tests.
- Nearby runtime suite: 115 tests.
- `compileall` over EHDB integration modules and smoke script.
- `git diff --check`.
- Real sibling-helper smoke with
  `../ehdb/target/release/ehdb-local-reference`.
- GitHub `forbid-client-term`.

Pointer state: `repos/noetl` should point at
`f82ccb7f8fb2c2b8ccbc9881ca230d0ca60a8edd`.
