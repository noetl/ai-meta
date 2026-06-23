# EHDB Stream Filtered Durable Consumer Replay

- Time: 2026-06-23T17:39:07Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/118
- PR: https://github.com/noetl/ehdb/pull/119
- Merged EHDB SHA: `2062560d3b6af3929c02230f4846c16ff90a8719`
- Wiki SHA: `9c154c494de097c65ccafde843f570edf2c25980`

## Summary

Added explicit subject-filtered durable consumer replay:

- `InMemoryStreamLog::replay_matching_for_consumer`
- `LocalJsonlStreamLog::replay_matching_for_consumer`

The helper filters retained records pending after the durable consumer
ack cursor by subject without moving that cursor. Missing consumers
still return `EhdbError::NotFound`.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #119.

## Boundary

This remains local explicit stream-log replay only. No durable subject
subscription, scheduler, background stream processing, NATS bridge,
network API, gateway route, distributed stream storage, production
replication, or persistent per-tenant service process was added.
