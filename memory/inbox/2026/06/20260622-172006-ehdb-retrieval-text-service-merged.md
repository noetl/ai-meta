# EHDB retrieval text search boundary merged

Date: 2026-06-22

## Summary

- Merged `noetl/ehdb#77`, closing issue #76.
- EHDB merged SHA: `8b853e5de110d15e4c9aae72bc12bd114609eb9f`.
- EHDB wiki SHA: `4fa416500b2d958e8c332cfe8b4b3d1873b314c4`.
- Feature branch: `kadyapam/ehdb-retrieval-text-service`.

## Platform Note

`ehdb-retrieval` now has typed `TextSearch` and `TextSearchHit`
boundaries for exact case-insensitive local substring matching over
registered chunk text, scoped by tenant and namespace. The fixture
validates non-empty queries and positive limits, returns match counts,
and orders hits deterministically.

`LocalRetrievalSearchService::search_text` exposes the same replayed
runtime behavior through `SearchTextChunksRequest` and
`SearchTextChunksHit` for future worker/playbook-shaped RAG lookup.

This remains an in-process correctness boundary only. It does not add a
full-text index, BM25 engine, network service, gateway route, production
IAM, external search adapter, distributed query engine, retrieval
daemon, gateway direct data path, or persistent per-tenant service
process.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage snapshot: 130 Rust tests across unit, integration, and
doc-test targets plus benchmark compilation.
