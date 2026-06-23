# EHDB retrieval receipt event stream replay merged

- Date: 2026-06-23 UTC
- Repository: `noetl/ehdb`
- Issue: `noetl/ehdb#106`
- PR: `noetl/ehdb#107`
- EHDB merge SHA: `95d147df5721e943f41ab8efe1ad327cb541d3be`
- Wiki SHA: `4ae9ed850b2a15ea49ff50029120542457d6ae8d`

Summary:

- Added `RetrievalContextReceiptEventStreamRecord` carrying stream
  sequence, transaction id, and validated receipt event payload.
- Added `RetrievalContextReceiptEventStreamReadLog` for caller-supplied
  local stream logs.
- Added `RetrievalContextReceiptEventStreamTarget::replay_events`.
- Replay validates stable subject
  `ehdb.retrieval.context.execution.receipt` and event payloads through
  the existing receipt event codec.
- Tests cover ordered replay, cursor replay, JSONL reopen/replay, wrong
  subject rejection, and malformed payload rejection.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed for PR #107.

Boundary note:

- Explicit local worker/playbook replay only. No background consumer,
  subscription loop, automatic processing, logging sink, network API,
  Arrow Flight retrieval endpoint, prompt engine, LLM invocation, ANN
  index, BM25 engine, learned ranker, gateway route, production IAM,
  ACL integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added.
