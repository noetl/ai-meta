# Future direction: Gemini / Vertex AI MCP pointer swap for GKE deployments

**Date filed**: 2026-05-06
**Status**: Captured / not started
**Origin**: User note during 20260506-040838 wrap-up round
**Related**: bridge/outbox/event_projection_audit.md, docs/architecture/triage_model_selection.md, noetl#405 (MCP-as-playbook)

## The ask

When NoETL runs on GKE Google Cloud, the auto-troubleshoot diagnose
path should be able to use Google's Gemini API or Vertex AI as the
model backend, replacing the in-cluster Ollama deployment.
Playbooks should support pointer-swapping so the same
`diagnose_execution.yaml` works in both modes (local Ollama, cloud
Vertex/Gemini) with different operator config.

## Why this fits NoETL's existing architecture

The MCP-as-playbook pattern (Gap 2 / noetl#405) was specifically
designed to decouple "what tool the agent calls" from "where that
tool runs." Today's `diagnose_execution.yaml` references
`mcp/ollama` as the MCP server proxying Ollama. Substituting
`mcp/vertex-ai` (or `mcp/gemini`) is a configuration change, not an
architecture change — provided the new MCP server playbook
implements the same JSON-RPC tools/list + tools/call contract.

## Implementation outline

This is a sketch, not a plan. Refining it is the first step of the
work.

1. **`repos/ops/automation/agents/mcp/vertex-ai.yaml`** (or similar
   name). MCP server playbook proxying to Vertex AI's
   GenerateContent API. Implements the same JSON-RPC contract as
   the existing ollama-bridge MCP. Tools: `chat_completion`
   (matches what diagnose_execution calls today). Credential
   surface: Workload Identity preferred, service-account JSON
   fallback, both via NoETL's credential resolution.

2. **`repos/ops/automation/agents/mcp/gemini.yaml`** (alternative
   variant). Same shape as vertex-ai but using the Gemini API
   directly with an API key credential. Cheaper and simpler; less
   integrated with GCP IAM. Operator picks one based on
   deployment style.

3. **Update `diagnose_execution.yaml`** — rename
   `workload.ollama_mcp_server` → `workload.triage_mcp_server`
   (signals that any compatible MCP backend is valid). Default
   stays `mcp/ollama` for backward compatibility. Operators
   override to `mcp/vertex-ai` or `mcp/gemini` for cloud
   deployments.

4. **Model name mapping**. Document the equivalences:
   - `gemma3:4b` (local default) ↔ `gemini-2.0-flash` (cloud
     default for triage)
   - `qwen3:32b` (local escalation) ↔ `gemini-2.0-pro` or
     `gemini-2.5-pro` (cloud escalation)
   - Operator can pin specific model names per deployment.
   The mapping is operator-controlled; the playbook just passes
   the model name through.

5. **`docs/architecture/triage_model_selection.md`** — add a
   "Deployment mode: in-cluster Ollama vs cloud-managed Vertex /
   Gemini" section. Include credential model, latency/cost
   tradeoffs, data-residency notes (Vertex AI keeps data in GCP;
   Ollama in-cluster keeps it in the cluster's network boundary;
   Gemini API depends on the data-handling agreement at API-key
   level).

6. **Smoke for the new MCP playbook**. Static fixture validating
   the JSON-RPC tools/list + tools/call shape against a canned
   Vertex AI response. Lives alongside the existing 5 smokes in
   ai-meta/scripts/.

7. **Regression sweep update**. The 8-bucket regression sweep
   pattern from the v2.35.8 round needs an additional bucket for
   "MCP backend pointer swap": invoke diagnose_execution once
   with mcp/ollama and once with mcp/vertex-ai (or canned mock
   for CI), confirm both return valid envelopes with the same
   shape contract.

## Open design questions

- **Naming convention**: `triage_mcp_server` vs
  `model_mcp_server` vs leaving it as `ollama_mcp_server` with
  implicit-pointer semantics. The first is clearest; the third
  preserves backward compatibility but obscures intent. Probably
  ship with the rename + a deprecation alias for one release
  cycle.

- **Credential surface unification**. Vertex AI uses Workload
  Identity / GKE metadata server. Gemini API uses an API key.
  AWS Bedrock (likely a future request) uses IAM roles. The MCP
  playbook should encapsulate the credential pattern behind the
  JSON-RPC interface so the troubleshoot agent doesn't branch on
  backend type.

- **Discriminated default**. Should `diagnose_execution.yaml`
  detect deployment context (`KUBERNETES_SERVICE_HOST` +
  cloud-provider metadata) and pick a default automatically? OR
  require explicit operator override? Strong vote for explicit:
  defaults that change by environment are a debugging
  nightmare.

- **Cost telemetry**. Cloud-managed inference is metered. The
  diagnose path runs on every agent failure. Should the playbook
  track per-execution token usage and surface it in the
  envelope's `data` field for cost tracking? Worth specifying
  upfront to avoid retrofit.

- **Streaming vs non-streaming**. Vertex AI supports streaming
  responses; the current Ollama bridge is non-streaming. Stick
  with non-streaming for the diagnose path (simpler, lower
  variance, matches today's behavior). Streaming is a separate
  feature for chat-style use cases.

## Effort estimate

Rough. Not a commitment.

- Design doc + sync sign-off: ~half day.
- vertex-ai MCP playbook + smoke: ~1 day.
- diagnose_execution rename + alias + tests: ~half day.
- Docs additions: ~half day.
- Regression bucket: ~half day.
- End-to-end validation in a real GKE cluster (separate from kind):
  ~1 day if we have a GKE cluster on hand, more if we have to
  provision one.

Total: ~3-4 days of focused work, plus GKE-side validation.

## Filed-for-later, not blocking

This doesn't gate any currently-shipping work. v2.35.9 is
production-ready for in-cluster Ollama deployments. GKE
deployments with cloud-managed inference are a separate path; this
note captures the design direction so it's not lost.

## When to start

Pick this up when:
- A GKE deployment is on the near roadmap, OR
- Someone asks about cost/latency of Ollama-in-cluster vs
  cloud-managed inference, OR
- A second cloud provider request shows up (e.g. Anthropic
  on-AWS, OpenAI Azure), making the "configurable triage backend"
  investment more obviously justified by N>1.
