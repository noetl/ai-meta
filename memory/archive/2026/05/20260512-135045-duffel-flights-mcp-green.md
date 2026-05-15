# Duffel flights MCP GREEN

Date: 2026-05-12 13:50 PT

Duffel is now the default flights provider for the travel agent.

What shipped:

- `automation/agents/mcp/duffel` as a search-only MCP playbook.
- Tools: `search_offers`, `get_offer`, `search_places`, `get_airlines`.
- Test environment only; live token path remains a placeholder.
- `search_offers` normalizes Duffel offers into the existing flight widget shape and caps offers at 10.
- Travel runtime workload fields: `flight_provider: duffel` and `duffel_env: test`.
- `flight_provider: amadeus` remains an explicit opt-out for the flights branch.
- Locations, hotels, and activities remain on Amadeus.
- Tutorial 07 documents the selector and scope.

Merged PRs:

- ops#84, merge `a92d752`
- docs#64, merge `5c394c3`

GKE registrations:

- `automation/agents/mcp/duffel` v2, catalog `625385140687995289`
- `automation/agents/travel/runtime` v16, catalog `625385144664195482`

Pre-handoff checks:

- `duffel-api-test` exists in Secret Manager.
- Worker SA `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com` has secret accessor.
- Worker ADC read the token and authenticated to Duffel `GET /air/airlines?limit=1` with HTTP 200.
- Token value was not recorded.

Smokes:

- Direct `tools/list`: `625385479898137107`, four tools.
- Direct `search_offers`: `625385503302353446`, 10 capped Duffel offers.
- Direct `search_places`: `625385527889363513`, 20 suggestions.
- Direct `get_airlines`: `625385551536849484`, 5 airlines.
- Travel default flights: `625385246619337115`, `render_flights`, 10 offers, `effective_flight_provider=duffel`.
- Travel Amadeus override: `625385670604751455`, branch matched `amadeus_via_mcp_flights`, then rendered the known upstream Amadeus test API 500 friendly failure.

Fix-forward inside the round:

- The successful Duffel path exercised `render_flights` helper calls and hit the known NoETL Python globals/locals rule. `_seg` and `_offer_card` are now republished through `globals().update(...)`.

Follow-up:

- Booking/order/payment remains out of scope.
- Live Duffel mode remains deferred until commercial/KYC and Thread 3 decisions land.
