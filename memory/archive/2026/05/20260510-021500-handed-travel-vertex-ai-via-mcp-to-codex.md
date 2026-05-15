# Handed travel vertex-ai Phase 3 to Codex (third provider via MCP playbook hop)

- date: 2026-05-10T02:15:00Z
- tags: travel-agent, vertex-ai, mcp-playbook, phase-3, agent-hop, codex-handoff

## Round goal

Add `vertex-ai` as the third provider for the travel agent's intent classification,
routing it through the existing `automation/agents/mcp/vertex-ai` MCP playbook via
`tool: agent framework: noetl` — mirroring Phase 2's Amadeus hop pattern that just
closed GREEN.

The travel agent stays thin: it dispatches. The MCP playbook owns GCP auth
(Workload Identity / metadata server / GOOGLE_OAUTH_ACCESS_TOKEN /
GOOGLE_APPLICATION_CREDENTIALS service-account JWT). One MCP playbook,
two callers — the travel agent AND any external MCP client speaking JSON-RPC to
`/api/mcp/playbook/automation/agents/mcp/vertex-ai/jsonrpc`.

## Why Option B (route through the MCP playbook), not Option A (direct urllib)

- Option A would require absorbing GCP auth complexity into the travel runtime
  (a `gcp_access_token` keychain kind, ADC handling, etc.) — exactly what was
  flagged as the deferral reason after the multi-provider round.
- The work is already done: `automation/agents/mcp/vertex-ai` ships a complete
  chat_completion MCP surface with full auth fallbacks. Reusing it is the natural
  Phase 3 move after Phase 2 proved the agent → MCP hop pattern is load-bearing.
- "MCP is just a playbook" thesis applied a second time, this time to AI providers
  rather than tool integrations.

## Three-branch refactor of classify_intent

1. RENAME current `classify_intent` → `classify_via_http_provider`
   (still kind:python, still handles openai+anthropic via urllib — body unchanged).

2. ADD `classify_via_vertex_mcp`:
   ```yaml
   tool:
     kind: agent
     framework: noetl
     entrypoint: automation/agents/mcp/vertex-ai
     payload:
       method: tools/call
       tool: chat_completion
       arguments:
         messages: [{role: user, content: "{{ workload.query }}"}]
         system: <classifier system prompt>
         temperature: 0
         vertex_project: ...
         vertex_region:  ...
         vertex_model:   gemini-2.5-flash
   ```

3. ADD a small kind:python merger named `classify_intent` (downstream Jinja keeps
   referencing classify_intent.X — contract preserved). Reads both upstreams via
   `default({})`, normalises vertex envelope into canonical shape, and falls back
   to openai via urllib if vertex returned isError or empty text.

start.next.arcs uses mode: exclusive and dispatches via `when:` predicates on
workload.ai_provider. Both classify_via_* branches arc into the merger; the
merger arcs into log_classification. Everything downstream of log_classification
is unchanged.

## Workload additions

- `vertex_project: "{{ workload.gcp_project }}"` (default — reuse existing field)
- `vertex_region: "us-central1"`
- `vertex_model: "gemini-2.5-flash"`
- ai_provider comment: `# openai | anthropic | vertex-ai`
- metadata.capabilities += `ai:vertex-ai`

No new keychain entry needed — vertex auth is handled inside the MCP playbook.

## Phases (8)

1. Validate design (apply edits; Pydantic-validate; confirm vertex-ai MCP playbook
   is in catalog — used already by troubleshoot/diagnose_execution.yaml).
2. Ops PR: feat(travel-agent): add Vertex AI as third provider via the Vertex AI
   MCP playbook (agent → MCP hop).
3. Docs PR: tutorial 07 Step 3 — extend provider switch + Phase 3 paragraph + jq
   snippet.
4. Re-register travel runtime (catalog v14 expected).
5. Terminal smokes — travel --provider vertex-ai help/flights/locations. Each
   MUST produce effective_provider='vertex-ai' AND classify_via_vertex_mcp event
   with tool_kind='agent' + sub_execution_id present. Screenshot widgets.
6. Regression — travel help (openai default) and travel --provider anthropic help
   (still falls back to openai per the deferred Anthropic secret state).
7. External MCP regression — cd /mcp/vertex-ai; cd /mcp/amadeus. Both intact.
8. Ai-meta pointer bumps. Stage but do not push.

## What could fall over

- The GCP service account or Workload Identity might lack `roles/aiplatform.user`
  on the noetl-cluster project — vertex MCP returns isError, merger falls back to
  openai with provider_fallback_reason='vertex-ai <error>'. Round closes AMBER if
  this happens; Codex documents what IAM role / project Kadyapam needs to grant.
- gemini-2.5-flash might not be reachable in the project's allowlist. Same path:
  isError → fallback. Try gemini-2.0-flash as a fallback default if 2.5 fails.

## Bridge artefacts

- `bridge/inbox/delegated/20260510-021500-travel-vertex-ai.task.json`
- `scripts/travel_vertex_ai_msg.txt`

## Deferred follow-ups (carried forward from Phase 2 result)

- Audit table re-add as a side effect inside each render_* python step (psycopg).
- Wire hotels and activities branches in the travel agent.
- app:form widget for refining Amadeus filters before re-running.
- Anthropic re-smoke once the secret is provisioned in project 1014428265962
  (Kadyapam owns this; out-of-band).
- Ollama provider — needs in-cluster bridge URL routing design pass.
- Investigate Amadeus test API 500s on flights/locations.

## Architectural lesson reinforced

After Phase 2 the "MCP is just a playbook" thesis was a one-shot — Amadeus.
Phase 3 makes it a pattern: the same hop shape works for AI providers too. The
travel agent's three-branch dispatch is a tiny piece of glue around two MCP
playbooks (Amadeus for tooling + Vertex for inference) plus one urllib step
(OpenAI/Anthropic — kept direct because there's no MCP playbook for them yet,
and adding one would be a bigger architectural-purity round).
