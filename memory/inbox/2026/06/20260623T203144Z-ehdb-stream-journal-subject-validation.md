# EHDB Stream Journal Subject Validation

`noetl/ehdb#125` merged on 2026-06-23 UTC as
`fe848a525dfece16ba7ad5662c277d3b1a03a3a0`, closing issue #124.

The slice validates persisted stream record subjects during local JSONL
journal replay. Replayed publish entries now re-run
`Subject::new(record.subject.as_str())` before insertion, so wildcard
concrete subjects and empty-token subjects deserialized from JSONL are
rejected instead of rebuilding invalid retained stream state.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #125

Scope boundary:

- Local stream journal replay validation only.
- No durable subject subscription, scheduler, background stream
  processing, NATS bridge, network API, gateway route, distributed
  stream storage, production replication, or persistent per-tenant
  service process was added.

Pointers:

- `repos/ehdb` should point at
  `fe848a525dfece16ba7ad5662c277d3b1a03a3a0`.
- `repos/ehdb-wiki` should point at `c628ee1`.
