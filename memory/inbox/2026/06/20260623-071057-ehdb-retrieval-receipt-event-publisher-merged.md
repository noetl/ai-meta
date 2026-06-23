# EHDB retrieval receipt event stream publisher merged

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#104`
- PR: `noetl/ehdb#105`
- EHDB merge SHA: `0d2c1bed33d43b0a541c7335c6be79795054d613`
- Wiki SHA: `f1f195ffb5b835b6be32dd1e68c85bc0b18bb310`

Summary:

- Added `RetrievalContextReceiptEventStreamTarget` for caller-owned
  tenant, namespace, and stream name.
- Added `RetrievalContextReceiptEventStreamLog` as an explicit local
  publisher contract.
- Implemented publisher support for `InMemoryStreamLog` and
  `LocalJsonlStreamLog`.
- Published validated receipt event payloads under stable subject
  `ehdb.retrieval.context.execution.receipt`.
- Required caller-supplied mutable stream log and transaction id.
- Tests cover in-memory publish/replay, JSONL persist/reopen/replay,
  missing stream errors, and malformed artifact rejection.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed for PR #105.

Boundary note:

- Explicit local worker/playbook publication only. No automatic stream
  publication, background task, logging sink, network API, Arrow Flight
  retrieval endpoint, prompt engine, LLM invocation, ANN index, BM25
  engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added.
