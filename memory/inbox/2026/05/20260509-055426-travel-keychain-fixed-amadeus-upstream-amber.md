# Travel keychain round AMBER — token binding fixed, Amadeus upstream/error handling remains
- Timestamp: 2026-05-09T05:54:26Z
- Author: codex
- Tags: travel-agent,amadeus,mcp,keychain,amber,ops

## Summary
Codex executed bridge task `20260509-054530-travel-keychain-amber-to-green`. The one allowed ops PR landed as noetl/ops#50 (`94f2f651e1b6f378479093558e237d423bc69f29`) and applied the bare-reference keychain fix to both `automation/agents/travel/runtime.yaml` and `automation/agents/mcp/amadeus.yaml`. Both playbooks Pydantic-validated, then registered locally as travel runtime version 3 (`catalog_id=622759020515820462`) and Amadeus MCP version 2 (`catalog_id=622759020683592623`).

The specific empty-Bearer diagnosis is fixed. Travel runtime executions now issue Amadeus HTTP commands with non-empty Bearer tokens in the command-issued event: flights execution `622759104921994162` and locations execution `622759104863273904` both had real tokens in the rendered Authorization header. `travel help` execution `622759104880051121` completed in 6.972s, and explicit OpenAI baseline help execution `622760279058678349` completed in 2.297s.

The round remains AMBER because Amadeus-backed smokes still do not complete. Flights and locations now fail with `Tool returned error status` at the Amadeus HTTP step instead of `Illegal header value b'Bearer '`. A direct curl check using the bound token, without printing the token, returned HTTP 500 with Amadeus error code `38189` for both locations and flights. The current playbook's `render_amadeus_failure` branch does not run because the HTTP tool failure aborts before next arcs evaluate. The Amadeus MCP smoke shows the same split: `tools/list` (`622759913239871695`) and `get_token` (`622759913256648913`) are green, `search_activities` (`622759913256648914`) completes with zero activities, but `search_locations` (`622760119322804675`), `search_flights` (`622760119415079364`), and `search_hotels` (`622759913239871696`) fail with `Tool returned error status`.

Next round should focus on load-bearing Amadeus error handling: either use a non-throwing HTTP mode if NoETL has one, or call Amadeus from a Python step that captures 4xx/5xx responses and returns a normal envelope so `render_amadeus_failure` can complete the workflow with a friendly widget. Result file: `bridge/outbox/20260509-054530-travel-keychain-amber-to-green.result.json`.
