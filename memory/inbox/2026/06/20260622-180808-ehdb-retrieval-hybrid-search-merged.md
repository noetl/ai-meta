# EHDB retrieval hybrid search merged

Timestamp: 2026-06-23T01:07:37Z merge / 2026-06-22 local memory note

`noetl/ehdb#79` merged as
`3d58042a8fc173414dae149296f68f26dac45672`, closing issue #78:
https://github.com/noetl/ehdb/issues/78

Slice delivered the local retrieval hybrid search boundary for the
NoETL-domain EHDB storage track:

- `ehdb-retrieval` now has `HybridSearch` and `HybridSearchHit`.
- `InMemoryRetrievalCatalog::search_hybrid` combines exact cosine
  similarity and exact case-insensitive text match counts using finite
  non-negative weights.
- Results are scoped by tenant, namespace, and embedding model; vectors
  must match dimensions; zero combined scores are excluded.
- Ordering is deterministic by combined score, vector score, text match
  count, document id, ordinal, and chunk id.
- `ehdb-service` now exposes the replayed-state boundary as
  `LocalRetrievalSearchService::search_hybrid` with
  `SearchHybridChunksRequest` and `SearchHybridChunksHit`.

Non-goals remain explicit: no ANN index, BM25 engine, learned ranker,
network service, gateway route, production IAM, external search adapter,
distributed query engine, retrieval daemon, gateway direct data path, or
persistent per-tenant service process.

Validation passed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage after the slice is 135 Rust tests plus Criterion benchmark
compilation. Wiki documentation was updated at
`f5ade086ee1743113c806a3364404a8e6de593d0`.
