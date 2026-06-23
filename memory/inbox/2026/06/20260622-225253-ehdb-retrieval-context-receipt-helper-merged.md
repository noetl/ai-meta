# EHDB retrieval context execution receipt helper merged

- UTC time: 2026-06-23T05:52:53Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/94
- PR: https://github.com/noetl/ehdb/pull/95
- EHDB merged SHA: `b5c9e23e92e32d179728ea0105274060c686f97f`
- EHDB wiki SHA: `5c64c2009eb6a02ca304acef244f07cbc84c5b97`
- ai-meta pointer update target: `repos/ehdb` -> `b5c9e23`,
  `repos/ehdb-wiki` -> `5c64c20`

Summary:

- Added `RetrievalContextPayloadExecution::encode_receipt_payload` in
  `ehdb-service`.
- The helper emits versioned
  `RetrievalContextPayloadExecutionReceiptPayload` bytes from the
  redacted execution summary.
- Tests prove helper-produced receipts decode back to the same summary
  returned by local execution.
- Tests prove helper-produced receipts exclude tenant IDs, namespace
  values, query text, chunk text, tokens, embedding vectors, payload
  bytes, object paths, and principals.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace` (162 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary:

- This remains local worker/playbook helper wiring only.
- No event publication, stream mutation, logging sink, network API,
  Arrow Flight retrieval endpoint, prompt engine, LLM invocation, ANN
  index, BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant process was
  added.
