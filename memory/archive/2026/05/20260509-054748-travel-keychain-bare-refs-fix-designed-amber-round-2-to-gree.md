# Travel keychain bare-refs fix designed — AMBER round 2 to GREEN handoff
- Timestamp: 2026-05-09T05:47:48Z
- Author: unknown
- Tags: ai-os,flagship,travel-agent,amber-to-green,keychain,jinja,oauth2,bridge,codex,handoff

## Summary
AMBER round 2 closed AMBER per bridge/outbox/20260509-051749-travel-agent-amber-to-green.result.json. SQL fix shipped (log_classification works), but Amadeus HTTP branches fail with Illegal header value Bearer empty. Diagnosed as three structural issues vs the proven amadeus_ai_api.yaml keychain: 1 keychain Jinja templates use workload.X instead of bare X; 2 OAuth2 endpoint URL uses Jinja conditional which does not render in keychain context; 3 when predicates on per-provider entries appear unsupported. Claude shipped fixes in working tree not committed. Travel runtime keychain rewritten with bare refs gcp_auth amadeus_key_path etc. Removed anthropic_token vertex_token entries multi-provider returns as follow-up after baseline GREEN. OAuth2 endpoint hardcoded test URL. classify_intent OpenAI-only explicit URL headers payload no conditionals. parse_classification drops vertex anthropic response unwrap branches. Amadeus search URLs collapsed Jinja conditional to plain strings. Same fix applied to amadeus.yaml MCP playbook plus searchCriteria maxFlightOffers hardcoded to integer 10 since YAML-quoted Jinja int still renders as string. Bridge task bridge/inbox/delegated/20260509-054530-travel-keychain-amber-to-green.task.json hands 8 phases to Codex validate ops PR re-register terminal canvas MCP smokes openai-only baseline ai-meta pointer bump on top of 16 unpushed commits. Codex prompt at scripts/travel_keychain_amber_to_green_msg.txt. Lesson keychain block uses bare workload references not workload.X. Multi-provider keychain switching needs design pass after baseline GREEN follow-up round can introduce when predicates if noetl supports them or alternatively use python helper to build provider-specific request shape.

## Actions
-

## Repos
-

## Related
-
