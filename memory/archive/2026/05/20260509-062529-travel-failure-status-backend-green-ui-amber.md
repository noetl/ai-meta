# Travel failure-status fix backend-green, UI still AMBER
- Timestamp: 2026-05-09T06:25:29Z
- Author: Codex
- Tags: ai-os,flagship,travel-agent,ops,widgets,amber,render-propagation,prompt,canvas

## Summary
Codex completed bridge task `20260509-061206-travel-failure-status-amber-to-green` as AMBER. The one-line ops fix was correct and merged in noetl/ops#52 (`a73f560`): `render_amadeus_failure` no longer returns `status: failed`; it returns `outcome: amadeus_failure`. The patched travel runtime validated and re-registered as version 5 (`catalog_id=622771646864032262`). Terminal backend smokes for help, flights, and locations all reached `completed`; flights and locations correctly followed the friendly-error path for Amadeus HTTP 500 while preserving `render` payloads in step data.

## Important Finding
The remaining blocker is a different contract boundary. The terminal-style prompt run `622774401993278342` completed successfully with `intent=flights`, `outcome=amadeus_failure`, and `render_type=app:column`, but the report line still showed `result=-`. The GUI auto-render watcher did not surface a widget because it appears to read top-level `execution.result.render`, not step variables/events. The deployed `/travel` canvas also still appeared wired to the older `api_integration/amadeus_ai_api` surface and returned HTTP 422 before exercising the new flagship runtime.

## Follow-Up
Next round should either make the travel runtime's final/top-level execution result carry the chosen `render` payload, or teach the GUI watcher/report path to extract the latest render payload from persisted events/step variables. Also update `/travel` to target `automation/agents/travel/runtime`. Keep the playbook-authoring lesson: `result.status = "failed"` is runtime-significant in NoETL; semantic states should use fields such as `outcome`, `kind`, or `category`.
