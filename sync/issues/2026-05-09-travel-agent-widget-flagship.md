# Travel agent + Amadeus MCP — flagship demo of NoETL DSL as a templating library for AI agents

**Date filed**: 2026-05-09
**Status**: Captured / staged
**Origin**: User vision — "create a new playbook that constructs different Amadeus API calls based on text input from user and shows back in terminal in a form of widgets — right in terminal instead of special travel canvas in GUI. But travel tab also should support the same. So it will be like travel agentic playbook + amadeus mcp server playbook + ai integration — any ai api can be used. I want a travel tutorial that will show power of NoETL DSL as templating library for AI agents and MCP tooling using NoETL playbooks only."
**Related**:
- `sync/issues/2026-05-08-noetl-as-ai-os-token-architecture.md` — round 2 widget renderer; this round is the flagship demo
- `repos/e2e/fixtures/playbooks/api_integration/amadeus_ai_api/amadeus_ai_api.yaml` — existing flight-search playbook (will stay as smoke fixture; new agent supersedes)
- `repos/docs/docs/architecture/playbook_as_mcp_server.md` — pattern this round implements for the Amadeus MCP

## The thesis

NoETL is the templating library; AI providers and MCP servers are
just playbooks. To make that visible end-to-end:

- A **travel agent playbook** takes a natural-language query, lets an
  AI provider classify intent (flights / hotels / locations / activities),
  routes to the right Amadeus endpoint, and emits its result as a widget
  tree in `result.render`. The widget renderer (round 2) materialises the
  tree in NoetlPrompt and in the travel canvas.
