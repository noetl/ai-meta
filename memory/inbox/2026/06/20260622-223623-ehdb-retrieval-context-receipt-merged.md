# EHDB retrieval context execution receipt codec merged

- UTC time: 2026-06-23T05:36:23Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/92
- PR: https://github.com/noetl/ehdb/pull/93
- EHDB merged SHA: `c997be8a32bb737a12579c16dfab30c2c4da1f8d`
- EHDB wiki SHA: `a2467a0a242b365f8c24a84de20d0387150fc95c`
- ai-meta pointer update target: `repos/ehdb` -> `c997be8`,
  `repos/ehdb-wiki` -> `a2467a0`

Summary:

- Added `RETRIEVAL_CONTEXT_EXECUTION_RECEIPT_VERSION`.
- Added `RetrievalContextPayloadExecutionReceiptPayload` in
  `ehdb-service`.
- Made `RetrievalContextPayloadExecutionSummary` serializable so the
  receipt can carry only redacted summary fields.
- Receipt payloads round-trip through versioned JSON bytes and reject
  malformed JSON or unsupported versions.
- Tests prove encoded receipts exclude tenant IDs, namespace values,
  query text, chunk text, tokens, embedding vectors, payload bytes,
  object paths, and principals.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace` (160 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary:

- This remains a durable receipt shape for future event-log/audit
  plumbing in local worker/playbook tests only.
- No event publication, stream mutation, logging sink, network API,
  Arrow Flight retrieval endpoint, prompt engine, LLM invocation, ANN
  index, BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant process was
  added.
