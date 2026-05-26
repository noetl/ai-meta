# Travel wiki bootstrap + docs/gateway/travel pointer bumps + thread archive
- Timestamp: 2026-05-24T18:24:04Z
- Author: Kadyapam
- Tags: wiki,travel,docs,gateway,architecture,sync

## Summary
Three PRs merged: noetl/docs#169 (ephemeral_blueprints architecture doc, sidebar position 1), noetl/gateway#11 (v2.11.0: SSE subscriptions + playbook/state lifecycle frames + Python Firestore sidecar), noetl/travel#50 (gateway-backed subscriptions; firebase dependency removed from SPA). Pointers bumped to docs 089b490, gateway 4f16a1c, travel 44f2433. Archived 2026-05-24-travel-ui-gateway-only-access thread (rounds 01/02/03 closed). User added a third wiki at https://github.com/noetl/travel/wiki and asked for developer-facing code coverage. Added repos/noetl-travel-wiki as a new submodule and published 8 pages totaling 1357 lines: Home, _Sidebar, architecture, widget-contract, playbook-itinerary-planner, gateway-integration, auth-and-session, deployment, adapting-for-your-domain. Framing: travel is the worked example of how to build any-industry SPA on NoETL (not just a travel app). Pages explain widget contract (schemas + components, smoke harness), the orchestrator playbook step-by-step, the SPA-gateway wire protocol (executePlaybook GraphQL + SSE frame families), Auth0+gateway-session model, Cloudflare Pages deployment, and a 6-phase fork-and-adapt checklist for non-travel domains. Wiki commit 96b96a6. agents/rules/wiki-maintenance.md updated to two→three wikis with the new Rule 0 entry for domain-SPA patterns.

## Actions
-

## Repos
-

## Related
-
