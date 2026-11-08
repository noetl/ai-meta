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
| DSL knowledge base + generation | **noetl.ai** | **noetl/noetl.ai** | Two faces over one version-accurate KB generated from orchestrate-core, with validate-before-register: (1) the programmatic/AI API (schema, tool kinds, validate, MCP); (2) a human prompt/spec → playbook console. | Scaffolded. The preview is `noetl-ai-kb.pages.dev`. The live domain still serves the noetl/gui `landing/` waitlist until a gated cutover. |
| Control-plane GUI | **console.noetl.ai** | **noetl/gui** | The deployable dashboard for the NoETL control plane, talking to the GCP gateway. | Live, and it stays the control-plane dashboard |
| Community / open cloud | **noetl.cloud** | none | A customer console to register their own NoETL servers, provision resources under the NoETL control plane, run playbooks and integrate services. | **Future.** Not built. The domain is reported available, not yet acquired. |
| Commercial cloud | **saqbit.com** | none (for this surface) | The same scope as noetl.cloud, as a fully commercial SaaS. | **Future.** Not built. saqbit.com currently hosts the quantum demo. |

## Consequences

- **The cloud surfaces are a separate track.** noetl.cloud and saqbit.com are a future track,
  built on the interop RFC (topology, registration, remote tasks, MCP) and the DSL KB. They are
  out of scope for current work, and nothing for them gets built until they are scoped.
- **noetl.ai is not the cloud.** It must not grow server registration or provisioning. Those
  belong to the cloud surfaces.
- **The gui stays the control plane's GUI.** noetl/gui is not the home of the KB or of
  generation features.
- **noetl.dev stays docs-only.** Anything interactive or programmatic links to noetl.ai.
