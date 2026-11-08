# Decision: The DSL knowledge base is generated from orchestrate-core and served by the running server

- **Date:** 2026-11-07
- **Status:** Proposed (Phase 1 in review as a server PR; `NOETL_DSL_KB` is not armed anywhere)
- **RFC:** [`docs/rfc/dsl-knowledge-base.md`](../rfc/dsl-knowledge-base.md)
- **Coordinates with:** [`docs/rfc/interop-topology-and-ai-mcp-playbooks.md`](../rfc/interop-topology-and-ai-mcp-playbooks.md)
  (ai-meta#539), which owns the MCP endpoint and worker `capabilities` registration.

## Context

- **Two models, one published schema.** The server's playbook grammar is the set of Rust types
  in `noetl-orchestrate-core` (`playbook.rs`). The only published JSON Schema comes from a
  different model: the CLI's `noetl-executor` (ai-meta#201), where `tool.kind` is an open string.
  A schema can therefore validate playbooks the server rejects.
- **No executor list.** No component knows which tool kinds can actually execute. The server
  knows what parses. Workers know what they registered, but they don't report it.
- **No parse at registration.** Catalog registration does not run `parse_playbook`, so grammar
  errors surface only at execute time.

## Decision

1. **The source of truth is orchestrate-core.** The grammar schema is derived with `schemars`
   from the orchestrate-core authoring types, behind an optional `json-schema` feature. The
   server enables it; the wasm32 orchestrate plug-in does not.
2. **The served schema reflects the running process.** `tool.kind` is a closed enum, narrowed to
   `ToolKindGates::current()` at emit time. Elsewhere the schema is permissive, matching the
   parser.
3. **The digest is the version.** The SHA-256 of the canonical gated schema identifies the
   grammar. It is the `ETag`, and it is stamped on every response together with the server and
   core versions and the gate states.
4. **Artifacts are generated, never edited.** The schema and manifest are committed under
   `orchestrate-core/schema/`. A test regenerates them and fails on any difference.
5. **Executability is reported, not asserted.** "Available now" is the parser-accepted set
   intersected with the tool kinds that *live* workers report (interop RFC Phase 3). Until
   workers report, the API says `not_reported`; it does not guess.
6. **A validator runs the real code.** `POST /api/dsl/validate` (Phase 2) is the register path
   without the insert, plus `parse_playbook`. Registration converges on it through `off → shadow
   → enforce`.
7. **Served over the API, behind a flag.** `/api/dsl/*` is read-only and mounted only when
   `NOETL_DSL_KB=true`. The MCP exposure rides the interop RFC's endpoint as fixed helper tools.

8. **Surfaces by domain.** noetl.dev is docs only. noetl.ai is the service: the AI/programmatic
   face and the human generation face, both clients of the same KB and validator. It lives in
   the new repo **noetl/noetl.ai** (preview `noetl-ai-kb.pages.dev`). noetl/gui stays the
   control-plane GUI. Moving the live noetl.ai domain off the gui landing/waitlist page is a
   separate, user-approved cutover.

## Consequences

- No prod change. The flag is absent from every manifest. With it off, no route is mounted and
  runtime behaviour is unchanged.
- A grammar change that forgets to regenerate the artifact fails CI.
- The CLI's schema becomes a second artifact to converge (RFC Phase 4). Until then, two schemas
  exist, and the server's is the authoritative one.
- New tool kinds follow the server#560 pattern: gated and off. The KB shows them as `gated_off`,
  then `accepted_not_executable`, then `available`, so AIs never see a kind before it can run.
- Rollback: unset `NOETL_DSL_KB` and restart.
