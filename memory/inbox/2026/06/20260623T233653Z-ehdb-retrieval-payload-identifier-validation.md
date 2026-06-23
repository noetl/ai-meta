# EHDB Retrieval Payload Identifier Validation

`noetl/ehdb#133` merged on 2026-06-23 UTC as
`4261d3ed8d4039b33d53a4241d18cb78b11368f5`, closing issue #132.

The slice validates retrieval context payload identifiers during local
RAG payload encode/decode. `RetrievalContextRequestPayload` now
revalidates tenant, namespace, and embedding model identifiers;
`RetrievalContextResultPayload` revalidates chunk, document, and
embedding model identifiers for each context block.

Invalid decoded identifiers fail before worker/playbook execution or
handoff.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #133

Scope boundary:

- Local RAG payload codec validation only.
- No ANN index, retrieval daemon, RPC protocol, Arrow Flight retrieval
  endpoint, gateway data-touch behavior, prompt/LLM invocation,
  background processing, scheduler behavior, or persistent per-tenant
  service process was added.

Pointers:

- `repos/ehdb` should point at
  `4261d3ed8d4039b33d53a4241d18cb78b11368f5`.
- `repos/ehdb-wiki` should point at `55c0fa5`.
