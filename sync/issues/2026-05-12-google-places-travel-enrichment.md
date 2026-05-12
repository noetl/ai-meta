# Google Places + Maps travel enrichment

Status: AMBER, with shipped code/docs and GKE activities enrichment GREEN.

## What Landed

- `automation/agents/mcp/google-places` wraps Google Places and Maps URL construction as a NoETL MCP playbook.
- `automation/agents/travel/runtime` can opt in with `enrich_with_google_places: true`.
- Default behavior stays OFF.
- Enrichment supplements Amadeus output; it does not replace Amadeus search.
- Per-execution enrichment is capped at 10 items.
- Backend calls use worker Workload Identity OAuth.
- Widget image URLs use the restricted `google-maps-widget-key` Secret Manager key only for Maps Static / Place Photos URL construction.

Merged PRs:

- noetl/ops#78, #79, #80, #81, #82
- noetl/docs#62

## GKE Validation

Registered on GKE:

- `automation/agents/mcp/google-places` version 6, catalog `625307577596772621`
- `automation/agents/travel/runtime` version 13, catalog `625307577697435918`

Pre-handoff checks passed:

- Maps and Places APIs were enabled.
- Worker service account has the required backend access.
- `google-maps-widget-key` exists in Secret Manager.
- Worker ADC successfully called Places `searchText`.
- Static Maps accepted the configured referer and rejected a deliberately bad referer.

Smokes:

- Direct Google Places MCP search: `625307783436435727`, completed, returned Eiffel Tower with Maps Static URL available.
- Default-off travel activities: `625309959902724902`, completed, `items_total=10`, `google_enriched_count=0`, no picture widget.
- Opt-in enriched travel activities: `625308771379577122`, completed, `items_total=10`, `google_enriched_count=10`, one picture widget.
- Non-destructive missing widget secret probe: `625309315867345375`, completed with no URL and a handled widget-key error.

## Remaining AMBER

Locations and hotels enrichment could not be proven through the travel runtime because Amadeus test API returned upstream HTTP 500 before Google enrichment could run:

- Locations: `625309575519928818`, `render_amadeus_failure`, upstream `500`
- Hotels: `625309687340073612`, `render_amadeus_failure`, upstream `500`

This matches the prior Amadeus test API instability investigation. The Google Places layer itself is not the failing component for those two intents.

## Follow-Ups

- Re-run locations and hotels enrichment after either Amadeus test API recovers or the opt-in production Amadeus credentials are provisioned.
- Consider moving richer Place Photo usage behind a separate explicit mode if we want more visual variety; compact Maps Static thumbnails are intentionally safer for payload size.
- Keep the current no-secrets rule: result files should only record booleans or redacted key prefixes, never full widget URLs with API keys.
