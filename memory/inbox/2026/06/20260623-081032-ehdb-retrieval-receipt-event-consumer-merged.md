# EHDB retrieval receipt event durable consumers merged

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#108`
- PR: `noetl/ehdb#109`
- EHDB merge SHA: `ff12df09cdd3f9c4398a813bb88b7d2c4ac4c8e8`
- Wiki SHA: `8bbfa387188a4d9eede05b255d37fd8b73885280`

Summary:

- Added `RetrievalContextReceiptEventDurableConsumerLog`.
- Added target helpers to create durable consumers, replay pending
  validated receipt events for a consumer, and ack receipt event
  sequences.
- Implemented support for caller-supplied `InMemoryStreamLog` and
  `LocalJsonlStreamLog` instances.
- Replay keeps validating the stable subject
  `ehdb.retrieval.context.execution.receipt` and receipt event payload.
- Tests cover consumer resume/ack behavior, ack rollback rejection,
  missing consumer rejection, and JSONL reopen cursor behavior.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed for PR #109.

Boundary note:

- Explicit local worker/playbook consumer control only. No background
  consumer, subscription loop, scheduler, automatic processing, logging
  sink, network API, Arrow Flight retrieval endpoint, prompt engine,
  LLM invocation, ANN index, BM25 engine, learned ranker, gateway route,
  production IAM, ACL integration, retrieval daemon, distributed query
  engine, gateway direct data path, or persistent per-tenant service
  process was added.
