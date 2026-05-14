# Travel itinerary Gateway callback hotfix GREEN

## Summary

Kadyapam reported that the live Travel/Muno chat still timed out with
`Playbook callback timed out`, while the NoETL execution list showed many
nested `automation/agents/mcp/firestore` executions. Investigation showed the
Firestore children were mostly misleading UI state: direct NoETL status checks
showed they completed quickly. The parent itinerary playbook also completed,
but it never posted the final result back to the Gateway async callback endpoint
that the browser waits on.

## Fix

- `repos/travel` PR #29 merged as `9948930`.
- Added `request_id` and `gateway_url` workload fields to
  `playbooks/itinerary-planner.yaml`.
- `final_result` now POSTs the completed result to
  `{gateway_url}/api/internal/callback/async` when `request_id` is present.
- Routed nested step references through `TaskResultProxy.context` after MCP and
  Firestore side-effect steps.
- Republished Python helper functions through `globals().update(...)` in
  `normalize_tool_response` so list comprehensions and helper-to-helper calls
  work under NoETL's separate globals/locals execution model.
- Render now merges slot information from pre-tool, post-tool, and extraction
  JSON state before returning the final widget payload.

## Validation

- `npm run test` passed.
- `npm run type-check` passed.
- `npm run build` passed.
- PR checks passed.
- GKE registered the merged playbook as catalog version 20
  (`626273327996207449`) for `muno/playbooks/itinerary-planner`.
- Direct GKE smoke execution `626270247338639787` completed in 16s at
  `final_result`. It attempted the Gateway callback; the expected fake
  `request_id` probe returned HTTP 404 because no browser request was pending.

## Follow-up

The live browser smoke should now resolve the Gateway callback instead of
timing out, because browser-started GraphQL executions create a real pending
request id in Gateway before the playbook posts the callback. If the browser
still times out, inspect Gateway logs for `Callback received` and
`Callback delivered to client` around the live request id.
