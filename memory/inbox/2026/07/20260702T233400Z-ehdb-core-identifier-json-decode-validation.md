# EHDB Core Identifier JSON Decode Validation

Date: 2026-07-02 UTC

Issue:
- `noetl/ehdb#226` — Validate core identifier JSON decode semantics

Merged PR:
- `noetl/ehdb#227` — `fix: validate core identifier JSON decode`

Pointers:
- `repos/ehdb` should point at
  `6a875c70b0d25f038bef73a2ebdaa776a5e9c922`.
- `repos/ehdb-wiki` should point at
  `698cf292d1fe634d99f9d9d56a5c690ce644656c`.

Summary:
- Core identifier newtypes now deserialize JSON through their
  constructors instead of accepting raw strings from derived
  deserialization.
- The existing string JSON shape is preserved for valid identifiers.
- Malformed tenant, namespace, table, transaction, stream, retrieval,
  and related identifiers are rejected during JSON decode before
  metadata is accepted.
- Service payload decoders and JSONL replay boundaries keep malformed
  identifiers classified as `EhdbError::InvalidIdentifier` while
  preserving storage/state errors for corrupt or unknown-field payloads.

Boundary:
- This is core identifier JSON decode validation only.
- No schema evolution, type coercion, SQL planning, predicate pushdown,
  distributed execution, gateway direct reads, production IAM/ACL
  behavior, object movement, or persistent per-tenant service process
  was added.

Validation:
- `cargo fmt --all --check`
- `cargo test --workspace` — 254 Rust tests
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

