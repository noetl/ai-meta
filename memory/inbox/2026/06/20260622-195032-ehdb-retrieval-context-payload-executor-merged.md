# EHDB retrieval context payload executor merged

Timestamp: 2026-06-23T02:50:06Z merge / 2026-06-22 local memory note

`noetl/ehdb#85` merged as
`9c494f9dd1879e6694a4dc3d0fad122f54601139`, closing issue #84:
https://github.com/noetl/ehdb/issues/84

Slice delivered a local retrieval context payload executor for the
NoETL-domain EHDB RAG track:

- `ehdb-service` now has
  `LocalRetrievalSearchService::execute_context_payload`.
- The executor decodes versioned retrieval context request payload
  bytes.
- It assembles context from replayed `LocalReferenceRuntime` retrieval
  state using the existing local context assembly boundary.
- It returns an encoded versioned retrieval context result payload.
- Malformed payloads, unsupported request versions, and invalid
  search/budget inputs are propagated deterministically.
- Coverage includes happy-path payload execution, malformed request
  payloads, unsupported request versions, invalid assembly inputs, and
  empty-result payloads.

Non-goals remain explicit: no network API, Arrow Flight retrieval
endpoint, prompt template engine, LLM invocation, ANN index, BM25
engine, learned ranker, gateway route, production IAM, retrieval
daemon, distributed query engine, gateway direct data path, or
persistent per-tenant service process.

Validation passed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage after the slice is 146 Rust tests plus Criterion benchmark
compilation. Wiki documentation was updated at
`817bb1fae04923f7fc00348a65d7d34c83e0934f`.
