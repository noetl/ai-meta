# EHDB bounded retrieval context execution artifacts merged

- UTC time: 2026-06-23T10:28:37Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/98
- PR: https://github.com/noetl/ehdb/pull/99
- EHDB merged SHA: `c0613881814643cf284bf0ee24f3d7cfb43444a3`
- EHDB wiki SHA: `235229bfb291f76d0ef0e5ae999ddb6b6f812a07`
- ai-meta pointer update target: `repos/ehdb` -> `c061388`,
  `repos/ehdb-wiki` -> `235229b`

Summary:

- Added `DEFAULT_RETRIEVAL_CONTEXT_MAX_RECEIPT_PAYLOAD_BYTES`.
- Added `max_receipt_payload_bytes` to
  `RetrievalContextPayloadExecutorConfig`.
- Added `RetrievalContextPayloadExecutionArtifacts` carrying result
  payload bytes and redacted receipt payload bytes.
- Added default, configured, and scope-aware artifact helpers for local
  retrieval context payload execution.
- Existing byte-returning, summary-returning, scope, and receipt APIs
  remain behavior-compatible.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace` (168 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary:

- This remains local worker/playbook handoff wiring only.
- No event publication, stream mutation, logging sink, network API,
  Arrow Flight retrieval endpoint, prompt engine, LLM invocation, ANN
  index, BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant process was
  added.
