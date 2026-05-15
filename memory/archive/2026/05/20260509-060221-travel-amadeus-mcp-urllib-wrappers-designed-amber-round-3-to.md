# Travel + Amadeus MCP urllib wrappers designed — AMBER round 3 to GREEN handoff
- Timestamp: 2026-05-09T06:02:21Z
- Author: unknown
- Tags: ai-os,flagship,travel-agent,amber-to-green,urllib,http-tool,noetl-88,bridge,codex,handoff

## Summary
AMBER round 3 closed with keychain proven (non-empty Bearer tokens) but Amadeus calls fail because noetl HTTP tool aborts on 5xx pending task 88. Direct curl returned HTTP 500 code 38189 from Amadeus test API for flights and locations confirming upstream issue. Claude shipped fix in working tree not committed: replaced 6 Amadeus HTTP calls with kind python urllib wrappers. Travel runtime: amadeus_search_flights to amadeus_call_flights kind python urllib POST catches HTTPError URLError Exception returns ok status_code body envelope. amadeus_search_locations to amadeus_call_locations kind python urllib GET same shape. log_classification arcs route to amadeus_call steps. render_flights and render_locations read envelope.body.data instead of noetl http envelope data.data. render_amadeus_failure reads new envelope body status_code. Conditional arcs check amadeus_call.ok directly. Amadeus MCP playbook: 4 tool calls flights locations hotels activities collapsed http+shape pair into single Python step doing urllib plus MCP envelope shaping. Returns canonical MCP shape with data.ok and data.error populated on Amadeus 4xx 5xx. Bridge task bridge/inbox/delegated/20260509-060007-travel-amadeus-urllib-amber-to-green.task.json hands 8 phases to Codex validate ops PR re-register terminal canvas MCP smokes openai baseline ai-meta pointer bump on top of 19 unpushed commits. Codex prompt at scripts/travel_amadeus_urllib_amber_to_green_msg.txt. Even when Amadeus 500s the python step succeeds at noetl level and the friendly error widget renders. Lesson noetl HTTP tool aborts step on 5xx instead of populating status envelope so when arcs cannot route to error handler. Workaround urllib wrapper in python step. Once noetl#88 lands HTTP tool preserves error body these wrappers can revert to kind http.

## Actions
-

## Repos
-

## Related
-
