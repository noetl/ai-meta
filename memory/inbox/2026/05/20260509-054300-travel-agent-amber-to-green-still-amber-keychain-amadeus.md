# Travel agent AMBER-to-GREEN round remains AMBER — SQL fixed, Amadeus/keychain path next
- Timestamp: 2026-05-09T05:43:00Z
- Author: codex
- Tags: travel-agent,amadeus,mcp,keychain,amber,ops

## Summary
Codex executed bridge task `20260509-051749-travel-agent-amber-to-green`. The intended one-PR ops fix landed as noetl/ops#49 (`18988bb5915506668652797fdfd364036f3010f9`): `parse_classification` now pre-serialises classification output to `json_str`, and `log_classification` uses that single field in the Postgres audit SQL. The fixed playbook Pydantic-validates and was re-registered locally as `automation/agents/travel/runtime` version 2, catalog id `622745768260010040`.

The original blocker is fixed: `travel help` execution `622745877731344441` completed in 4.008s with `log_classification`, `render_help`, `persist_and_callback`, and `end` all in `completed_steps`. The round remains AMBER because the next required smokes exposed a separate Amadeus/keychain runtime issue. `travel flights from SFO to JFK on 2026-07-15 for 2 adults` (`622746596920262831`) and `travel locations near Boston` (`622746596869931182`) both classified correctly and reached `log_classification`, then failed in `amadeus_search_flights` / `amadeus_search_locations` with `Request error: Illegal header value b'Bearer '`. That means the travel runtime's Amadeus branch is seeing an empty `keychain.amadeus_token.access_token`.

Important contrast: the standalone `automation/agents/mcp/amadeus` playbook did bind the Amadeus OAuth token. `tools/list` execution `622747225478660441` completed and reported `_meta.tool_count=5`; `get_token` execution `622747225470271832` completed and reported `_meta.token_bound=true`. However, MCP `search_locations` (`622748958464410404`) and `search_flights` (`622748958472799013`) still failed with `Tool returned error` and zero shaped results, so there is also an MCP search request/response follow-up.

Provider switch remained blocked: OpenAI/default help completed, but Vertex (`622747227877802330`) failed classify with empty Bearer, Ollama (`622747227978465627`) failed classify after roughly 60s, and Anthropic (`622748690179949231`) returned `Tool returned error`. The likely next round should focus on travel runtime keychain `when:` behavior / provider keychain rendering, then replay flights, locations, canvas, MCP search, and provider-switch smokes. Result file: `bridge/outbox/20260509-051749-travel-agent-amber-to-green.result.json`.
