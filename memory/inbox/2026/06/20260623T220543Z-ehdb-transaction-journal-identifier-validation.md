# EHDB Transaction Journal Identifier Validation

`noetl/ehdb#129` merged on 2026-06-23 UTC as
`5aa284228eecb877f36e02d701da1168ce4aaa55`, closing issue #128.

The slice validates persisted transaction journal identifiers during
local JSONL replay. Replayed transaction envelopes now re-run
transaction ID, tenant, and namespace validation; catalog, stream,
retrieval, system-library, and storage mutation identifiers are also
revalidated before insertion.

Stream publish subjects inside transaction mutations are revalidated as
concrete subjects, and corrupted persisted transaction records fail
reopen deterministically instead of entering ordered replay state.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #129

Scope boundary:

- Local transaction-log replay validation only.
- No consensus engine, background processing, network API, gateway
  data-touch behavior, production replication, scheduler behavior, or
  persistent per-tenant service process was added.

Pointers:

- `repos/ehdb` should point at
  `5aa284228eecb877f36e02d701da1168ce4aaa55`.
- `repos/ehdb-wiki` should point at `e32cd7c`.
