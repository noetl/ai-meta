# Travel Ollama Phase 4 closes GREEN — multi-provider arc reaches its cap

- date: 2026-05-11T02:00:00Z
- tags: travel-agent, ollama, mcp-playbook, phase-4, green, arc-closure

## What landed

- Ops PR: noetl/ops#66 — new automation/agents/mcp/ollama.yaml + travel runtime hookup
- Docs PR: noetl/docs#56 — tutorial 07 fourth provider path
- mcp/ollama playbook catalog 623469830623986139 v2
- Travel runtime catalog 623469831437681116 v24
- Validation log appended

## GREEN smoke evidence

- All five ollama intents (help/flights/locations/hotels/activities)
  completed with effective_provider='ollama', no fallback.
- Direct `cd /mcp/ollama; call chat_completion ping` returned "pong" through
  the new canonical chat_completion wrapper — confirms the playbook's
  external MCP surface is reachable too.
- OpenAI default regression clean.
- Vertex regression on kind correctly fell back to OpenAI because local
  kind lacks GKE Workload Identity. That's the EXPECTED behaviour per the
  Phase 3 workload-default-environment-mismatch lesson — vertex's auth
  chain hits the metadata-server fallback which doesn't exist on kind.
  Not a regression. The cluster targeted matters.

## Architectural arc — final state

After Phase 4, the travel agent demonstrates:

| capability                             | route                                                   |
| -------------------------------------- | ------------------------------------------------------- |
| OpenAI inference                       | urllib direct in classify_via_http_provider             |
| Anthropic inference                    | urllib direct in classify_via_http_provider             |
| Vertex AI inference                    | classify_via_vertex_mcp → mcp/vertex-ai playbook hop    |
| Ollama inference                       | classify_via_ollama_mcp → mcp/ollama playbook hop (NEW) |
| Amadeus flights/hotels/locations/acts  | amadeus_via_mcp_* → mcp/amadeus playbook hops           |
| Refinement forms per render branch     | app:form with template substitution                     |
| Audit trail per render outcome         | best-effort psycopg side effect inside render_* steps   |
| Friendly error widgets on Amadeus 5xx  | render_amadeus_failure with intent context preserved    |

Three concrete examples of "MCP is just a playbook":
1. Amadeus tooling (Phase 2)
2. Vertex AI inference (Phase 3)
3. Ollama inference (Phase 4)

The thesis is now fully load-bearing. The travel runtime is the smallest
possible glue around three MCP playbooks plus one urllib step, with
widget render-as-tail and audit side effects.

## Bookkeeping observation

Codex left the Anthropic v2 re-smoke artifacts unstaged on purpose —
pushing the staged bridge task would fire the watcher before the GCP
secret is provisioned. That's the right operational instinct. The
artifacts stay on disk locally until either (a) the secret is provisioned
and the user wants to fire the round, or (b) they're abandoned.

## Lurking design debt — promoted to load-bearing

The classifier system_prompt is now duplicated across THREE branches
(Python const + vertex payload + ollama payload). Phase 4 cemented this
coupling. Every schema extension henceforth touches three places. The
deferred 'classifier system prompt single source of truth' refactor is
no longer optional — it's the next architectural-purity round to do
before any further classifier extensions.

## Deferred follow-ups remaining (in order)

7. Investigate Amadeus test API 500s on flights/locations — NEXT
8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system_prompt (now load-bearing)
10. Anthropic re-smoke (gated on user; v2 task on disk but unstaged)

After #7-#10, the architectural arc has no obvious next round. The travel
agent is feature-complete as a NoETL-DSL-as-templating-library demo.
