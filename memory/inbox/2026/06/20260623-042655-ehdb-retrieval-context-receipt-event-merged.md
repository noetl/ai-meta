# EHDB retrieval context receipt event payload merged

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#102`
- PR: `noetl/ehdb#103`
- EHDB merge SHA: `cebcf2f2ee2116e8559327a33332009eb93a5ca9`
- Wiki SHA: `2feaf2da5d649c80fc422d22ced2c6221cf9a57b`

Summary:

- Added `RetrievalContextPayloadExecutionReceiptEventPayload`.
- Added stable subject
  `ehdb.retrieval.context.execution.receipt`.
- Added artifact helpers to build and encode receipt event payloads
  from validated `RetrievalContextPayloadExecutionArtifacts`.
- Event payload decode validates embedded receipt bytes through the
  existing receipt codec.
- Invalid cases reject empty receipt bytes, malformed receipts, and
  unsupported event envelope versions.
- The event envelope excludes result payload/context bytes.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed for PR #103.

Boundary note:

- Local stream-ready payload modeling only. No automatic stream
  publication, stream mutation, logging sink, network API, Arrow Flight
  retrieval endpoint, prompt engine, LLM invocation, ANN index, BM25
  engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added.
