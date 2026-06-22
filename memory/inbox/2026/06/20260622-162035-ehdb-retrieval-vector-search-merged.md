# EHDB retrieval vector search fixture merged

Date: 2026-06-22

## Summary

- Merged `noetl/ehdb#73`, closing issue #72.
- EHDB merged SHA: `45243ef9a426e707ae165b07e1607a24ecca2760`.
- EHDB wiki SHA: `d464c02d8967253c0fe70e34846a5c237779fa8c`.
- Feature branch: `kadyapam/ehdb-retrieval-vector-search`.

## Platform Note

`ehdb-retrieval` now has a local exact cosine-similarity fixture:
`VectorSearch` scopes candidate chunk embeddings by tenant, namespace,
and embedding model, validates finite non-zero query and embedding
vectors, applies dimension compatibility, and returns deterministic
`VectorSearchHit` ordering.

This is a local RAG correctness primitive only. It does not introduce an
ANN index, retrieval daemon, production IAM, gateway integration,
external Qdrant adapter, distributed query engine, gateway direct data
path, or persistent per-tenant service process.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage snapshot: 124 Rust tests across unit, integration, and
doc-test targets plus benchmark compilation.
