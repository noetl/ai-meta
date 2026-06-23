# EHDB bounded retrieval context payload execution merged

Timestamp: 2026-06-23T03:46:51Z merge / 2026-06-22 local memory note

`noetl/ehdb#87` merged as
`854dae3417ec182313666f022059c62286c86fbb`, closing issue #86:
https://github.com/noetl/ehdb/issues/86

Slice delivered bounded local retrieval context payload execution for
the NoETL-domain EHDB RAG track:

- `ehdb-service` now has `RetrievalContextPayloadExecutorConfig`.
- The config validates positive max request and max result payload byte
  limits.
- Default local-reference limits are 1 MiB request payloads and 4 MiB
  result payloads.
- `LocalRetrievalSearchService::execute_context_payload_with_config`
  rejects oversized request payloads before JSON decode.
- Encoded result payloads are checked before bytes are returned.
- The existing `execute_context_payload` convenience method uses the
  default config.
- Coverage includes default config, invalid config, oversized request
  payloads, oversized result payloads, and happy-path configured
  execution.

Non-goals remain explicit: no network API, Arrow Flight retrieval
endpoint, prompt template engine, LLM invocation, ANN index, BM25
engine, learned ranker, gateway route, production IAM, retrieval
daemon, distributed query engine, gateway direct data path, scheduler,
or persistent per-tenant service process.

Validation passed before merge:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Coverage after the slice is 150 Rust tests plus Criterion benchmark
compilation. Wiki documentation was updated at
`7c0073ce3321757aaff521c307fb6e4dabf94c8e`.
