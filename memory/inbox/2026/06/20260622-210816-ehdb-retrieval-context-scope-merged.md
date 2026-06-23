# EHDB retrieval context payload scope guard merged

Timestamp: 2026-06-23T04:07:39Z merge / 2026-06-22 local memory note

`noetl/ehdb#89` merged as
`b2c36d111921b8e1ba7bc491aaa47dd61cefecad`, closing issue #88:
https://github.com/noetl/ehdb/issues/88

Slice delivered a local retrieval context payload scope guard for the
NoETL-domain EHDB RAG track:

- `ehdb-service` now has `RetrievalContextPayloadScope`.
- Scope validation checks decoded context assembly request tenant and
  namespace against the expected worker/playbook execution scope before
  context assembly.
- `LocalRetrievalSearchService::execute_context_payload_with_scope`
  composes the existing request/result byte bounds with the new scope
  check.
- Existing default and config-aware payload execution are unchanged.
- Coverage includes matching scope, tenant mismatch, namespace
  mismatch, malformed payload propagation, and oversized request
  propagation.

Non-goals remain explicit: no production IAM, policy engine, ACL
integration, network API, Arrow Flight retrieval endpoint, prompt
template engine, LLM invocation, ANN index, BM25 engine, learned ranker,
gateway route, retrieval daemon, distributed query engine, gateway
direct data path, scheduler, or persistent per-tenant service process.

Validation passed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage after the slice is 153 Rust tests plus Criterion benchmark
compilation. Wiki documentation was updated at
`40d38057dc5edfa7b1ab0a6c9042f7ab25c4a773`.
