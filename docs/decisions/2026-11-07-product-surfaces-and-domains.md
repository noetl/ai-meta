# Decision: NoETL product surfaces and domains

- **Date:** 2026-11-07
- **Status:** Accepted (a map of surfaces; it ships nothing on its own)
- **Related:** [`docs/rfc/dsl-knowledge-base.md`](../rfc/dsl-knowledge-base.md) (#542),
  [`docs/rfc/interop-topology-and-ai-mcp-playbooks.md`](../rfc/interop-topology-and-ai-mcp-playbooks.md) (#539)

## Context

Several surfaces were being discussed under overlapping names: docs, the AI service, the
control-plane GUI and a future cloud. This record fixes one map, so that every session and every
agent uses the same model.

## Decision

| Surface | Domain | Repo | What it is | State |
|---|---|---|---|---|
| Documentation | **noetl.dev** | noetl/docs (Docusaurus) | Human documentation only. Its generated DSL reference is rendered from release artifacts. | Live |
| DSL knowledge base (AI/service surface) | **noetl.ai** | **noetl/noetl.ai** | The shared, version-accurate KB generated from orchestrate-core: schema, tool kinds, validate, MCP, plus a read-only KB explorer. Both machines and the console consume it as the single source of truth. | First slice live on noetl.ai (2026-11-07). The live `/api/dsl/*` upstream is gated. |
| Control-plane GUI + human generation console | **console.noetl.ai** | **noetl/gui** | The deployable control-plane dashboard on the GCP gateway. It is also the home of the **human prompt/spec → playbook generation console**, a client of noetl.ai's KB/validate/MCP API. | Live dashboard; the generation console is a later workstream |
| Waitlist / feedback | **www.noetl.io/waitlist/** | noetl/noetl.io | Moved from the noetl.ai landing page; the same `WAITLIST` KV store | Live (noetl.io#8) |
| Community / open cloud | **noetl.cloud** | none | A customer console to register their own NoETL servers, provision resources under the NoETL control plane, run playbooks and integrate services. | **Future.** Not built. The domain is reported available, not yet acquired. |
| Commercial cloud | **saqbit.com** | none (for this surface) | The same scope as noetl.cloud, as a fully commercial SaaS. | **Future.** Not built. saqbit.com currently hosts the quantum demo. |

## Consequences

- **The cloud surfaces are a separate track.** noetl.cloud and saqbit.com are a future track,
  built on the interop RFC (topology, registration, remote tasks, MCP) and the DSL KB. They are
  out of scope for current work, and nothing for them gets built until they are scoped.
- **noetl.ai is not the cloud.** It must not grow server registration or provisioning. Those
  belong to the cloud surfaces.
- **The KB lives once, in noetl.ai.** noetl/gui hosts the human generation console, but never a
  copy of the KB. The console calls noetl.ai's API.
- **noetl.dev stays docs-only.** Anything interactive or programmatic links to noetl.ai.
