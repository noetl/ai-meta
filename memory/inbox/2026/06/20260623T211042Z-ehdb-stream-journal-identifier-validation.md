# EHDB Stream Journal Identifier Validation

`noetl/ehdb#127` merged on 2026-06-23 UTC as
`97c4cd67a76f61e184a78596507ebbf7daaa4fe5`, closing issue #126.

The slice validates persisted stream journal identifiers during local
JSONL replay. Replayed stream config, create-consumer, publish, and ack
entries now re-run tenant/namespace/stream coordinate validation;
consumer names and stream record transaction IDs are also revalidated
before rebuilding retained records or consumer cursor state.

Invalid persisted identifiers fail reopen deterministically with
`EhdbError::InvalidIdentifier` instead of rebuilding invalid state or
surfacing as misleading missing-stream errors.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #127

Scope boundary:

- Local stream journal replay validation only.
- No durable subject subscription, scheduler, background stream
  processing, NATS bridge, network API, gateway route, distributed
  stream storage, production replication, or persistent per-tenant
  service process was added.

Pointers:

- `repos/ehdb` should point at
  `97c4cd67a76f61e184a78596507ebbf7daaa4fe5`.
- `repos/ehdb-wiki` should point at `252e425`.
