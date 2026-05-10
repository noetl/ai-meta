# Handed travel-via-Amadeus-MCP Phase 2 to Codex
- Timestamp: 2026-05-10T00:36:02Z
- Author: unknown
- Tags: ai-os,travel-agent,phase-2,amadeus-mcp,agent-to-mcp-hop,bridge,codex,handoff,gap-1-precedent

## Summary
Anthropic re-smoke deferred (GCP secret provisioning blocked — different account scope; user will pick up when ready). Moving on to next backlog item: Phase 2 of the travel agent flagship — route Amadeus calls through the Amadeus MCP playbook (agent → MCP hop) instead of direct urllib calls. Bridge task bridge/inbox/delegated/20260510-003344-travel-agent-via-amadeus-mcp.task.json. Today amadeus_call_flights and amadeus_call_locations use kind:python urllib directly. After this round they become amadeus_via_mcp_flights / amadeus_via_mcp_locations using tool kind:agent framework:noetl invoking automation/agents/mcp/amadeus catalog v3 with method tools/call tool search_flights / search_locations and arguments dict. Renames flow into log_classification arcs and render_flights/locations/amadeus_failure envelope reads (from envelope.body.data to envelope.data.offers/items per the MCP playbook's shape_search_* output). Tutorial 07 Same capability via MCP section updated to note Phase 2: agent now uses MCP playbook internally so both surfaces share one Amadeus implementation. Includes jq snippet showing tool_kind=agent and sub_execution_id in events. Spike Gap 1 task #89 provides the tool:agent framework:noetl precedent. 7 phases validate ops-PR docs-PR re-register terminal-widget-smoke external-MCP-regression ai-meta-pointer-bumps. Cap 1 ops + 1 docs PR. Codex prompt at scripts/travel_agent_via_amadeus_mcp_msg.txt. Architectural win: MCP is just a playbook becomes load-bearing — change Amadeus integration in one place updates both the agent's internal calls and external MCP clients.

## Actions
-

## Repos
-

## Related
-
