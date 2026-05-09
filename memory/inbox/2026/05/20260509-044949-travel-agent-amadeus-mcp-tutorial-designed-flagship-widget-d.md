# Travel agent + Amadeus MCP + tutorial designed — flagship widget demo handoff
- Timestamp: 2026-05-09T04:49:49Z
- Author: unknown
- Tags: ai-os,flagship,travel-agent,amadeus,mcp,widgets,bridge,codex,handoff,tutorial,3-prs

## Summary
Flagship round demonstrating NoETL DSL as templating library for AI providers + MCP + widgets. Five artifacts in working tree (not committed): (A) repos/ops/automation/agents/travel/runtime.yaml — travel agent with Jinja-conditional AI provider switching across openai/vertex-ai/anthropic/ollama on URL/headers/body, intent classification routing to Amadeus flights or locations endpoints (hotels/activities deferred to phase 2), widget output trees per intent (carousel of flight cards / recordtable of locations / friendly error / help screen with example buttons), postgres event audit. Keychain uses when: predicates so only the matching provider token is bound. (B) repos/ops/automation/agents/mcp/amadeus.yaml — Amadeus MCP server playbook with tools/list returning 5-tool catalog and tools/call dispatching by tool name. exposes_as_mcp: true; appears as cd /mcp/amadeus. Returns MCP-shaped envelopes. (C) repos/gui/src/components/NoetlPrompt.tsx gains travel verb with optional --provider flag; help text updated. (D) repos/gui/src/components/GatewayAssistant.tsx switches default playbook to the new travel agent runtime, extracts result.render via extractAgentRender, renders widgets via WidgetRenderer below chat bubbles; widget command/navigate events route through onSubmit/navigate so canvas buttons work. (E) repos/docs/docs/tutorials/07-travel-agent-with-widgets.md — 6-section flagship tutorial covering register and run, read the agent, pluggable AI provider, widget output contract, same capability via MCP, travel canvas. Sync issue at sync/issues/2026-05-09-travel-agent-widget-flagship.md captures the 3-phase plan. tsc noEmit clean. Bridge task bridge/inbox/delegated/20260509-044651-travel-agent-widget-flagship.task.json hands 11 phases to Codex: typecheck+build, validate both playbooks, 3 PRs (ops gui docs), redeploy and register, smoke each surface (terminal travel verb + travel canvas + cd mcp amadeus + AI provider switch), ai-meta gitlink bumps. Codex prompt at scripts/travel_agent_widget_flagship_msg.txt. The thesis: NoETL is the templating library; AI providers and MCP servers and rendering surfaces are all pluggable. Same capability one playbook one widget contract two surfaces. No noetl Python changes. Phase 2 deferred items wire travel agent through Amadeus MCP internally and complete hotels and activities branches. Phase 3 deferred items run AI provider parity smokes against all four providers.

## Actions
-

## Repos
-

## Related
-