- An **Amadeus MCP server playbook** wraps the same Amadeus capabilities
  as MCP tools (`tools/list`, `tools/call`) following the
  `playbook_as_mcp_server` pattern. Same endpoints, two surfaces:
  the agent uses the HTTP tool directly; an MCP client (Claude Desktop,
  another agent playbook, the prompt's `cd /mcp/amadeus`) uses the
  MCP server playbook.
- The **AI provider is parameterised**. The agent reads
  `workload.ai_provider` and resolves the chat-completions endpoint via
  keychain, so the same playbook runs against OpenAI, Vertex AI,
  Anthropic, or a local Ollama bridge by changing one workload field.
- The **terminal prompt** gets a `travel <query>` shorthand so users
  don't have to remember the playbook path.
- The **travel tab** (`GatewayAssistant.tsx`) renders widgets when
  the agent emits them, alongside its existing text fallback.
- A **tutorial** walks through all of it as a flagship example —
  templating, AI-provider plug-in, MCP, widgets.

## Components

### A. Travel agent playbook (new)

Path: `repos/ops/automation/agents/travel/runtime.yaml`.

Workload fields:

```yaml
workload:
  query: "I need a flight from SFO to JFK on 2026-07-15 for 2 adults"
  ai_provider: openai      # openai | vertex-ai | anthropic | ollama
  amadeus_env: test        # test | production
  request_id: ""
  callback_url: ""
```

Workflow shape:

1. **`classify_intent`** — call `workload.ai_provider` to classify into
   `flights | hotels | locations | activities | help`. Default `flights`
   if classification is ambiguous so the demo always lands on a working
   path.
2. **Route via `next.arcs[when]`**:
   - `intent == "flights"` → `build_flight_query` → `amadeus_search_flights`
   - `intent == "hotels"` → `build_hotel_query` → `amadeus_search_hotels`
   - `intent == "locations"` → `build_location_query` → `amadeus_search_locations`
   - `intent == "activities"` → `build_activity_query` → `amadeus_search_activities`
   - `intent == "help"` → straight to `render_help` (no Amadeus call)
3. **Render** — build a widget tree in `result.render`:
   - Title + query echo
   - On success: `app:carousel` of `app:column`s, one per offer/result
   - On error: `app:alert variant=error` + the friendly message
   - Action buttons: `report <execution_id>`, `rerun <execution_id>`
4. **Persist** — same postgres event-log pattern as the existing
   `amadeus_ai_api` playbook (so the audit trail still works).

The AI provider switch is a Jinja conditional inside one HTTP step:

```yaml
- step: classify_intent
  tool:
    kind: http
    method: POST
    url: "{{
      'https://api.openai.com/v1/chat/completions' if workload.ai_provider == 'openai'
      else ('https://us-central1-aiplatform.googleapis.com/v1/projects/' ~ workload.gcp_project ~ '/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent') if workload.ai_provider == 'vertex-ai'
      else 'https://api.anthropic.com/v1/messages' if workload.ai_provider == 'anthropic'
      else 'http://ollama-bridge.noetl.svc.cluster.local:8080/v1/chat/completions'
    }}"
    headers:
      Authorization: "Bearer {{ keychain[workload.ai_provider ~ '_token'].api_key }}"
      Content-Type: application/json
    payload:
      ...
```

That's the whole thesis: the URL/headers vary; the structure is
templated by NoETL.

### B. Amadeus MCP server playbook (new)

Path: `repos/ops/automation/agents/mcp/amadeus.yaml`.

Implements `tools/list` and `tools/call` per
`playbook_as_mcp_server.md`. Tools exposed:

- `search_flights` — flight offers
- `search_hotels` — hotel offers
- `search_locations` — IATA / city lookup
- `search_activities` — points of interest
- `get_token` — debug; returns whether OAuth bind succeeded

Registered as `Mcp` catalog kind so it appears in `cd /mcp/amadeus`
in NoetlPrompt. The travel agent can also call MCP tools through the
agent → MCP path (Gap 1 spike pattern), giving us two ways to call
the same Amadeus capability — direct HTTP from the agent, or MCP
hop.

### C. Travel verb in NoetlPrompt (small GUI change)

`repos/gui/src/components/NoetlPrompt.tsx`. Add `verb === "travel"`:

```typescript
} else if (verb === "travel") {
  if (!rest) throw new Error("usage: travel <natural-language query>");
  const response = await apiService.executePlaybookWithPayload({
    path: "automation/agents/travel/runtime",
    workload: { query: rest, ai_provider: "openai" },
  });
  append({
    tone: "success",
    text: `started travel agent :: execution=${response.execution_id}`,
    actions: [
      { label: `report ${response.execution_id}`, command: `report ${response.execution_id}` },
      { label: `open ${response.execution_id}`, path: `/execution/${response.execution_id}` },
    ],
  });
  navigate(`/execution/${response.execution_id}`);
  void watchExecutionForRender(response.execution_id, "travel agent");
}
```

The auto-render watcher (round 2.x) handles surfacing the widget when
the agent terminates. No new infrastructure needed.

Optional: `travel --provider vertex-ai <query>` parses an
`--provider <name>` flag and threads it into the workload.

### D. GatewayAssistant.tsx widget rendering (small GUI change)

The travel canvas currently renders `extractTextOutput(execution)` only.
Extend it: also call `extractAgentRender(execution)` and, when
present, render via `WidgetRenderer`. Text and widget can coexist —
text above for the audit trail, widget below for the rich display.

### E. Tutorial — flagship demo

Path: `repos/docs/docs/tutorials/07-travel-agent-with-widgets.md`
(tutorial 06 is the widget-rendering walkthrough Codex shipped earlier).

Sections:

1. **What you'll build** — natural language → widget tree, in two
   surfaces (terminal prompt + travel canvas).
2. **Architecture** — diagram showing query → AI provider →
   intent → Amadeus endpoint → widget output. Highlight that
   every box is a playbook step except the AI provider and Amadeus,
   which are plain HTTP.
3. **Run it** — `travel "flights from SFO to JFK July 15"` in the
   prompt; `report <id>` to see the widget; click the rerun button
   in the widget to re-run.
4. **AI provider plug-in** — show how to switch from OpenAI to Vertex
   AI to Anthropic to Ollama by changing `workload.ai_provider`.
5. **Same capability via MCP** — `cd /mcp/amadeus`, then
   `call search_flights origin=SFO destination=JFK departureDate=2026-07-15`.
   Same Amadeus call, different surface.
6. **Why this matters** — NoETL is the templating layer; AI providers
   are pluggable; MCP is just another playbook surface; widgets are
   JSON over the wire. Cite round 2 widget renderer + round 2.x.0
   auto-render + this round's intent routing.

## Phasing

### Phase 1 — Playbook + tutorial + small GUI changes (this round)

- A: travel agent playbook (with widget output, intent routing, AI
  provider switch, persistence)
- C: `travel` verb in NoetlPrompt
- D: GatewayAssistant widget rendering
- E: tutorial draft

### Phase 2 — Amadeus MCP server playbook (follow-up)

- B: full Amadeus MCP server playbook with all four tool kinds
- Tutorial gains the "Same capability via MCP" section once B lands

### Phase 3 — AI provider parity smoke (follow-up)

- Run the travel agent against all four providers (openai, vertex-ai,
  anthropic, ollama-bridge) to confirm the parameterisation works
  in practice. Capture any provider-specific shape drift in a follow-up
  round.

## Open design questions

- **Where do we keep the AI provider keychain entries?** Each
  provider has a different secret-manager path. Recommend extending
  the existing keychain block with conditional entries — only the
  one matching `workload.ai_provider` is bound. (See the `keychain`
  declarations in the existing amadeus_ai_api playbook for the
  pattern.)
- **Anthropic and Vertex shape drift.** OpenAI and Anthropic use
  `chat/completions`-style request bodies but with different message
  shapes; Vertex's `generateContent` uses `contents` with `parts`.
  Recommend a small Python step that marshals the prompt into the
  provider-specific body before the HTTP step.
- **Ollama bridge URL.** Cluster-local; only valid in-cluster.
  Operator runs against an out-of-cluster ollama via a port-forwarded
  bridge service.
- **Widget shape for offers.** A `app:carousel` of `app:column`s with
  `app:infotable` per offer is the richest. A simpler `app:recordtable`
  is a fallback. Tutorial shows both.

## Effort estimate

- Phase 1: 1 ops PR (playbook), 1 gui PR (travel verb +
  GatewayAssistant), 1 docs PR (tutorial). ~1–2 days.
- Phase 2: 1 ops PR (Amadeus MCP). ~1 day.
- Phase 3: ad-hoc smokes. ~half-day per provider.
