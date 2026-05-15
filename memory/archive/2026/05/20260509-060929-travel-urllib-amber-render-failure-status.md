# Travel urllib round AMBER — MCP green, travel friendly-error renderer still marks failed
- Timestamp: 2026-05-09T06:09:29Z
- Author: codex
- Tags: travel-agent,amadeus,mcp,urllib,widgets,amber,ops

## Summary
Codex executed bridge task `20260509-060007-travel-amadeus-urllib-amber-to-green`. The one allowed ops PR landed as noetl/ops#51 (`67cdd67b6c2bcb0fb4fe4ad6ab23f13d60178e35`), replacing the Amadeus `kind: http` calls with Python `urllib` wrappers in both `automation/agents/travel/runtime.yaml` and `automation/agents/mcp/amadeus.yaml`. Both playbooks validated and were registered locally as travel runtime version 4 (`catalog_id=622767261182329538`) and Amadeus MCP version 3 (`catalog_id=622767261249438403`).

The MCP half reached the intended contract. `tools/list` (`622767696358146115`) and `get_token` (`622767697616437316`) completed. `search_locations` (`622767697616437317`), `search_flights` (`622767697616437318`), and `search_hotels` (`622767873517158680`) also completed at the NoETL level and reported upstream Amadeus 500s through `isError=true` plus `_meta.status_code=500`. `search_activities` (`622767873450049815`) completed with `isError=false`, HTTP 200, and `activities_total=72`.

The travel runtime remains AMBER for a smaller reason. `travel help` (`622767330396734148`) completed. `travel flights from SFO to JFK on 2026-07-15 for 2 adults` (`622767330723889861`) and `travel locations near Boston` (`622767330732278470`) now route through `amadeus_call_*`, catch the Amadeus 500 (`errors[0].code=38189`), and execute `render_amadeus_failure`. That renderer builds the expected app:column friendly-error widget and `persist_and_callback` + `end` run, but the renderer result carries `status: failed`, so NoETL emits `command.failed` / `Tool returned error status` for `render_amadeus_failure` and the overall execution remains `FAILED`.

Next round should be tiny: change `render_amadeus_failure` to return a NoETL-success status (`ok`/`completed`) while preserving upstream failure semantics in `upstream_status_code`, `upstream_message`, and the alert widget. Result file: `bridge/outbox/20260509-060007-travel-amadeus-urllib-amber-to-green.result.json`.
