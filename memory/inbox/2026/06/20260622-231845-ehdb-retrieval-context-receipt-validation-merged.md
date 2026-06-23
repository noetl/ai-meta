# EHDB retrieval context receipt summary validation merged

- UTC time: 2026-06-23T06:18:45Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/96
- PR: https://github.com/noetl/ehdb/pull/97
- EHDB merged SHA: `8fff5535f2e13de9b322bdd6fe6b514e8cdad132`
- EHDB wiki SHA: `aaa6335efb371dd264a5ab7145d0e8ffc3cae94c`
- ai-meta pointer update target: `repos/ehdb` -> `8fff553`,
  `repos/ehdb-wiki` -> `aaa6335`

Summary:

- Added `RetrievalContextPayloadExecutionSummary::validate`.
- Receipt summaries now require positive request/result payload byte
  counts.
- Receipt summaries reject non-zero total text chars when context block
  count is zero.
- `RetrievalContextPayloadExecutionReceiptPayload::encode` and
  `decode` both validate the redacted summary.
- Execution-produced and helper-produced receipts remain compatible.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace` (165 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary:

- This remains local receipt contract hardening only.
- No event publication, stream mutation, logging sink, network API,
  Arrow Flight retrieval endpoint, prompt engine, LLM invocation, ANN
  index, BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant process was
  added.
