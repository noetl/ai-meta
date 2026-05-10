# Handed travel hotels/activities round to Codex (closes Phase 1 stub)

- date: 2026-05-10T18:45:00Z
- tags: travel-agent, hotels, activities, amadeus-mcp, agent-hop, codex-handoff

## Round goal

Wire the travel runtime's hotels and activities intents to the Amadeus MCP
playbook, mirroring the Phase 2 flights/locations pattern. Closes the Phase 1
stub comment in `runtime.yaml` ("Phase 2 wires the real Amadeus calls").

The Amadeus MCP playbook already exposes both tools — search_hotels and
search_activities — so this round is a pure travel-runtime + tutorial edit.
No MCP playbook changes.

## Two design choices

1. **Hotels — IATA city code via the classifier.** Amadeus search_hotels
   requires `cityCode` (IATA, e.g. NYC, PAR, LON). The current classifier
   extracts `city` (free-text city name). Rather than add a city→IATA
   lookup step, extend the classifier system prompt to extract IATA codes
   directly. The LLM has the mapping for major cities. Keep `city` as a
   secondary human-readable field (useful for widget display).

2. **Activities — latitude/longitude via the classifier.** Amadeus
   search_activities requires `latitude`/`longitude`. The classifier
   currently extracts `keyword`. Extend the system prompt to also extract
   lat/long when intent='activities'. The LLM has coordinates for major
   cities and landmarks ("near Times Square" → ~40.758, -73.985). Default
   to NYC center if extraction returns null. If the LLM whiffs the
   coordinates, the Amadeus call returns a clean error envelope and the
   existing render_amadeus_failure widget handles it — no new error path.

## What changes in the runtime

- classify_intent system prompt extended (TWO places — Python const for
  http branch + payload `system` arg for vertex branch — kept synchronized).
- Merger schema gains cityCode/latitude/longitude fields with proper coercion.
- Two new agent → MCP hops: amadeus_via_mcp_hotels, amadeus_via_mcp_activities.
- Two new render steps: render_hotels, render_activities (recordtable widgets,
  render-as-tail).
- log_classification arcs split: hotels → mcp_hotels, activities → mcp_activities,
  help → render_help. Stale "stubbed" comment removed.

## What does NOT change

- Amadeus MCP playbook (single source of truth holds across the whole arc).
- Vertex AI MCP playbook.
- render_flights, render_locations, render_amadeus_failure — proven, untouched.
- The classifier's intent enum (already had hotels/activities).
- The merger's overall pattern.

## Phases (6)

1. Validate design (apply edits; Pydantic-validate).
2. Ops PR: feat(travel-agent): wire hotels and activities branches via the Amadeus MCP playbook.
3. Docs PR: tutorial 07 mentions all four branches + adds example commands.
4. Re-register and smoke all four intents + help regression. Hotels and
   activities must show tool_kind=agent + sub_execution_id in events.
5. External MCP regression — direct call_hotels and call_activities still work.
6. ai-meta pointer bumps. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260510-184500-travel-hotels-activities.task.json`
- `scripts/travel_hotels_activities_msg.txt`

## What's next after this lands

From the post-flagship deferred list (in order):

3. app:form widget for refining Amadeus filters before re-running
4. Audit table re-add inside render_* steps (psycopg)
5. Anthropic re-smoke (gated on user provisioning the GCP secret)
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations

## Lurking design debt to flag

The classifier system prompt now lives in TWO places (Python const + Vertex
payload arg). When both branches need the same prompt change, both must be
edited together. A future architectural-purity round should extract the
prompt into a single workload field referenced by both branches. Not in
scope here — mark as known debt.
