# EHDB retrieval context assembly merged

Timestamp: 2026-06-23T01:30:37Z merge / 2026-06-22 local memory note

`noetl/ehdb#81` merged as
`fccbbe19e1046dadb6323bdafa26230cd4512c11`, closing issue #80:
https://github.com/noetl/ehdb/issues/80

Slice delivered the local retrieval context assembly boundary for the
NoETL-domain EHDB RAG track:

- `ehdb-service` now has `AssembleRetrievalContextRequest`,
  `RetrievalContextBlock`, and `RetrievalContext`.
- `LocalRetrievalSearchService::assemble_context` builds on replayed
  local hybrid search hits.
- Context blocks preserve chunk id, document id, ordinal, checksum,
  clipped text, original text length, embedding model metadata, vector
  score, text match count, and combined score.
- The result reports total text characters and truncation state.
- The boundary validates positive per-block and total text budgets and
  inherits hybrid search validation for hit limits, query vectors, text
  query, and weights.
- Coverage includes ordered assembly, budget clipping, empty results,
  validation, and tenant/namespace scoping.

Non-goals remain explicit: no ANN index, BM25 engine, learned ranker,
prompt template engine, LLM invocation, network service, gateway route,
production IAM, external search adapter, distributed query engine,
retrieval daemon, gateway direct data path, or persistent per-tenant
service process.

Validation passed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage after the slice is 139 Rust tests plus Criterion benchmark
compilation. Wiki documentation was updated at
`15301e2caa954bcd93d070f8ec8b2da51289871e`.
