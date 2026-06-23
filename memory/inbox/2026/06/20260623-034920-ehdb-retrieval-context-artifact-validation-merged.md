# EHDB retrieval context artifact validation merged

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#100`
- PR: `noetl/ehdb#101`
- EHDB merge SHA: `b87e4b41af872a5f82661700a5ac4c56f6ec4873`
- Wiki SHA: `359f58195c062724e79c1d811807a50f7cc766f8`

Summary:

- Added `RetrievalContextPayloadExecutionArtifacts::receipt_summary`.
- Added `RetrievalContextPayloadExecutionArtifacts::validate`.
- Artifact validation decodes the redacted receipt payload, rejects
  empty result/receipt payload arrays, rejects malformed receipts, and
  rejects result byte count mismatches between the receipt summary and
  actual result payload.
- Artifact helper paths now return validated artifacts.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed for PR #101.

Boundary note:

- Local artifact contract hardening only. No event publication, stream
  mutation, logging sink, network API, Arrow Flight retrieval endpoint,
  prompt engine, LLM invocation, ANN index, BM25 engine, learned ranker,
  gateway route, production IAM, ACL integration, retrieval daemon,
  distributed query engine, gateway direct data path, scheduler, or
  persistent per-tenant service process was added.
