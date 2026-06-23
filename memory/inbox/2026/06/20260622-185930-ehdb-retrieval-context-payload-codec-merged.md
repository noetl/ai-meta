# EHDB retrieval context payload codec merged

Timestamp: 2026-06-23T01:58:58Z merge / 2026-06-22 local memory note

`noetl/ehdb#83` merged as
`41ab8357e37255cf2668b998f0f728787c256e47`, closing issue #82:
https://github.com/noetl/ehdb/issues/82

Slice delivered a local retrieval context payload codec for the
NoETL-domain EHDB RAG track:

- `ehdb-service` now has `RetrievalContextRequestPayload` and
  `RetrievalContextResultPayload`.
- Payloads wrap local context assembly requests/results in explicit
  versioned JSON byte envelopes.
- `AssembleRetrievalContextRequest`, `RetrievalContextBlock`, and
  `RetrievalContext` now derive serialization for the payload boundary.
- Malformed JSON and unsupported request/result versions are rejected
  deterministically before execution or handoff.
- Coverage includes request payload round-trip, assembled result
  payload round-trip, malformed payloads, and unsupported versions.

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

Coverage after the slice is 143 Rust tests plus Criterion benchmark
compilation. Wiki documentation was updated at
`3ae0c70c155a559b5166794d60a58d82148814f3`.
