# Phase 2 GREEN — travel agent uses Amadeus MCP playbook internally
- Timestamp: 2026-05-10T01:38:12Z
- Author: unknown
- Tags: ai-os,travel-agent,phase-2,green,close-out,amadeus-mcp,agent-to-mcp-hop,milestone

## Summary
Phase 2 of the travel agent flagship closed GREEN. ops PR noetl/ops#58 merged docs PR noetl/docs#49 merged. Travel runtime re-registered as catalog 623349468200436085 version 13. The amadeus_call_flights and amadeus_call_locations steps replaced with tool kind:agent framework:noetl invocations of automation/agents/mcp/amadeus catalog v3 with method tools/call. Final smokes help 623349608365687158 render_help app:column completed; flights 623349633313407419 with MCP sub-exec 623349652397490679 friendly error widget; locations 623349971575636549 with MCP sub-exec 623349991473414785 friendly error widget. External MCP regression clean: tools/list 5 tools get_token bound search_flights surfaces Amadeus HTTP 500 as error envelope per round 3 urllib wrappers. Amadeus test API currently returning 500 for flights/locations so GREEN means architecture and graceful widget path proven not happy-path Amadeus data. Validation log appended bridge/outbox/codex-spike-green-validation.md. ai-meta 3 unpushed commits not yet pushed. Architectural achievement: MCP-is-just-a-playbook thesis is now load-bearing — Amadeus integration changes propagate to both agent internal calls and external MCP clients atomically through the single Amadeus MCP playbook. The travel agent's tool kind for Amadeus events is now agent with sub_execution_id pointing at the MCP playbook execution proving the hop happened. Backlog after Phase 2: audit table re-add as side effect inside render_* python steps; wire hotels and activities branches; app:form widget for refining Amadeus filters; Anthropic re-smoke once GCP secret provisioned in project 1014428265962; Vertex AI provider needs gcp_access_token keychain kind; Ollama provider needs in-cluster bridge URL; investigate Amadeus test API 500 on flights/locations endpoints (may be amadeus-side or token-scope issue worth surfacing in get_token MCP tool detail).

## Actions
-

## Repos
-

## Related
-
