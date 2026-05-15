# Travel agent flagship AMBER — log_classification SQL fix designed and handed to Codex
- Timestamp: 2026-05-09T05:20:03Z
- Author: unknown
- Tags: ai-os,flagship,travel-agent,amber-to-green,sql-quoting,jinja,postgres,bridge,codex,handoff

## Summary
Flagship round shipped AMBER per bridge/outbox/20260509-044651-travel-agent-widget-flagship.result.json. 3 PRs merged (ops48 d0e27357 / gui29 v1.10.0 fa3101c1 / docs46 23dbb010), GUI v1.10.0 deployed, both playbooks registered (travel runtime catalog_id 622737301109474241; amadeus mcp catalog_id 622737301503738818). OpenAI classify and render_help widget worked but log_classification audit step failed with command_0 syntax error — Postgres received the LITERAL Jinja expression backslash-escaped-double-quotes around the inner replace args got mangled in the YAML/Jinja chain so the inline tojson plus replace pattern did not render. Phase 7 blocker also paused phases 8 9 10. Claude designed the fix in working tree not committed two surgical edits to repos/ops/automation/agents/travel/runtime.yaml. Edit one parse_classification python step gains result.json_str via json.dumps with separators comma colon. Edit two log_classification SQL changes from inline tojson plus replace to single-field reference pattern that the existing amadeus_ai_api playbook uses successfully at line 553. Bridge task bridge/inbox/delegated/20260509-051749-travel-agent-amber-to-green.task.json hands 8 phases to Codex validate, ops PR, re-register, replay phase 7 to GREEN with 3 intents, complete deferred phases 8 canvas 9 amadeus MCP 10 provider switch, ai-meta pointer bump on top of existing 13 unpushed commits. Codex prompt at scripts/travel_agent_amber_to_green_msg.txt. Lesson the inline tojson plus replace pattern with embedded apostrophes inside YAML literal block is fragile single-field reference referenced.json_str pipe replace is the proven safe form.

## Actions
-

## Repos
-

## Related
-
