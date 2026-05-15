# Google Places enrichment AMBER, activities GREEN

Date: 2026-05-12 11:20 PT

The Google Places + Maps enrichment round shipped as Pattern C:

- Backend Google Places calls run through worker Workload Identity OAuth.
- Widget image URLs use the restricted `google-maps-widget-key` from Secret Manager.
- Travel enrichment is opt-in via `enrich_with_google_places: true`; default remains OFF.
- Enrichment supplements Amadeus results and is capped at 10 items per execution.

Merged PRs:

- ops#78 adds the Google Places MCP playbook and travel runtime enrichment hooks.
- docs#62 documents the tutorial flow.
- ops#79 fixes MCP tool input binding.
- ops#80 fixes NoETL Python globals/locals helper visibility.
- ops#81 emits `control_data` for agent-hop parent visibility.
- ops#82 compacts enrichment payloads by using Maps Static URLs instead of search-time Place Photo payloads.

GKE registrations:

- `automation/agents/mcp/google-places` v6, catalog `625307577596772621`
- `automation/agents/travel/runtime` v13, catalog `625307577697435918`

Validation:

- Worker ADC Places probe succeeded.
- Secret Manager widget-key read succeeded; only prefix/length recorded.
- Static Maps accepted the intended referer and rejected a deliberately bad referer.
- Direct Google Places MCP search `625307783436435727` completed with Eiffel Tower and a widget image URL.
- Default-off activities `625309959902724902` completed with 10 items and no Google enrichment.
- Opt-in activities `625308771379577122` completed with 10 items, `google_enriched_count=10`, and a picture widget.
- Missing-widget-secret probe `625309315867345375` completed with a handled no-URL response.

AMBER reason:

- Locations `625309575519928818` and hotels `625309687340073612` both hit the known Amadeus test API HTTP 500 path before enrichment could run. This is upstream of Google Places and matches the existing Amadeus test API instability thread.

Operational cleanup:

- Temporary GKE worker scale was restored to 2 replicas.
- The local `kubectl port-forward` used for registration and smokes was stopped.

Lesson:

Keep enrichment payloads compact by default. A single Google Places response with photos and long image URLs can cross reference/spill thresholds, especially when cost-control rounds intentionally stop in-cluster object-store pods and route durable spillover elsewhere. Static Maps thumbnails are a better default for inline widget decoration; richer Place Photo URLs can be explicit.
