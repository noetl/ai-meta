# EHDB Stream Subject-Filtered Replay

- Time: 2026-06-23T17:10:53Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/116
- PR: https://github.com/noetl/ehdb/pull/117
- Merged EHDB SHA: `70c33dc30467e6ac08f59c95b6f556074cfedc2a`
- Wiki SHA: `f4d98e9ef93dae353ac3d9d185032bcd4d47a9f5`

## Summary

Added local subject-filtered stream replay:

- `Subject::matches` supports exact matches, single-token `*`
  wildcards, and terminal `>` tail wildcards.
- `InMemoryStreamLog::replay_matching` returns retained records after
  an optional cursor and subject filter.
- `LocalJsonlStreamLog::replay_matching` delegates the same behavior
  after journal reopen.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #117.

## Boundary

This remains local explicit stream-log replay only. No durable subject
subscription, scheduler, background stream processing, NATS bridge,
network API, gateway route, distributed stream storage, production
replication, or persistent per-tenant service process was added.
