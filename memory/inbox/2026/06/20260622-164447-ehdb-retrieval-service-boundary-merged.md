# EHDB retrieval search service boundary merged

Date: 2026-06-22

## Post-Restart Health

- Podman machine `noetl-dev` was running after the Mac restart.
- Local `kind-noetl` cluster was reachable; NoETL server/workers,
  NATS, Postgres, MinIO, Kafka, and observability pods were Running.
- GKE context `gke_noetl-demo-19700101_us-central1_noetl-cluster`
  was reachable; NoETL server/workers and related platform pods were
  Running.

## Summary

- Merged `noetl/ehdb#75`, closing issue #74.
- EHDB merged SHA: `c6224be27b6df65c021fafad3a45c2954525604e`.
- EHDB wiki SHA: `d9053d9fde89141c5fe79c7a2471b61ee36abbac`.
- Feature branch: `kadyapam/ehdb-retrieval-service-boundary`.

## Platform Note

`LocalRetrievalSearchService` now gives `ehdb-service` a local
service-facing boundary over replayed retrieval state. It accepts
`SearchSimilarChunksRequest` values, calls the exact local
`VectorSearch` fixture, and returns ranked `SearchSimilarChunksHit`
values with chunk identity, document identity, ordinal, text, checksum,
embedding model, dimensions, and score while excluding raw embedding
vectors from service results.

This is an in-process reference boundary for future worker/playbook use
only. It does not introduce a network service, gateway route, production
IAM, ANN index, external Qdrant adapter, distributed query engine,
retrieval daemon, gateway direct data path, or persistent per-tenant
service process.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage snapshot: 126 Rust tests across unit, integration, and
doc-test targets plus benchmark compilation.
