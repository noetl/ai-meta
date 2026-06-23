# EHDB System Journal Identifier Validation

`noetl/ehdb#131` merged on 2026-06-23 UTC as
`243d78eb41cb1f7f33426147203a33c3afd40e64`, closing issue #130.

The slice validates persisted system-library journal identifiers during
local JSONL replay. Replayed publish entries now revalidate library
path, revision, digest, object path, and transaction ID before
rebuilding immutable WASM manifests.

Replayed bind entries revalidate tenant, namespace, environment,
channel, path, revision, digest, and transaction ID before rebuilding
hot-replaceable environment/channel bindings.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #131

Scope boundary:

- Local system-library journal replay validation only.
- No WASM execution, background processing, network API, gateway
  data-touch behavior, production replication, scheduler behavior, or
  persistent per-tenant service process was added.

Pointers:

- `repos/ehdb` should point at
  `243d78eb41cb1f7f33426147203a33c3afd40e64`.
- `repos/ehdb-wiki` should point at `6c95770`.
