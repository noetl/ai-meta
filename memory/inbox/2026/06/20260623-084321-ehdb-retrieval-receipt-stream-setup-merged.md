# EHDB retrieval receipt event stream setup merged

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#110`
- PR: `noetl/ehdb#111`
- EHDB merge SHA: `da4ebfb98667bde853715d4aa2588b528567fb6d`
- Wiki SHA: `8126c3549014f6067d44ccbe4d74db26c2a4d38f`

Summary:

- Added explicit stream setup helpers to
  `RetrievalContextReceiptEventStreamTarget`.
- Added `stream_config` to build `StreamConfig` from target tenant,
  namespace, stream, and caller-selected retention.
- Added `create_stream` support for caller-supplied `InMemoryStreamLog`
  and `LocalJsonlStreamLog`.
- Kept setup explicit: publish helpers do not auto-create streams.
- Tests cover setup plus publish/replay, duplicate stream rejection, and
  JSONL stream persistence after reopen.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed for PR #111.

Boundary note:

- Explicit local worker/playbook stream setup only. No
  auto-create-on-publish, scheduler, automatic processing, logging
  sink, network API, Arrow Flight retrieval endpoint, prompt engine,
  LLM invocation, ANN index, BM25 engine, learned ranker, gateway route,
  production IAM, ACL integration, retrieval daemon, distributed query
  engine, gateway direct data path, or persistent per-tenant service
  process was added.
