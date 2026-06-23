# EHDB Retrieval Receipt Stream Retention Setup

- Time: 2026-06-23T16:15:40Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/112
- PR: https://github.com/noetl/ehdb/pull/113
- Merged EHDB SHA: `c9f67cff0645edab2295a8c92b5e317adff84b5c`
- Wiki SHA: `1518d6287e981935ebfdbac5516edb94f39612ff`

## Summary

Added explicit retrieval receipt event stream retention setup helpers:

- `RetrievalContextReceiptEventStreamTarget::create_keep_all_stream`
- `RetrievalContextReceiptEventStreamTarget::create_bounded_stream`

The bounded helper rejects zero retention before touching the stream
log, then creates a stream with `RetentionPolicy::MaxRecords`.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #113.

## Boundary

This remains explicit local worker/playbook stream setup only. No
auto-create-on-publish, scheduler, automatic processing, logging sink,
network API, Arrow Flight retrieval endpoint, prompt engine, LLM
invocation, ANN index, BM25 engine, learned ranker, gateway route,
production IAM, ACL integration, retrieval daemon, distributed query
engine, gateway direct data path, or persistent per-tenant service
process was added.
