# EHDB Stream Positive Retention Validation

- Time: 2026-06-23T16:29:28Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/114
- PR: https://github.com/noetl/ehdb/pull/115
- Merged EHDB SHA: `b70cf038acd4c9ec2455c2b24aacad021bf3c247`
- Wiki SHA: `b4cee2b654e10da2e93cdc57cdad5d07ecac3b1d`

## Summary

Enforced positive bounded stream retention at the core stream log
boundary:

- `InMemoryStreamLog::create_stream` rejects
  `RetentionPolicy::MaxRecords(0)`.
- `LocalJsonlStreamLog::create_stream` rejects
  `RetentionPolicy::MaxRecords(0)` before writing a journal entry.
- JSONL reopen tests prove rejected zero-retention stream configs are
  not persisted.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #115.

## Boundary

This remains local stream log validation only. No scheduler, background
stream processing, NATS bridge, network API, gateway route, distributed
stream storage, production replication, or persistent per-tenant service
process was added.
